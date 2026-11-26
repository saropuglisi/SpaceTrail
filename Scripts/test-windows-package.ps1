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

function Test-Window($Mode) {
    $Process = Start-Process -FilePath $App -PassThru
    try {
        $Window = Wait-For {
            $Process.Refresh()
            if ($Process.HasExited) { throw "Desktop exited with code $($Process.ExitCode)." }
            if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
                [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
            }
        } "the installed SpaceTrail window"

        if ($Mode -eq 'first-run') {
            Wait-For { Named $Window 'See what’s using your space' } 'the first-run heading' | Out-Null
            Wait-For { Named $Window 'Start background updates at sign-in' } 'the first-run sign-in option' | Out-Null
        } else {
            Wait-For { Named $Window 'Recent growth' } 'the saved storage overview' | Out-Null
            $Search = @(Wait-For { Named $Window 'Search' } 'the Search view button')[0]
            Invoke-Control $Search
            $Box = @(Wait-For { Named $Window 'Search by name' } 'the search field')[0]
            $Box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('Field notes')
            $Submit = @(Named $Window 'Search')[-1]
            Invoke-Control $Submit
            Wait-For { Named $Window 'Field notes.pdf' } 'the saved search result' | Out-Null
            $SettingsButton = @(Named $Window 'Settings')[0]
            Invoke-Control $SettingsButton
            Wait-For { Named $Window 'Close settings' } 'the settings dialog' | Out-Null
        }
        Write-Output "Installed desktop verified ($Mode)"
    } catch {
        Write-Output "Window title: $($Process.MainWindowTitle)"
        if ($Window) {
            $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                Select-Object -First 50 | ForEach-Object { Write-Output "UI: $($_.Current.Name) ($($_.Current.ControlType.ProgrammaticName))" }
        }
        throw
    } finally {
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
