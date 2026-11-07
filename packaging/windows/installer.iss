#ifndef ProductConfigFile
  #error Build with the generated ProductConfigFile through zig build installer
#endif
#include ProductConfigFile
#ifndef InstalledContextFile
  #error InstalledContextFile is required
#endif
#ifndef InstalledVMManifestFile
  #error InstalledVMManifestFile is required
#endif
#ifndef PortableRoot
  #error PortableRoot is required
#endif

[Setup]
AppId={#ProductAppId}
AppName={#ProductName}
AppVersion={#ProductVersion}
AppPublisher=Cutrans contributors
AppPublisherURL=https://github.com/TLBtianhu/Cutrans
DefaultDirName={localappdata}\Programs\{#ProductName}
DefaultGroupName={#ProductName}
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
DisableReadyPage=yes
ShowLanguageDialog=no
ArchitecturesAllowed=x64compatible and not arm64
ArchitecturesInstallIn64BitMode=x64compatible
SetupArchitecture=x64
OutputDir=..\..\zig-out\installer
OutputBaseFilename={#ProductName}-Setup-{#ProductVersion}-windows-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\app\cutrans_vm.exe
ChangesAssociations=yes
CloseApplications=no
RestartApplications=no
SetupMutex={#ProductId}.setup

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "{#PortableRoot}\runtime\*"; DestDir: "{app}\runtime-envs\default"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PortableRoot}\shell\*"; DestDir: "{app}\shells\desktop"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PortableRoot}\nanoui-library\*"; DestDir: "{app}\shells\nanoui-library"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PortableRoot}\*"; DestDir: "{app}\app"; Excludes: "runtime\*,shell\*,nanoui-library\*,data\*,cutrans-context.json,vm-pack.json"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#InstalledContextFile}"; DestDir: "{app}\app"; DestName: "cutrans-context.json"; Flags: ignoreversion
Source: "{#InstalledVMManifestFile}"; DestDir: "{app}\app"; DestName: "vm-pack.json"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#ProductName}"; Filename: "{app}\app\cutrans_vm.exe"; Parameters: "desktop --mode=installed"; WorkingDir: "{app}\app"; Flags: uninsneveruninstall

[InstallDelete]
Type: files; Name: "{autoprograms}\Cutrans 资源库 (NanoUI).lnk"; Check: ShouldDeleteLegacyShortcut

[Registry]
Root: HKA; Subkey: "Software\Classes\{#ProductExtension}"; ValueType: string; ValueName: ""; ValueData: "{#ProductProgId}"; Check: ShouldAssociateCut
Root: HKA; Subkey: "Software\Classes\{#ProductProgId}"; ValueType: string; ValueName: ""; ValueData: "{#ProductName} Document"
Root: HKA; Subkey: "Software\Classes\{#ProductProgId}\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\app\cutrans_vm.exe"" desktop --mode=installed --open ""%1"""

[Code]
const
  InvalidAttributes = $FFFFFFFF;
  DirectoryAttribute = $10;
  ReparseAttribute = $400;
var
  DiagnosticFailed: Boolean;
  DiagnosticSerial: Integer;
  FailureStage: String;
  UninstallOwned: Boolean;

function GetFileAttributesW(const FileName: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function RegistrationKey: String;
var
  Id: String;
begin
  Id := '{#ProductAppId}';
  if Copy(Id, 1, 2) = '{{' then Delete(Id, 1, 1);
  Result := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + Id + '_is1';
end;

function NormalPath(const Value: String): String;
begin
  Result := ExpandFileName(Value);
  while (Length(Result) > 3) and (Result[Length(Result)] = '\') do
    Delete(Result, Length(Result), 1);
end;

function SafeParents(const Value: String): Boolean;
var
  Current, Parent: String;
  Attributes: Cardinal;
begin
  Result := false;
  Current := NormalPath(Value);
  if (Length(Current) < 3) or (Copy(Current, 2, 2) <> ':\') then exit;
  while Length(Current) > 3 do
  begin
    Attributes := GetFileAttributesW(Current);
    if (Attributes <> InvalidAttributes) and ((Attributes and ReparseAttribute) <> 0) then exit;
    Parent := ExtractFileDir(Current);
    if SameText(Current, Parent) then exit;
    Current := Parent;
  end;
  Result := true;
end;

function ExpectedOpenCommand(const Root: String): String;
begin
  Result := '"' + NormalPath(Root) + '\app\cutrans_vm.exe" desktop --mode=installed --open "%1"';
end;

function OwnsRegistration(const Root: String): Boolean;
var
  RegisteredRoot, Command: String;
begin
  Result := false;
  if not RegQueryStringValue(HKA, RegistrationKey, 'InstallLocation', RegisteredRoot) then exit;
  if not SameText(NormalPath(RegisteredRoot), NormalPath(Root)) then exit;
  if RegQueryStringValue(HKA, 'Software\Classes\{#ProductProgId}\shell\open\command', '', Command) and
     (not SameText(Command, ExpectedOpenCommand(Root))) then exit;
  Result := true;
end;

function PsQuote(const Value: String): String;
begin
  Result := Value;
  StringChange(Result, '''', '''''');
  Result := '''' + Result + '''';
end;

function ShortcutOwned(const Path, Root: String): Boolean;
var
  Shell, Link: Variant;
begin
  Result := false;
  if not FileExists(Path) or not SafeParents(Path) then exit;
  try
    Shell := CreateOleObject('WScript.Shell');
    Link := Shell.CreateShortcut(Path);
    Result := SameText(NormalPath(Link.TargetPath), NormalPath(Root) + '\app\cutrans_vm.exe');
  except
    Log('Shortcut ownership is unavailable; preserving the link');
  end;
end;

function ShouldDeleteLegacyShortcut: Boolean;
begin
  Result := ShortcutOwned(ExpandConstant('{autoprograms}\Cutrans 资源库 (NanoUI).lnk'), ExpandConstant('{app}'));
end;

function BackupSystemState(const Phase: String): Boolean;
var
  Folder, Key, Shortcut, LegacyShortcut: String;
  Code, Serial: Integer;
begin
  Result := false;
  Folder := ExpandConstant('{app}') + '\install-evidence\' + GetDateTimeString('yyyymmdd-hhnnss', '-', '-') + '-' + Phase;
  Serial := 0;
  while DirExists(Folder + '-' + IntToStr(Serial)) do Serial := Serial + 1;
  Folder := Folder + '-' + IntToStr(Serial);
  if not SafeParents(Folder) or not ForceDirectories(Folder) then exit;
  if not SaveStringToFile(Folder + '\scope.txt', 'product={#ProductId}' + #13#10 + 'purpose=installer-registration-backup' + #13#10 + 'phase=' + Phase + #13#10, false) then exit;
  Key := RegistrationKey;
  if RegKeyExists(HKA, Key) then
  begin
    if not Exec(ExpandConstant('{sys}\reg.exe'), 'export "HKCU\' + Key + '" "' + Folder + '\uninstall.reg" /y',
      '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then exit;
  end
  else if not SaveStringToFile(Folder + '\uninstall.absent', '', false) then exit;
  Key := 'Software\Classes\{#ProductProgId}';
  if RegKeyExists(HKA, Key) then
  begin
    if not Exec(ExpandConstant('{sys}\reg.exe'), 'export "HKCU\' + Key + '" "' + Folder + '\progid.reg" /y',
      '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then exit;
  end
  else if not SaveStringToFile(Folder + '\progid.absent', '', false) then exit;
  Key := 'Software\Classes\{#ProductExtension}';
  if RegKeyExists(HKA, Key) then
  begin
    if not Exec(ExpandConstant('{sys}\reg.exe'), 'export "HKCU\' + Key + '" "' + Folder + '\extension.reg" /y',
      '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then exit;
  end
  else if not SaveStringToFile(Folder + '\extension.absent', '', false) then exit;
  Shortcut := ExpandConstant('{autoprograms}\{#ProductName}.lnk');
  LegacyShortcut := ExpandConstant('{autoprograms}\Cutrans 资源库 (NanoUI).lnk');
  if not SafeParents(Shortcut) or not SafeParents(LegacyShortcut) then exit;
  if FileExists(Shortcut) then
  begin
    if not FileCopy(Shortcut, Folder + '\main-shortcut.lnk', true) then exit;
  end
  else if not SaveStringToFile(Folder + '\main-shortcut.absent', '', false) then exit;
  if FileExists(LegacyShortcut) then
  begin
    if not FileCopy(LegacyShortcut, Folder + '\legacy-shortcut.lnk', true) then exit;
  end
  else if not SaveStringToFile(Folder + '\legacy-shortcut.absent', '', false) then exit;
  Log('CUTRANS_REGISTRATION_BACKUP phase=' + Phase + ' path=' + Folder);
  Result := true;
end;

function NoOwnedProcesses(const Root: String): Boolean;
var
  Script, Parameters: String;
  Code: Integer;
begin
  Script := '$ErrorActionPreference=''Stop''; $root=' + PsQuote(NormalPath(Root) + '\') + '; ' +
    'for($i=0;$i -lt 50;$i++){ $p=@(Get-CimInstance Win32_Process | Where-Object { ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) -or ($_.Name -like ''cutrans_*.exe'' -and [String]::IsNullOrWhiteSpace($_.ExecutablePath)) }); if($p.Count -eq 0){exit 0}; Start-Sleep -Milliseconds 100 }; exit 20';
  Parameters := '-NoProfile -NonInteractive -Command "' + Script + '"';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters,
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

function ShouldAssociateCut: Boolean;
var
  Existing: String;
begin
  Result := not RegQueryStringValue(HKCR, '{#ProductExtension}', '', Existing) or
    (Existing = '') or SameText(Existing, '{#ProductProgId}');
  if not Result then Log('Keeping an association owned by another application');
end;

function SameProgramTree(const Candidate, Existing: String): Boolean;
var
  FindRec: TFindRec;
  CandidateCount, ExistingCount: Integer;
  Left, Right: String;
begin
  Result := false;
  if not SafeParents(Candidate) or not SafeParents(Existing) then exit;
  if not DirExists(Candidate) or not DirExists(Existing) then exit;
  CandidateCount := 0;
  ExistingCount := 0;
  if FindFirst(Candidate + '\*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
        begin
          CandidateCount := CandidateCount + 1;
          Left := Candidate + '\' + FindRec.Name;
          Right := Existing + '\' + FindRec.Name;
          if (FindRec.Attributes and ReparseAttribute) <> 0 then exit;
          if not SafeParents(Right) then exit;
          if (FindRec.Attributes and DirectoryAttribute) <> 0 then
          begin
            if not SameProgramTree(Left, Right) then exit;
          end
          else if (not FileExists(Right)) or (GetSHA256OfFile(Left) <> GetSHA256OfFile(Right)) then exit;
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
  if FindFirst(Existing + '\*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
          ExistingCount := ExistingCount + 1;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
  Result := CandidateCount = ExistingCount;
end;

function StopOwnedHost: Boolean;
var
  Root, Exe: String;
  Code: Integer;
begin
  Result := false;
  Root := ExpandConstant('{app}');
  if not SafeParents(Root) or not SafeParents(Root + '\data') or not OwnsRegistration(Root) then exit;
  Exe := Root + '\app\cutrans_vm.exe';
  if not FileExists(Exe) or not SafeParents(Exe) or not SafeParents(Root + '\data\session') or not SafeParents(Root + '\data\documents') then exit;
  if not Exec(Exe, 'stop --mode=installed --data="' + Root + '\data"',
    Root + '\app', SW_HIDE, ewWaitUntilTerminated, Code) then exit;
  Result := (Code = 0) and NoOwnedProcesses(Root);
end;

function RunDiagnostic(const Root, Phase: String): Integer;
var
  Parameters, VerifyDataDir: String;
begin
  DiagnosticSerial := DiagnosticSerial + 1;
  VerifyDataDir := ExpandConstant('{tmp}') + '\{#ProductId}-diagnostic-' + Phase + '-' + IntToStr(DiagnosticSerial);
  Parameters := '--mode=installed "--verify-data-dir=' + VerifyDataDir + '"';
  if not ExecAsOriginalUser(Root + '\cutrans_diag.exe', Parameters, Root,
    SW_HIDE, ewWaitUntilTerminated, Result) then Result := -1;
  Log('CUTRANS_INSTALL_DIAGNOSTIC phase=' + Phase + ' isolated=1 code=' + IntToStr(Result));
  if Result = 0 then
  begin
    Parameters := '--diag --mode=installed "--data=' + VerifyDataDir + '"';
    if not ExecAsOriginalUser(Root + '\cutrans_bootstrap.exe', Parameters, Root,
      SW_HIDE, ewWaitUntilTerminated, Result) then Result := -1;
    Log('CUTRANS_INSTALL_RUNTIME_DIAGNOSTIC phase=' + Phase + ' isolated=1 code=' + IntToStr(Result));
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Candidate, Root: String;
  Code: Integer;
begin
  Result := '';
  FailureStage := 'preflight';
  try
    Root := ExpandConstant('{app}');
    if not SafeParents(Root) or (FileExists(Root) and not DirExists(Root)) then
    begin
      Log('CUTRANS_INSTALL_REJECTED phase=path-boundary');
      Result := '安装路径必须是无目录联接或符号链接的真实目录。';
      exit;
    end;
    if ExpandConstant('{param:VerifyDataDir|}') <> '' then
    begin
      Log('CUTRANS_INSTALL_REJECTED phase=diagnostic-data-override');
      Result := '安装器诊断数据固定在专属临时目录，不接受 VerifyDataDir。';
      exit;
    end;
    ExtractTemporaryFiles('{app}\*');
    Candidate := ExpandConstant('{tmp}\') + '{app}';
    Code := RunDiagnostic(Candidate + '\app', 'preflight');
    if Code <> 0 then
    begin
      Result := '安装前诊断失败（' + IntToStr(Code) + '），未复制应用文件或写入系统登记。';
      exit;
    end;
    if ExpandConstant('{param:PreflightOnly|0}') = '1' then
    begin
      Log('CUTRANS_INSTALL_PREFLIGHT_ONLY_OK registration=untouched host=untouched');
      Result := '仅验证已完成，未安装。预检模式按约定返回退出码 7。';
      exit;
    end;
    if RegKeyExists(HKA, RegistrationKey) then
    begin
      if not OwnsRegistration(Root) then
      begin
        Result := '已有安装登记属于其他目录；不会覆盖或恢复其系统配置。';
        exit;
      end;
      FailureStage := 'upgrade-guard';
      if not SameProgramTree(Candidate + '\app', Root + '\app') or
         not SameProgramTree(Candidate + '\runtime-envs', Root + '\runtime-envs') or
         not SameProgramTree(Candidate + '\shells', Root + '\shells') then
      begin
        Log('CUTRANS_UPGRADE_REJECTED changed_payload=1 files_unchanged=1');
        Result := '此版本尚未验收不同程序资产的升级回滚事务。已在复制前拒绝，现有安装与数据保持原样。';
        exit;
      end;
      FailureStage := 'stop-owned-host';
      if not StopOwnedHost then
      begin
        Result := '现有安装无法正常停止并保存；未替换应用文件，请修复后重试。';
        exit;
      end;
    end
    else if DirExists(Root + '\app') or DirExists(Root + '\runtime-envs') or DirExists(Root + '\shells') then
    begin
      Result := '目标包含未登记的程序资产，归属不明，已保留并拒绝覆盖。';
      exit;
    end;
    if DirExists(ExpandConstant('{localappdata}\Cutrans')) and
       (ExpandConstant('{param:MigrateLegacy|no}') <> 'no') then
    begin
      Result := '旧数据迁移需单独核实归属与备份；本安装器不会自动移动旧目录。';
      exit;
    end;
    if FileExists(ExpandConstant('{autoprograms}\{#ProductName}.lnk')) and
       not ShortcutOwned(ExpandConstant('{autoprograms}\{#ProductName}.lnk'), Root) then
    begin
      Result := '同名快捷方式归属其他位置，已保留；请先核实再重试安装。';
      exit;
    end;
    FailureStage := 'registration-backup';
    if not BackupSystemState('before-install') then
    begin
      Result := '系统登记或快捷方式备份失败，未替换应用文件或登记。';
      exit;
    end;
    Log('CUTRANS_INSTALL_PREFLIGHT_OK ready=1');
  except
    Result := '安装预检失败（' + FailureStage + '）：' + GetExceptionMessage;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Root: String;
  Code: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    Root := ExpandConstant('{app}');
    FailureStage := 'post-install-diagnostic';
    DiagnosticFailed := RunDiagnostic(Root + '\app', 'installed') <> 0;
    if (not DiagnosticFailed) and FileExists(Root + '\data\session\runtime.lock') then
    begin
      FailureStage := 'runtime-activation';
      if not Exec(Root + '\app\cutrans_vm.exe', 'activate-runtime --mode=installed "--runtime=' +
        Root + '\runtime-envs\default" "--data=' + Root + '\data"', Root + '\app',
        SW_HIDE, ewWaitUntilTerminated, Code) then DiagnosticFailed := true
      else DiagnosticFailed := Code <> 0;
    end;
    if DiagnosticFailed then
    begin
      SaveStringToFile(Root + '\installation-state.txt', 'format={#ProductId}-install/1' + #13#10 +
        'state=failed' + #13#10 + 'stage=' + FailureStage + #13#10, false);
      Log('CUTRANS_INSTALL_FAILED stage=' + FailureStage + ' retry_preserves_data=1 code=9');
      WizardForm.FinishedHeadingLabel.Caption := '安装验证失败';
      WizardForm.FinishedLabel.Caption := '安装程序将返回退出码 9。状态与诊断已保留，重试不会清除用户数据。';
    end
    else
    begin
      SaveStringToFile(Root + '\installation-state.txt', 'format={#ProductId}-install/1' + #13#10 +
        'state=ready' + #13#10, false);
      Log('CUTRANS_INSTALL_READY data_untouched=1');
    end;
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  if DiagnosticFailed then Result := 9 else Result := 0;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Command, Existing, Root: String;
begin
  Root := ExpandConstant('{app}');
  if CurUninstallStep = usUninstall then
  begin
    UninstallOwned := SafeParents(Root) and OwnsRegistration(Root);
    if not UninstallOwned then
      RaiseException('此卸载器不再拥有当前安装登记，或路径包含链接。未删除任何内容。');
    if not StopOwnedHost then
      RaiseException('无法确认本安装已正常停止并保存。保留程序、登记和数据，请修复控制入口后重试。');
    if not BackupSystemState('before-uninstall') then
      RaiseException('系统登记与快捷方式备份失败。保留安装与数据，请修复后重试。');
  end;
  if (CurUninstallStep = usPostUninstall) and UninstallOwned then
  begin
    if ShortcutOwned(ExpandConstant('{autoprograms}\{#ProductName}.lnk'), Root) then
      DeleteFile(ExpandConstant('{autoprograms}\{#ProductName}.lnk'));
    if RegQueryStringValue(HKA, 'Software\Classes\{#ProductProgId}\shell\open\command', '', Command) and
       SameText(Command, ExpectedOpenCommand(Root)) then
    begin
      if RegQueryStringValue(HKA, 'Software\Classes\{#ProductExtension}', '', Existing) and
         SameText(Existing, '{#ProductProgId}') then
        RegDeleteValue(HKA, 'Software\Classes\{#ProductExtension}', '');
      RegDeleteKeyIncludingSubkeys(HKA, 'Software\Classes\{#ProductProgId}');
    end;
  end;
end;
