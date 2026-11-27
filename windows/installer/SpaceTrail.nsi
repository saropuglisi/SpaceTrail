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
!define MUI_WELCOMEPAGE_TITLE "Set up SpaceTrail"
!define MUI_WELCOMEPAGE_TEXT "Install or update SpaceTrail for your Windows account. Setup closes any running copy and keeps your saved index.$\r$\n$\r$\nNew installations start indexing local drives automatically."
!define MUI_FINISHPAGE_TITLE "SpaceTrail is installed"
!define MUI_FINISHPAGE_TEXT "Open SpaceTrail to view your files and scan progress. SpaceTrail continues indexing in the notification area."
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
  ClearErrors
  ExecWait '"$PLUGINSDIR\SpaceTrail.exe" --shutdown' $0
  ${If} ${Errors}
  ${OrIf} $0 != 0
    SetErrorLevel 1
    Abort "Close SpaceTrail before running setup."
  ${EndIf}

  SetOutPath "$INSTDIR"
  ClearErrors
  File "/oname=SpaceTrail.next" "${APP_EXE}"
  ${If} ${Errors}
    SetErrorLevel 1
    Abort "SpaceTrail could not be copied to $INSTDIR."
  ${EndIf}
  ; Replace the executable in place only after staging the complete new file.
  System::Call 'kernel32::MoveFileExW(w "$INSTDIR\SpaceTrail.next", w "$INSTDIR\SpaceTrail.exe", i 9) i .r0'
  ${If} $0 == 0
    Delete "$INSTDIR\SpaceTrail.next"
    SetErrorLevel 1
    Abort "SpaceTrail could not be updated. Close any open copies and run setup again."
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
  StrCpy $1 $0 9 -9
  StrCpy $2 $0 1 -1
  ${If} $1 == " --broker"
    WriteRegStr HKCU "${STARTUP_KEY}" "SpaceTrail" '"$INSTDIR\SpaceTrail.exe" --broker'
  ${ElseIf} $2 == '"'
    WriteRegStr HKCU "${STARTUP_KEY}" "SpaceTrail" '"$INSTDIR\SpaceTrail.exe"'
  ${EndIf}
  IfSilent done
  Exec '"$INSTDIR\SpaceTrail.exe" --broker'
done:
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
  ${OrIf} $0 == '"$INSTDIR\SpaceTrail.exe"'
    DeleteRegValue HKCU "${STARTUP_KEY}" "SpaceTrail"
  ${EndIf}
  Delete "$SMPROGRAMS\SpaceTrail.lnk"
  Delete "$INSTDIR\SpaceTrail.next"
  Delete "$INSTDIR\SpaceTrail.exe"
  Delete "$INSTDIR\Uninstall.exe"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  RMDir "$INSTDIR"
SectionEnd
