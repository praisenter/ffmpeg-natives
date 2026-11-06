# Package all classifier ZIPs, or check release prerequisites without downloading anything.
#param([switch] $CheckRelease)

# Load the pinned upstream inputs and Maven version relative to this script's location.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
$root = (Resolve-Path "$PSScriptRoot/../..").Path
$upstreamConfig = Get-Content -Raw "$root/upstream.properties" | ConvertFrom-StringData
[xml] $pom = Get-Content "$root/pom.xml"
$version = [string] $pom.project.version

# Discard previous output and extraction folders so stale files cannot enter a new ZIP.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$output = "$root/target/distributions"
if (Test-Path $output) { Remove-Item -Recurse -Force $output }
New-Item -ItemType Directory -Force $output | Out-Null
$work = "$root/target/packaging"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force $work | Out-Null

# Resolve an archive from the input lock and verify its SHA-256 before extracting it.
# ZIP extraction uses .NET; tar handles the Linux provider's tar.xz archive.
function Expand-VerifiedArchive($Prefix, $Destination, $Extension) {
    $url = $upstreamConfig["$Prefix.url"]
    $expected = $upstreamConfig["$Prefix.sha256"]
    $binaryPath = $upstreamConfig["$Prefix.path"]
    if ($url -notmatch '^https://' -or $url -match '/latest/' -or $expected -notmatch '^[0-9a-f]{64}$') {
        throw "Missing or invalid locked URL/checksum: $Prefix"
    }
    if ([string]::IsNullOrWhiteSpace($binaryPath) -or [System.IO.Path]::IsPathRooted($binaryPath) -or
        ($binaryPath -split '[\\/]' -contains '..')) {
        throw "Missing or invalid relative executable directory: $Prefix.path"
    }
    New-Item -ItemType Directory -Force $Destination | Out-Null
    $archive = "$Destination/source.$Extension"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
    if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $expected) {
        throw "SHA-256 mismatch: $url"
    }
    if ($Extension -eq 'zip') {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($archive, "$Destination/extracted")
    } else {
        New-Item -ItemType Directory -Force "$Destination/extracted" | Out-Null
        & tar -xf $archive -C "$Destination/extracted"
        if ($LASTEXITCODE -ne 0) { throw "tar failed for $url" }
    }
    return "$Destination/extracted"
}

# Fail rather than silently package a missing or empty executable or required notice.
function Copy-RequiredFile($Source, $Destination) {
    if (!(Test-Path -LiteralPath $Source -PathType Leaf) -or (Get-Item -LiteralPath $Source).Length -eq 0) {
        throw "Missing or empty input: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination
}

# Map public Maven classifiers to provider-specific property prefixes and file suffixes.
$platforms = @(
    @{ Classifier = 'windows-x86_64'; Prefix = 'ffmpeg.windows'; Suffix = '.exe' },
    @{ Classifier = 'linux-x86_64'; Prefix = 'ffmpeg.linux'; Suffix = '' },
    @{ Classifier = 'macos-x86_64'; Prefix = 'ffmpeg.macos.x64'; Suffix = '' },
    @{ Classifier = 'macos-aarch64'; Prefix = 'ffmpeg.macos.arm64'; Suffix = '' }
)
$checksums = @()
# Give every platform the same bin/licenses/metadata layout, regardless of provider layout.
foreach ($platform in $platforms) {
    $classifier = $platform.Classifier
    $prefix = $platform.Prefix
    $staging = "$work/$classifier/staging"
    New-Item -ItemType Directory -Force "$staging/bin", "$staging/licenses" | Out-Null
    # Repository license texts and per-platform notices do not depend on other extractions.
    Copy-RequiredFile "$root/licenses/COPYING.GPLv3.txt" "$staging/licenses/COPYING.GPLv3.txt"
    Copy-RequiredFile "$root/licenses/providers/$classifier.txt" "$staging/licenses/UPSTREAM-NOTICE.txt"
    $metadata = @(
        "artifact.version=$version", 
        "classifier=$classifier", 
        "ffmpeg.version=$($upstreamConfig['ffmpeg.version'])"
    )
    # BtbN bundles both tools together; Martin Riedl supplies a separate ZIP per tool.
    if ($classifier.StartsWith('macos-')) {
        $metadata += 'upstream.provider=Martin Riedl'
    } else {
        $extension = if ($platform.Suffix) { 'zip' } else { 'tar.xz' }
        $extracted = Expand-VerifiedArchive $prefix "$work/$classifier/source" $extension
        $binaryDirectory = Join-Path $extracted $upstreamConfig["$prefix.path"]
        # BtbN puts its license beside the bin directory containing both executables.
        Copy-RequiredFile "$binaryDirectory/../LICENSE.txt" "$staging/licenses/UPSTREAM-LICENSE.txt"
        $metadata += 'upstream.provider=BtbN'
    }
    # Stage only the expected executable paths and record hashes without modifying binaries.
    foreach ($tool in @('ffmpeg', 'ffprobe')) {
        $toolPrefix = $prefix
        if ($classifier.StartsWith('macos-')) {
            $toolPrefix = "$prefix.$tool"
            $extracted = Expand-VerifiedArchive $toolPrefix "$work/$classifier/$tool" 'zip'
            $binaryDirectory = Join-Path $extracted $upstreamConfig["$toolPrefix.path"]
        }
        $source = Join-Path $binaryDirectory "$tool$($platform.Suffix)"
        $destination = "$staging/bin/$tool$($platform.Suffix)"
        Copy-RequiredFile $source $destination
        $hash = (Get-FileHash $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        $metadata += "$tool.sha256=$hash", "$tool.archive.url=$($upstreamConfig["$toolPrefix.url"])", "$tool.archive.sha256=$($upstreamConfig["$toolPrefix.sha256"])"
    }
    # Include source instructions and provenance; use BOM-free UTF-8 and LF for metadata.
    # Copy-RequiredFile "$root/SOURCES.md" "$staging/SOURCES.md"
    [System.IO.File]::WriteAllText("$staging/build-info.properties", ($metadata -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
    # Create the classifier ZIP using current timestamps; checksums identify this build's artifacts.
    $name = "ffmpeg-$version-$classifier.zip"
    $zip = [System.IO.Compression.ZipFile]::Open("$output/$name", [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in (Get-ChildItem -File -Recurse $staging | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($staging.Length + 1).Replace('\', '/')
            $entry = $zip.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::UtcNow
            # ZIP high-word Unix modes: regular file 0755 for Unix tools, otherwise 0644.
            # Set entry metadata before opening its stream, then copy executable bytes unchanged.
            $entry.ExternalAttributes = if ($relative.StartsWith('bin/') -and !$platform.Suffix) { -2115174400 } else { -2119958528 }
            $sourceStream = $file.OpenRead()
            $entryStream = $entry.Open()
            try { $sourceStream.CopyTo($entryStream) } finally {
                $entryStream.Dispose()
                $sourceStream.Dispose()
            }
        }
    } finally { $zip.Dispose() }
    # Hash the finished archive for integrity checks after transfer between CI jobs.
    $hash = (Get-FileHash "$output/$name" -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksums += "$hash  $name"
    Write-Host "Packaged $name"
}
# Publish one checksum manifest covering all four classifier ZIPs.
[System.IO.File]::WriteAllText("$output/SHA256SUMS", ($checksums -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))