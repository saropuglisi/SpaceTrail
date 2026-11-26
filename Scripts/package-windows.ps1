param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
    [string]$MakeNsis = 'makensis.exe'
)

$ErrorActionPreference = 'Stop'
$Repository = Split-Path -Parent $PSScriptRoot
$Destination = Join-Path $Repository 'dist\windows'
$Package = Join-Path $Repository 'windows\installer\SpaceTrail.nsi'
$Application = Join-Path $Destination "SpaceTrail-$Architecture.exe"
$Installer = Join-Path $Destination "SpaceTrail-Setup-$Architecture.exe"
$Version = [regex]::Match((Get-Content (Join-Path $Repository 'windows\Cargo.toml') -Raw), '(?m)^version = "(\d+\.\d+\.\d+)"').Groups[1].Value

if (-not (Test-Path -LiteralPath $Application)) {
    throw "Build SpaceTrail-$Architecture.exe before packaging."
}
if (-not $Version) { throw 'Could not read the Windows version from Cargo.toml.' }

$Work = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ('SpaceTrail-Setup-' + [guid]::NewGuid()))
try {
    $Bootstrapper = Join-Path $Work 'MicrosoftEdgeWebview2Setup.exe'
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $Bootstrapper
    $Signature = Get-AuthenticodeSignature -LiteralPath $Bootstrapper
    if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch 'CN=Microsoft Corporation(?:,|$)') {
        throw 'The WebView2 bootstrapper did not have a valid Microsoft signature.'
    }
    & $MakeNsis /V3 "/DARCH=$Architecture" "/DVERSION=$Version" "/DAPP_EXE=$Application" "/DOUTPUT=$Installer" "/DWEBVIEW_BOOTSTRAPPER=$Bootstrapper" $Package
    if ($LASTEXITCODE -ne 0) { throw "NSIS failed to build the $Architecture installer." }
    Get-FileHash -Algorithm SHA256 -LiteralPath $Installer
} finally {
    Remove-Item -LiteralPath $Work -Recurse -Force
}
