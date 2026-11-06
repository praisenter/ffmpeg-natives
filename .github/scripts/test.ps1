# Always check the selected ZIP; omit ArchiveOnly to also execute its native binaries.
param(
    [Parameter(Mandatory)]
    [ValidateSet('windows-x86_64', 'linux-x86_64', 'macos-x86_64', 'macos-aarch64')]
    [string] $Classifier,
    [switch] $ArchiveOnly
)

# Locate the artifacts using the checked-out Maven version, independent of the working directory.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = (Resolve-Path "$PSScriptRoot/../..").Path
[xml] $pom = Get-Content "$root/pom.xml"
$name = "ffmpeg-$($pom.project.version)-$Classifier.zip"
$directory = "$root/target/distributions"
# Require exactly one manifest entry and verify the transferred ZIP before opening it.
$lines = @(Get-Content "$directory/SHA256SUMS" | Where-Object { $_.EndsWith("  $name") })
if ($lines.Count -ne 1 -or (Get-FileHash "$directory/$name" -Algorithm SHA256).Hash -ne $lines[0].Split(' ')[0]) {
    throw "Archive checksum missing or incorrect: $name"
}
$suffix = if ($Classifier.StartsWith('windows-')) { '.exe' } else { '' }
$expected = @('build-info.properties', 'licenses/COPYING.GPLv3.txt', 'licenses/UPSTREAM-NOTICE.txt', "bin/ffmpeg$suffix", "bin/ffprobe$suffix")
if (!$Classifier.StartsWith('macos-')) { $expected += 'licenses/UPSTREAM-LICENSE.txt' }
$zip = [System.IO.Compression.ZipFile]::OpenRead("$directory/$name")
try {
    # Enforce the complete archive layout, including notices, with no extra or duplicate entries.
    if ($zip.Entries.Count -ne $expected.Count -or (Compare-Object @($zip.Entries.FullName) $expected)) {
        throw "Unexpected, missing or duplicate ZIP entries: $name"
    }
    # Verify the common license and this platform's notice against their repository originals.
    $noticeSources = @{
        'licenses/COPYING.GPLv3.txt' = "$root/licenses/COPYING.GPLv3.txt"
        'licenses/UPSTREAM-NOTICE.txt' = "$root/licenses/providers/$Classifier.txt"
    }
    foreach ($path in $noticeSources.Keys) {
        $reader = [System.IO.StreamReader]::new($zip.GetEntry($path).Open())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ([string]::IsNullOrWhiteSpace($text) -or $text -cne [System.IO.File]::ReadAllText($noticeSources[$path])) {
            throw "Incorrect license or platform notice: $path"
        }
    }
    if (!$Classifier.StartsWith('macos-') -and $zip.GetEntry('licenses/UPSTREAM-LICENSE.txt').Length -eq 0) {
        throw 'Missing original upstream license'
    }
    # Check embedded identity before using its per-executable hashes and FFmpeg version.
    $reader = [System.IO.StreamReader]::new($zip.GetEntry('build-info.properties').Open())
    try { $metadata = $reader.ReadToEnd() | ConvertFrom-StringData } finally { $reader.Dispose() }
    if ($metadata['classifier'] -ne $Classifier -or $metadata['artifact.version'] -ne [string] $pom.project.version) {
        throw 'Incorrect archive classifier/version metadata'
    }
    # Check nonempty executables, Unix mode 0755 (decimal 493), and their recorded SHA-256 values.
    foreach ($tool in @('ffmpeg', 'ffprobe')) {
        $entry = $zip.GetEntry("bin/$tool$suffix")
        if ($entry.Length -lt 64) { throw "Truncated executable: $tool" }
        if (!$suffix -and (($entry.ExternalAttributes -shr 16) -band 511) -ne 493) {
            throw "Incorrect executable permissions: $tool"
        }
        $stream = $entry.Open()
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() } finally {
            $stream.Dispose()
            $algorithm.Dispose()
        }
        if ($hash -ne $metadata["$tool.sha256"]) { throw "Executable checksum mismatch: $tool" }
    }
} finally { $zip.Dispose() }
Write-Host "Verified $name"
# Archive-only checks can run on any platform without launching foreign executables.
if ($ArchiveOnly) { return }

# Capture both output streams and fail on nonzero exit codes. Windows PowerShell
# treats native stderr as error records, even for successful FFmpeg version output.
function Invoke-Tool([string] $Executable, [string[]] $Arguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $text = & $Executable @Arguments 2>&1 | ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($exitCode -ne 0) { throw "Command failed: $Executable`n$($text -join "`n")" }
    return ($text -join "`n")
}

# Native checks use the Maven fixture's extracted files, including its path with spaces.
# CI chooses a matching runner; this section must run on the classifier's actual platform.
$tools = "$root/src/it/consumer/target/native tools"
foreach ($tool in @('ffmpeg', 'ffprobe')) {
    $executable = "$tools/bin/$tool$suffix"
    if ((Get-FileHash $executable -Algorithm SHA256).Hash -ne $metadata["$tool.sha256"]) {
        throw "Maven unpacking changed executable bytes: $tool"
    }
    # Restore executable permissions if extraction lost them, then verify version and license output.
    if (!$suffix) { Invoke-Tool 'chmod' @('755', $executable) | Out-Null }
    $version = Invoke-Tool $executable @('-version')
    $expectedVersion = [regex]::Escape($metadata['ffmpeg.version'])
    if ($version.Split("`n")[0] -notmatch "^$tool version n?$expectedVersion(?=[^\d.]|$)" -or $version.Contains('--enable-nonfree')) {
        throw "Unexpected version or unredistributable build: $tool"
    }
    $license = Invoke-Tool $executable @('-L')
    if (!$license.Contains('General Public License') -or $license.Contains('nonfree and unredistributable')) {
        throw "Unexpected binary license: $tool"
    }
    Write-Host $version.Split("`n")[0]
    # Check macOS signatures/portable library paths or missing Linux shared-library dependencies.
    if ($Classifier.StartsWith('macos-')) {
        Invoke-Tool 'codesign' @('--verify', '--strict', $executable) | Out-Null
        $libraries = Invoke-Tool 'otool' @('-L', $executable)
        Write-Host $libraries
        if (($libraries -split "`n" | Select-Object -Skip 1) -match '/(opt/homebrew|usr/local|Users)/') {
            throw 'Nonportable macOS library dependency'
        }
    } elseif ($Classifier.StartsWith('linux-')) {
        $libraries = Invoke-Tool 'ldd' @($executable)
        Write-Host $libraries
        if ($libraries.Contains('not found')) { throw 'Missing Linux runtime library' }
    }
}
# Exercise both programs together: encode one H.264 frame and inspect FFprobe's JSON metadata.
$media = "$tools/sample media.mp4"
try {
    Invoke-Tool "$tools/bin/ffmpeg$suffix" @('-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc2=size=32x32:rate=1', '-frames:v', '1', '-c:v', 'libx264', $media) | Out-Null
    $probe = Invoke-Tool "$tools/bin/ffprobe$suffix" @('-v', 'error', '-show_entries', 'stream=codec_name,width,height', '-of', 'json', $media)
    $streams = @((ConvertFrom-Json $probe).streams)
    if ($streams.Count -ne 1 -or $streams[0].codec_name -ne 'h264' -or $streams[0].width -ne 32 -or $streams[0].height -ne 32) {
        throw 'H.264 encode/probe round-trip failed'
    }
} finally { if (Test-Path $media) { Remove-Item $media } }
Write-Host "Native smoke test passed: $Classifier"