Unicode true
RequestExecutionLevel user
SetCompressor /SOLID lzma
Name "SpaceTrail"
OutFile "${OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\SpaceTrail"
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "SpaceTrail"
VIAddVersionKey "FileDescription" "SpaceTrail for Windows Setup"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "SpaceTrail contributors"

!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"

!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\SpaceTrail"
!define STARTUP_KEY "Software\Microsoft\Windows\CurrentVersion\Run"
!define WEBVIEW_KEY "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

!define MUI_ICON "..\assets\spacetrail.ico"
!define MUI_UNICON "..\assets\spacetrail.ico"
!define MUI_WELCOMEFINISHPAGE_BITMAP "welcome.bmp"
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "Install SpaceTrail"
!define MUI_WELCOMEPAGE_TEXT "SpaceTrail shows what is using space on your PC and keeps the results up to date.$\r$\n$\r$\nSetup installs SpaceTrail for your Windows account and adds it to the Start menu."
!define MUI_FINISHPAGE_TITLE "SpaceTrail is installed"
!define MUI_FINISHPAGE_TEXT "Open SpaceTrail to choose a drive or folder. If you have used SpaceTrail before, SpaceTrail will open your saved index."
!define MUI_FINISHPAGE_RUN "$INSTDIR\SpaceTrail.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Open SpaceTrail"
!define MUI_UNCONFIRMPAGE_TEXT_TOP "This removes SpaceTrail, its Start menu shortcut, and its sign-in entry. Saved scan data remains in your Local AppData folder."

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  SetShellVarContext current
!if "${ARCH}" == "arm64"
  ${IfNot} ${IsNativeARM64}
    MessageBox MB_ICONSTOP|MB_OK "Download SpaceTrail-Setup-x64.exe for an Intel or AMD PC." /SD IDOK
    SetErrorLevel 1
    Abort
  ${EndIf}
!else
  ${IfNot} ${IsNativeAMD64}
    MessageBox MB_ICONSTOP|MB_OK "Download SpaceTrail-Setup-arm64.exe for a Windows on Arm PC." /SD IDOK
    SetErrorLevel 1
    Abort
  ${EndIf}
!endif
  SetRegView 64
FunctionEnd

Function EnsureWebView
  SetRegView 32
  ReadRegStr $0 HKLM "${WEBVIEW_KEY}" "pv"
  SetRegView 64
  ReadRegStr $1 HKCU "${WEBVIEW_KEY}" "pv"
  ${If} $0 != ""
  ${AndIf} $0 != "0.0.0.0"
    Return
  ${EndIf}
  ${If} $1 != ""
  ${AndIf} $1 != "0.0.0.0"
    Return
  ${EndIf}

  DetailPrint "Installing Microsoft Edge WebView2 Runtime"
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  File "/oname=WebView2Setup.exe" "${WEBVIEW_BOOTSTRAPPER}"
  ExecWait '"$PLUGINSDIR\WebView2Setup.exe" /silent /install' $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP|MB_OK "WebView2 could not be installed. Check your internet connection, then run SpaceTrail Setup again." /SD IDOK
    SetErrorLevel 1
    Abort
  ${EndIf}
FunctionEnd

Section "SpaceTrail"
  Call EnsureWebView
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  File "/oname=SpaceTrail.exe" "${APP_EXE}"
  DetailPrint "Closing any running copy of SpaceTrail"
  ExecWait '"$PLUGINSDIR\SpaceTrail.exe" --shutdown' $0
  ${If} $0 != 0
    SetErrorLevel 1
    Abort "Close SpaceTrail before running setup."
  ${EndIf}

  SetOutPath "$INSTDIR"
  ClearErrors
  CopyFiles /SILENT "$PLUGINSDIR\SpaceTrail.exe" "$INSTDIR"
  ${If} ${Errors}
    SetErrorLevel 1
    Abort "SpaceTrail could not be copied to $INSTDIR."
  ${EndIf}
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortcut "$SMPROGRAMS\SpaceTrail.lnk" "$INSTDIR\SpaceTrail.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "SpaceTrail"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "SpaceTrail contributors"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\SpaceTrail.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  ReadRegStr $0 HKCU "${STARTUP_KEY}" "SpaceTrail"
  ${If} $0 != ""
    WriteRegStr HKCU "${STARTUP_KEY}" "SpaceTrail" '"$INSTDIR\SpaceTrail.exe" --broker'
  ${EndIf}
SectionEnd

Function un.onInit
  SetShellVarContext current
  SetRegView 64
FunctionEnd

Section "Uninstall"
  ExecWait '"$INSTDIR\SpaceTrail.exe" --shutdown' $0
  ${If} $0 != 0
    SetErrorLevel 1
    Abort "Close SpaceTrail before uninstalling."
  ${EndIf}
  ReadRegStr $0 HKCU "${STARTUP_KEY}" "SpaceTrail"
  ${If} $0 == '"$INSTDIR\SpaceTrail.exe" --broker'
    DeleteRegValue HKCU "${STARTUP_KEY}" "SpaceTrail"
  ${EndIf}
  Delete "$SMPROGRAMS\SpaceTrail.lnk"
  Delete "$INSTDIR\SpaceTrail.exe"
  Delete "$INSTDIR\Uninstall.exe"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  RMDir "$INSTDIR"
SectionEnd
