param([ValidateSet('x64', 'arm64')][string]$Architecture)

$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ACTIONS) { throw 'Run the installer smoke test on a disposable GitHub Actions runner.' }

$Repository = Split-Path -Parent $PSScriptRoot
$Setup = Join-Path $Repository "dist\windows\SpaceTrail-Setup-$Architecture.exe"
$Install = Join-Path $env:LOCALAPPDATA 'Programs\SpaceTrail'
$App = Join-Path $Install 'SpaceTrail.exe'
$Uninstall = Join-Path $Install 'Uninstall.exe'
$Support = Join-Path $env:LOCALAPPDATA 'SpaceTrail'
$Settings = Join-Path $Support 'settings.json'
$Scan = Join-Path $env:RUNNER_TEMP 'SpaceTrail sample files'
$Shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'SpaceTrail.lnk'
$AppsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SpaceTrail'
$StartKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Run-Checked($File, $Arguments) {
    $Process = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -Wait
    if ($Process.ExitCode -ne 0) { throw "$File returned exit code $($Process.ExitCode)." }
}

function Test-Window($Mode) {
    $Port = Get-Random -Minimum 18200 -Maximum 19900
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$Port"
    Start-Process -FilePath $App
    try {
        node (Join-Path $PSScriptRoot 'test-windows-ui.mjs') $Port $Mode
        if ($LASTEXITCODE -ne 0) { throw "SpaceTrail desktop check failed in $Mode." }
    } finally {
        Remove-Item Env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
        Run-Checked $App '--shutdown'
    }
}

Run-Checked $Setup '/S'
if (-not (Test-Path -LiteralPath $App)) { throw 'The application was not installed.' }
if (-not (Test-Path -LiteralPath $Shortcut)) { throw 'The Start menu shortcut is missing.' }
if ((Get-ItemProperty -LiteralPath $AppsKey).DisplayName -ne 'SpaceTrail') { throw 'The Installed Apps entry is missing.' }
Test-Window 'first-run'

New-Item -ItemType Directory -Path $Scan, $Support -Force | Out-Null
Set-Content -LiteralPath (Join-Path $Scan 'Field notes.pdf') -Value '%PDF-1.7'
Set-Content -LiteralPath (Join-Path $Scan 'Project notes.txt') -Value 'A fixture for Windows Search.'
Run-Checked $App @('--scan-once', ('"{0}"' -f $Scan), ('"{0}"' -f $Support))
@{root = '\\?\' + $Scan} | ConvertTo-Json -Compress | Set-Content -LiteralPath $Settings -Encoding utf8NoBOM
New-Item -Path $StartKey -Force | Out-Null
Set-ItemProperty -Path $StartKey -Name 'SpaceTrail' -Value '"C:\Portable\SpaceTrail-x64.exe" --broker'
Run-Checked $Setup '/S'
if ((Get-ItemProperty -LiteralPath $StartKey).SpaceTrail -ne ('"{0}" --broker' -f $App)) {
    throw 'Setup did not migrate the existing sign-in entry.'
}
Test-Window 'saved-index'

Run-Checked $Uninstall '/S'
if ((Test-Path -LiteralPath $App) -or (Test-Path -LiteralPath $Shortcut) -or (Test-Path -LiteralPath $AppsKey)) {
    throw 'Uninstall left the application registered.'
}
if ((Get-ItemProperty -LiteralPath $StartKey).SpaceTrail) { throw 'Uninstall left the sign-in entry registered.' }
if (-not (Test-Path -LiteralPath $Settings) -or -not (Test-Path -LiteralPath (Join-Path $Support 'index.sqlite'))) {
    throw 'Uninstall removed saved scan data.'
}
Write-Output 'Installer, update, and uninstall verified.'
