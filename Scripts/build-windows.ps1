param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' })
)

$ErrorActionPreference = 'Stop'
$Repository = Split-Path -Parent $PSScriptRoot
$Target = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$Build = Join-Path $Repository 'windows\target'
$Destination = Join-Path $Repository 'dist\windows'
$Manifest = Join-Path $Repository 'windows\Cargo.toml'

$PreviousFlags = $env:RUSTFLAGS
try {
    $env:RUSTFLAGS = "$PreviousFlags -Ctarget-feature=+crt-static".Trim()
    cargo build --release --locked --manifest-path $Manifest --target-dir $Build --target $Target
    if ($LASTEXITCODE -ne 0) { throw "Windows build failed for $Target." }
} finally {
    $env:RUSTFLAGS = $PreviousFlags
}

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$Output = Join-Path $Destination "SpaceTrail-$Architecture.exe"
Copy-Item -LiteralPath (Join-Path $Build "$Target\release\spacetrail.exe") -Destination $Output -Force
Write-Output $Output
