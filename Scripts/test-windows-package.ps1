param([ValidateSet('x64', 'arm64')][string]$Architecture)

$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ACTIONS -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'Run the installer smoke test on a disposable GitHub Actions runner.' }

$Repository = Split-Path -Parent $PSScriptRoot
$Setup = Join-Path $Repository "dist\windows\SpaceTrail-Setup-$Architecture.exe"
$Install = Join-Path $env:LOCALAPPDATA 'Programs\SpaceTrail'
$App = Join-Path $Install 'SpaceTrail.exe'
$Uninstall = Join-Path $Install 'Uninstall.exe'
$LegacyAppData = Join-Path $env:RUNNER_TEMP 'SpaceTrail upgrade profile'
$NewAppData = Join-Path $env:RUNNER_TEMP 'SpaceTrail first run profile'
$Support = Join-Path $LegacyAppData 'SpaceTrail'
$Settings = Join-Path $Support 'settings.json'
$Scan = Join-Path $env:RUNNER_TEMP 'SpaceTrail sample files'
$Shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'SpaceTrail.lnk'
$AppsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SpaceTrail'
$StartKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Run-Checked($File, $Arguments) {
    $Process = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -Wait
    if ($Process.ExitCode -ne 0) { throw "$File returned exit code $($Process.ExitCode)." }
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

function Wait-For($Condition, $Description) {
    $Deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        $Result = & $Condition
        if ($Result) { return $Result }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $Deadline)
    throw "Timed out waiting for $Description."
}

function Named($Window, $Name) {
    $Condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Condition)
}

function Invoke-Control($Control) {
    $Control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Start-Desktop($AppData) {
    $Original = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $AppData
        Start-Process -FilePath $App -PassThru
    } finally {
        $env:LOCALAPPDATA = $Original
    }
}

function Find-Window($Process) {
    Wait-For {
        $Process.Refresh()
        if ($Process.HasExited) { throw "Desktop exited with code $($Process.ExitCode)." }
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
        }
    } 'the installed SpaceTrail window'
}

function Show-Window-Diagnostics($Window) {
    if (-not $Window) { return }
    $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
        Select-Object -First 65 | ForEach-Object { Write-Output "UI: $($_.Current.Name) ($($_.Current.ControlType.ProgrammaticName))" }
}

function Test-Search($Window) {
    $Search = @(Wait-For { Named $Window 'Search' } 'the Search view button')[0]
    Invoke-Control $Search
    $Box = @(Wait-For {
        Named $Window 'Search by name' |
            Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit }
    } 'the search field')[0]
    $Box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('Field notes')
    $Submit = @(Named $Window 'Search')[-1]
    Invoke-Control $Submit
    Wait-For {
        $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition) |
            Where-Object { $_.Current.Name -like 'Field notes.pdf*' } |
            Select-Object -First 1
    } 'the saved search result' | Out-Null
}

function Assert-Install($Version) {
    if (-not (Test-Path -LiteralPath $App)) { throw 'The application was not installed.' }
    if (-not (Test-Path -LiteralPath $Shortcut)) { throw 'The Start menu shortcut is missing.' }
    if ((Get-ItemProperty -LiteralPath $AppsKey).DisplayVersion -ne $Version) {
        throw "The Installed Apps entry did not record version $Version."
    }
}

function Startup-Entry {
    (Get-ItemProperty -LiteralPath $StartKey -ErrorAction SilentlyContinue).SpaceTrail
}

function Choose-Startup($Window, $Choice) {
    Wait-For { Named $Window 'Open SpaceTrail at sign-in?' } 'the first-launch sign-in prompt' | Out-Null
    $Button = @(Wait-For { Named $Window $Choice } "the $Choice button")[0]
    Invoke-Control $Button
    Wait-For { -not (Named $Window 'Open SpaceTrail at sign-in?') } 'the sign-in prompt to close' | Out-Null
}

$OldSetup = Join-Path $env:RUNNER_TEMP "SpaceTrail-0.3.0-$Architecture.exe"
Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/saropuglisi/SpaceTrail/releases/download/windows-v0.3.0/SpaceTrail-Setup-$Architecture.exe" -OutFile $OldSetup
$ExpectedHash = if ($Architecture -eq 'x64') {
    'f56468246f1a6fbf6e370fc6da757d77152828fa1361a6a6ed713c3277ffe72f'
} else {
    'd8f4a9074e7afa4a00925bd8505c0842c37b024a270da07d336886ac0c73998f'
}
if ((Get-FileHash -LiteralPath $OldSetup -Algorithm SHA256).Hash -ne $ExpectedHash) {
    throw 'The previous installer did not match the released checksum.'
}
Run-Checked $OldSetup '/S'
Assert-Install '0.3.0'

New-Item -ItemType Directory -Path $Scan, $Support -Force | Out-Null
Set-Content -LiteralPath (Join-Path $Scan 'Field notes.pdf') -Value '%PDF-1.7'
Set-Content -LiteralPath (Join-Path $Scan 'Project notes.txt') -Value 'A fixture for Windows Search.'
Run-Checked $App @('--scan-once', ('"{0}"' -f $Scan), ('"{0}"' -f $Support))
$FixtureSettings = @{root = '\\?\' + $Scan} | ConvertTo-Json -Compress
[IO.File]::WriteAllText($Settings, $FixtureSettings, [Text.UTF8Encoding]::new($false))
New-Item -Path $StartKey -Force | Out-Null
Set-ItemProperty -Path $StartKey -Name 'SpaceTrail' -Value '"C:\Portable\SpaceTrail-x64.exe" --broker'
$OldProcess = Start-Desktop $LegacyAppData
$OldWindow = Find-Window $OldProcess
Wait-For { Named $OldWindow 'Search by name' } 'the 0.3.0 desktop before updating' | Out-Null
Run-Checked $Setup '/S'
$Version = [regex]::Match((Get-Content (Join-Path $Repository 'windows\Cargo.toml') -Raw), '(?m)^version = "([0-9.]+)"').Groups[1].Value
Assert-Install $Version
$OldProcess.Refresh()
if (-not $OldProcess.HasExited) { throw 'Setup left the old desktop running.' }
$BackgroundEntry = '"{0}" --broker' -f $App
$WindowEntry = '"{0}"' -f $App
if ((Startup-Entry) -ne $BackgroundEntry) {
    throw 'Setup did not migrate the existing sign-in entry.'
}
$Window = $null
try {
    $Process = Start-Desktop $LegacyAppData
    $Window = Find-Window $Process
    Choose-Startup $Window 'Not Now'
    if ((Startup-Entry) -ne $BackgroundEntry) { throw 'Declining window startup changed the existing background entry.' }
    Test-Search $Window
    Invoke-Control (@(Named $Window 'Settings')[0])
    Wait-For { Named $Window 'Scan all drives' } 'the previous folder scope in Settings' | Out-Null
} catch {
    Show-Window-Diagnostics $Window
    throw
} finally {
    Run-Checked $App '--shutdown'
}
Write-Output 'In-place update from 0.3.0, saved index search, and background-only startup verified.'

Run-Checked $Uninstall '/S'
if (Startup-Entry) { throw 'Uninstall left the background sign-in entry registered.' }
Run-Checked $Setup '/S'
Assert-Install $Version
if (Startup-Entry) { throw 'A fresh install registered startup before the user answered.' }

$Window = $null
try {
    $Process = Start-Desktop $NewAppData
    $Window = Find-Window $Process
    Choose-Startup $Window 'Open at Sign-in'
    if ((Startup-Entry) -ne $WindowEntry) { throw 'Opting in did not register the desktop window for sign-in.' }
    Wait-For { Named $Window 'First Scan' } 'the automatic first scan' | Out-Null
    $Fixed = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })
    if ($Fixed.Count -lt 1) { throw 'The test host has no readable fixed drive.' }
    foreach ($Drive in $Fixed) {
        $DriveName = $Drive.Name.Substring(0, 2)
        Wait-For {
            $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition) |
                Where-Object { $_.Current.Name -like "*($DriveName)" } |
                Select-Object -First 1
        } "scan status for $DriveName" | Out-Null
    }
    Write-Output "Automatic scan verified for $($Fixed.Count) fixed drive(s)."
} catch {
    Show-Window-Diagnostics $Window
    throw
} finally {
    Run-Checked $App '--shutdown'
}

Run-Checked $Setup '/S'
if ((Startup-Entry) -ne $WindowEntry) { throw 'Setup changed the existing window sign-in entry.' }
$Window = $null
try {
    $Process = Start-Desktop $NewAppData
    $Window = Find-Window $Process
    Wait-For { Named $Window 'Search by name' } 'the desktop after opting in' | Out-Null
    Invoke-Control (@(Named $Window 'Settings')[0])
    Wait-For { Named $Window 'When I sign in' } 'the startup setting after relaunch' | Out-Null
    if (Named $Window 'Open SpaceTrail at sign-in?') { throw 'The sign-in prompt appeared again after opting in.' }
} catch {
    Show-Window-Diagnostics $Window
    throw
} finally {
    Run-Checked $App '--shutdown'
}
Write-Output 'First-launch consent and preservation of the window sign-in entry verified.'

Run-Checked $Uninstall '/S'
if ((Test-Path -LiteralPath $App) -or (Test-Path -LiteralPath $Shortcut) -or (Test-Path -LiteralPath $AppsKey)) {
    throw 'Uninstall left the application registered.'
}
if (Startup-Entry) { throw 'Uninstall left the window sign-in entry registered.' }
if (-not (Test-Path -LiteralPath $Settings) -or -not (Test-Path -LiteralPath (Join-Path $Support 'index.sqlite'))) {
    throw 'Uninstall removed saved scan data.'
}
Write-Output 'Installer, update, and uninstall verified.'
