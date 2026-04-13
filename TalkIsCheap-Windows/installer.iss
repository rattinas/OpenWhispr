; TalkIsCheap Windows Installer — Inno Setup Script
; Build with: iscc installer.iss

#define MyAppName "TalkIsCheap"
#define MyAppVersion "2.0.0"
#define MyAppPublisher "TalkIsCheap"
#define MyAppURL "https://talkischeap.app"
#define MyAppExeName "TalkIsCheap.exe"

[Setup]
AppId={{B8F2C3D4-E5A6-4B7C-9D8E-1F2A3B4C5D6E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=output
OutputBaseFilename=TalkIsCheap-Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupIconFile=TalkIsCheap\Resources\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "autostart"; Description: "Start TalkIsCheap when Windows starts"; GroupDescription: "Additional options:"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "TalkIsCheap\dist\TalkIsCheap.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "TalkIsCheap\Resources\icon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: autostart

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch TalkIsCheap"; Flags: nowait postinstall skipifsilent
