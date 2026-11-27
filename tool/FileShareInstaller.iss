#define MyAppName "File Share"
#ifndef MyAppVersion
  #define MyAppVersion "0.1.0.1"
#endif
#define MyAppExeName "file_share.exe"

[Setup]
AppId={{7D57D58C-FE20-43DA-87C8-36177241320F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=File Share
DefaultDirName={autopf}\File Share
; Preserve the existing Program Files folder for this stable AppId on upgrades.
UsePreviousAppDir=yes
DefaultGroupName=File Share
OutputDir=..\dist
OutputBaseFilename=FileShare-Windows-Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
DisableProgramGroupPage=yes
SetupLogging=yes
SetupIconFile=..\assets\branding\file_share_tray.ico
CloseApplications=yes
RestartApplications=no

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\assets\branding\file_share_tray.ico"; DestDir: "{app}"; DestName: "FileShare.ico"; Flags: ignoreversion
; Official Microsoft-supported VC++ 2015-2022 x64 runtime is bundled, not
; copied as unmanaged DLLs to System32. Installation is offline/idempotent.
Source: "..\tool\installer-deps\VC_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{group}\File Share"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\FileShare.ico"; AppUserModelID: "FileShare.Desktop"
Name: "{autodesktop}\File Share"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\FileShare.ico"; AppUserModelID: "FileShare.Desktop"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Code]
// The current supported x64 VC runtime is needed for native Flutter/plugin
// libraries. Inno installs the official signed runtime only when missing;
// do not manually place Microsoft CRT DLLs into Windows system directories.
function MicrosoftVCRuntimeInstalled(): Boolean;
var
  Installed: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM64,
    'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
    'Installed', Installed) and (Installed = 1);
end;

[Run]
Filename: "{tmp}\VC_redist.x64.exe"; Parameters: "/install /quiet /norestart"; \
  StatusMsg: "Installing required Microsoft Visual C++ runtime..."; \
  Flags: waituntilterminated; Check: not MicrosoftVCRuntimeInstalled
Filename: "{app}\{#MyAppExeName}"; Description: "Launch File Share"; Flags: nowait postinstall skipifsilent
