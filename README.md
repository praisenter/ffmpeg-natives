# Praisenter FFmpeg Binaries

Binary-only Maven distribution of FFmpeg and FFprobe. No JNI, Java runtime
library, or ffplay are included.  FFmpeg/FFprobe binaries are downloaded 
during build from the sources provided in `upstream.properties`

## Artifacts

Coordinates: `org.praisenter:ffmpeg:8.1-1`, type `zip`.

| Classifier | Platform | Upstream |
| --- | --- | --- |
| `windows-x86_64` | Windows x64 | BtbN |
| `linux-x86_64` | Linux x64, glibc (not Alpine/musl) | BtbN |
| `macos-x86_64` | macOS Intel | Martin Riedl |
| `macos-aarch64` | macOS Apple Silicon / ARM64 | Martin Riedl |

Each ZIP has this layout, without an extra enclosing directory:

```text
bin/ffmpeg[.exe]
bin/ffprobe[.exe]
licenses/COPYING.GPLv3.txt
licenses/UPSTREAM-NOTICE.txt
build-info.properties
SOURCES.md
```

The common GPL text comes from [licenses/COPYING.GPLv3.txt](licenses/COPYING.GPLv3.txt).
Each ZIP includes its own provenance notice from the matching file under
`licenses/providers`. Windows/Linux ZIPs additionally retain their archive's original 
license as `licenses/UPSTREAM-LICENSE.txt`. The macOS downloads do not contain 
a license document. Common license text and these packaging-maintained provenance notices
do not replace the required build-specific license/dependency/source audit.

The POM owns all four attached classifier ZIPs; there is no unclassified JAR.
Select both `type=zip` and the desired classifier. Maven does not automatically
choose a classifier from the host OS/CPU. Consumers can use their own Maven
profiles or a CI matrix to set the classifier explicitly.

Unpack the selected artifact with Maven Dependency Plugin before running your
application packager. Include the complete extracted directory, including notices,
in the package, and execute the tool by its absolute filesystem path
using `ProcessBuilder`. Do not add these ZIPs to the Java classpath/module path.
Unix executables carry mode `0755`; restore that mode during packaging if the
consumer's extraction/copy tooling loses it. Never set world-writable permissions.
macOS application signing/notarization remains the packager's responsibility.
The macOS executable bytes and upstream signatures are preserved, not re-signed.

## Build Responsibilities

GitHub Actions handles packaging and testing. Maven only attaches the prepared
ZIPs, installs them locally, and signs/publishes them when.

- [.github/scripts/package.ps1](.github/scripts/package.ps1): download the six
   locked archives, verify SHA-256 before extraction, stage files and produce four
   ZIPs plus `SHA256SUMS` under `target/distributions`. Each run starts fresh.
- [.github/scripts/test.ps1](.github/scripts/test.ps1): check archive layout,
   metadata, hashes and Unix modes, then optionally run native smoke tests.
- [pom.xml](pom.xml): artifact coordinates, four ZIP attachments and an optional
   release profile. It does not download binaries or construct ZIPs.
- [src/it/consumer/pom.xml](src/it/consumer/pom.xml): a small test fixture using
   Maven Dependency Plugin to resolve/unpack one classifier, not application code.

For a local Windows development build, run these from PowerShell:

```powershell
./.github/scripts/package.ps1
mvn -B -ntp install
mvn -B -ntp -f src/it/consumer/pom.xml clean verify -Dffmpeg.classifier=windows-x86_64
./.github/scripts/test.ps1 -Classifier windows-x86_64
```

GitHub uses PowerShell 7 (`pwsh`), Java 25 and Maven 3.9+ (not Maven 4). Local
Windows PowerShell 5.1 is also supported. Packaging needs `tar` for the Linux
archive and HTTPS access to the upstream providers. No FFmpeg compiler is needed.
The scripts can be run locally but are not part of the Maven lifecycle. Do not
run `mvn clean` after packaging: that would delete the prepared ZIPs.

The native test executes the Maven-unpacked binaries from a path containing
spaces, checks version/license output, then encodes and probes a tiny H.264
video. Override `ffmpeg.artifact.version` in the fixture for another version.

## Updating Inputs

[upstream.properties](upstream.properties) contains `ffmpeg.version` and the
URL, SHA-256 and executable directory (`.path`) for each of the six archives.
Paths are relative to the extracted archive; use forward slashes and `.` when
the executables are at the archive's top level. Absolute paths and `..` segments
are rejected. For example:

```properties
ffmpeg.windows.path=ffmpeg-n8.1-7-ga3475e2554-win64-gpl-8.1/bin
ffmpeg.macos.x64.ffmpeg.path=.
ffmpeg.macos.x64.ffprobe.path=.
```

Windows/Linux intentionally
use the approved `n8.1-7-ga3475e2554` branch build, seven commits after 8.1; macOS
uses the original 8.1 builds. Each ZIP records its provider, FFmpeg version,
archive URLs and archive/executable hashes in `build-info.properties`, without
separate upstream build/revision fields. Providers do not necessarily contain
identical codecs.

Resolve a dated release, verify its published checksum, inspect its exact archive
member paths, build configuration, architecture and licensing, then update the
URL, checksum and `.path` values in the properties file. BtbN's original
`LICENSE.txt` is expected one directory above its executable directory; update
the packaging script if that provider's license layout changes.
Never silently substitute latest/master, a new patch release, shared or nonfree
builds. Preserve corresponding sources and verified original archives in durable
storage: BtbN retains monthly builds for two years, not indefinitely. A vanished
or changed input fails the build rather than falling back to another binary.

BtbN currently documents Windows 10 22H2+ support and Linux glibc 2.28+/kernel
4.18+. macOS minimum versions must be confirmed from the pinned executables on
the deployment baseline; a passing macOS 15 CI job alone does not establish an
older minimum. Martin Riedl plans to stop Intel release builds in January 2027.

## GitHub Actions

[.github/workflows/verify.yml](.github/workflows/verify.yml) builds on Ubuntu,
checks all four archives and their integrity checksums, then
runs the exact artifacts on Windows x64, Linux x64, macOS Intel and macOS ARM64.
The native jobs assert the runner architecture; they do not run ARM binaries
under Rosetta. macOS jobs also verify signatures and library paths, and Linux
checks for missing shared libraries. Runner availability and all native jobs
must pass before a release. Pull-request verification needs no publishing secrets.

[.github/workflows/release.yml](.github/workflows/release.yml) is manually
dispatched with a reviewed existing tag such as `v8.1-1`. It runs the complete
verification workflow first, then downloads and checks the exact tested ZIPs
before signing/uploading to Central, without rebuilding. Configure required reviewers on the
`maven-central` GitHub environment and protect release tags.
