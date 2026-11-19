#define MyAppName "File Share"
#define MyAppVersion "0.1.0"
#define MyAppExeName "file_share.exe"

[Setup]
AppId={{7D57D58C-FE20-43DA-87C8-36177241320F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=File Share
DefaultDirName={autopf}\File Share
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

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\File Share"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\File Share"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch File Share"; Flags: nowait postinstall skipifsilent
