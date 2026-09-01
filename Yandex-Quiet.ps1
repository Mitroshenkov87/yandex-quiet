#Requires -Version 5.1
<#
.SYNOPSIS
  Keep Yandex Browser installed for hand launch; disable background watchers.

.DESCRIPTION
  Yandex Quiet leaves Yandex Browser on disk so you can open it yourself
  (Russian GOST / national-certificate sites). It stops the updater service,
  update scheduled tasks, SoftLanding (ad/landing) tasks, Run-key autostart,
  and companion clients (Disk, Telemost, Pin, Alice) from sitting in the
  background. First Apply writes a snapshot; -Restore rolls that snapshot back.
  By default Apply also installs a SYSTEM watchdog (logon + hourly) because
  Yandex recreates tasks.

.PARAMETER Status
  Print what is currently enabled, running, or already quiet.

.PARAMETER Apply
  Disable watchers. Writes snapshot.json on the first run only.
  Installs the watchdog unless -Once is also set.

.PARAMETER Restore
  Revert services, tasks, Run keys, policies, and landing shortcuts
  to the snapshot taken on first Apply. Removes the watchdog.

.PARAMETER Once
  With -Apply: do not install/update the watchdog.

.PARAMETER InstallWatchdog
  Copy this script to ProgramData and register the hourly/logon task.

.PARAMETER RemoveWatchdog
  Remove the watchdog task. Snapshot and quieting stay as they are.

.PARAMETER KillBrowser
  Also stop browser.exe that lives under a Yandex install path.
  Default is to leave a browser you launched yourself alone.

.PARAMETER Quiet
  No prompts, minimal console output. Used by the watchdog.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Yandex-Quiet.ps1

.EXAMPLE
  .\Yandex-Quiet.ps1 -Apply

.EXAMPLE
  .\Yandex-Quiet.ps1 -Restore
#>
[CmdletBinding(DefaultParameterSetName = 'Menu')]
param(
    [Parameter(ParameterSetName = 'Status')]
    [switch] $Status,

    [Parameter(ParameterSetName = 'Apply')]
    [switch] $Apply,

    [Parameter(ParameterSetName = 'Restore')]
    [switch] $Restore,

    [Parameter(ParameterSetName = 'Apply')]
    [switch] $Once,

    [Parameter(ParameterSetName = 'WatchdogOn')]
    [switch] $InstallWatchdog,

    [Parameter(ParameterSetName = 'WatchdogOff')]
    [switch] $RemoveWatchdog,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Menu')]
    [switch] $KillBrowser,

    [switch] $Quiet,

    [switch] $WhatIf
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

$script:YqVersion = '1.0.0'
$script:StateDir = Join-Path $env:ProgramData 'YandexQuiet'
$script:SnapshotPath = Join-Path $script:StateDir 'snapshot.json'
$script:LogPath = Join-Path $script:StateDir 'yandex-quiet.log'
$script:InstalledScript = Join-Path $script:StateDir 'Yandex-Quiet.ps1'
$script:ShortcutBackupDir = Join-Path $script:StateDir 'shortcut-backup'
$script:WatchdogTaskPath = '\YandexQuiet\'
$script:WatchdogTaskName = 'YandexQuiet-Watchdog'
$script:PolicyKey = 'HKLM:\SOFTWARE\Policies\YandexBrowser'
$script:Quiet = [bool] $Quiet
$script:KillBrowser = [bool] $KillBrowser
$script:WhatIf = [bool] $WhatIf

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Test-YqAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-YqAdmin {
    if (Test-YqAdmin) { return }
    $argList = New-Object System.Collections.Generic.List[string]
    [void] $argList.Add('-NoProfile')
    [void] $argList.Add('-ExecutionPolicy')
    [void] $argList.Add('Bypass')
    [void] $argList.Add('-File')
    [void] $argList.Add($PSCommandPath)
    foreach ($key in @($PSBoundParameters.Keys)) {
        $val = $PSBoundParameters[$key]
        if ($val -is [switch]) {
            if ($val.IsPresent) { [void] $argList.Add("-$key") }
        }
        elseif ($val -eq $true) {
            [void] $argList.Add("-$key")
        }
        else {
            [void] $argList.Add("-$key")
            [void] $argList.Add([string] $val)
        }
    }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList.ToArray() | Out-Null
    exit 0
}

function Get-YqArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return @($Value) }
    return @($Value)
}

function Initialize-YqStateDir {
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
}

function Write-YqLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')]
        [string] $Level = 'INFO',
        [Parameter(Mandatory = $true)]
        [string] $Message
    )
    Initialize-YqStateDir
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    try {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
    catch { }
    if ($script:Quiet) { return }
    $color = 'Gray'
    switch ($Level) {
        'OK' { $color = 'Green' }
        'WARN' { $color = 'Yellow' }
        'ERROR' { $color = 'Red' }
        default { $color = 'Gray' }
    }
    Write-Host $line.Substring(20) -ForegroundColor $color
}

function Confirm-Yq {
    param([string] $Message)
    if ($script:Quiet) { return $true }
    if ($script:WhatIf) { return $true }
    $r = Read-Host ($Message + ' [y/N]')
    return ($r -eq 'y' -or $r -eq 'Y' -or $r -eq 'д' -or $r -eq 'Д')
}

function Test-YqShouldProcess {
    param(
        [Parameter(Position = 0)]
        $Target,
        [Parameter(Position = 1)]
        $Action
    )
    if ($null -eq $Action -and $Target -is [System.Array]) {
        $Action = $Target[1]
        $Target = $Target[0]
    }
    $Target = [string] $Target
    $Action = [string] $Action
    if ($script:WhatIf) {
        $msg = "WhatIf: {0} -> {1}" -f $Action, $Target
        Write-YqLog INFO $msg
        if ($script:Quiet) { Write-Host $msg -ForegroundColor DarkGray }
        return $false
    }
    return $true
}

function Test-YqTargetText {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $n = $Text.ToLowerInvariant()
    if ($n -match '\\yandexquiet\\') { return $false }
    if ($n -match '\\yandex\\') { return $true }
    if ($n -match 'service_update\.exe') { return $true }
    if ($n -match 'yandexbrowser|yandexdisk|yandextelemost|telemost|yapin') { return $true }
    if ($n -match 'yandex\.ru|ya\.ru') { return $true }
    return $false
}

function Test-YqBrowserExe {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $leaf = [IO.Path]::GetFileName($Text)
    if ($leaf -and $leaf.ToLowerInvariant() -eq 'browser.exe') {
        return (Test-YqTargetText $Text)
    }
    return $false
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

function Get-YqTargetServices {
    $list = @()
    foreach ($svc in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
        $nameHit = $svc.Name -match '(?i)^Yandex'
        $pathHit = Test-YqTargetText ([string] $svc.PathName)
        if ($nameHit -or $pathHit) {
            $list += [pscustomobject]@{
                Name        = $svc.Name
                DisplayName = $svc.DisplayName
                State       = $svc.State
                StartMode   = $svc.StartMode
                PathName    = $svc.PathName
            }
        }
    }
    return $list
}

function Get-YqTargetTasks {
    $list = @()
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        if ($t.TaskPath -eq $script:WatchdogTaskPath -and $t.TaskName -eq $script:WatchdogTaskName) {
            continue
        }
        $hit = $false
        if ($t.TaskPath -match '\\SoftLanding\\') { $hit = $true }
        elseif ($t.TaskName -match '(?i)Yandex|Яндекс|YaBrowser|YaDisk|Telemost|Alice|Алиса') { $hit = $true }
        else {
            foreach ($a in @(Get-YqArray $t.Actions)) {
                $blob = ('{0} {1}' -f $a.Execute, $a.Arguments)
                if (Test-YqTargetText $blob) { $hit = $true; break }
            }
        }
        if ($hit) {
            $exec = @()
            foreach ($a in @(Get-YqArray $t.Actions)) {
                $exec += [string] $a.Execute
            }
            $list += [pscustomobject]@{
                TaskPath = $t.TaskPath
                TaskName = $t.TaskName
                State    = [string] $t.State
                Exec     = $exec
            }
        }
    }
    return $list
}

function Get-YqRunValues {
    $paths = @(
        @{ Hive = 'HKCU'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' },
        @{ Hive = 'HKCU'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' },
        @{ Hive = 'HKLM'; Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' },
        @{ Hive = 'HKLM'; Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce' },
        @{ Hive = 'HKLM'; Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' },
        @{ Hive = 'HKLM'; Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce' }
    )
    $list = @()
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p.Path)) { continue }
        $item = Get-Item -LiteralPath $p.Path -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }
        foreach ($name in @($item.GetValueNames())) {
            $val = [string] $item.GetValue($name)
            if (Test-YqTargetText $val -or $name -match '(?i)Yandex|Яндекс|YaDisk|Telemost|Alice|Алиса') {
                $list += [pscustomobject]@{
                    Hive  = $p.Hive
                    Path  = $p.Path
                    Name  = $name
                    Value = $val
                }
            }
        }
    }
    return $list
}

function Get-YqShortcutInfo {
    param([string] $FullName)
    $ext = [IO.Path]::GetExtension($FullName)
    $target = ''
    $args = ''
    $url = ''
    if ($ext -eq '.lnk') {
        try {
            $w = New-Object -ComObject WScript.Shell
            $sc = $w.CreateShortcut($FullName)
            $target = [string] $sc.TargetPath
            $args = [string] $sc.Arguments
        }
        catch { }
    }
    elseif ($ext -eq '.url') {
        try {
            foreach ($line in @(Get-Content -LiteralPath $FullName -ErrorAction SilentlyContinue)) {
                if ($line -match '^(?i)URL=(.+)$') { $url = $Matches[1]; break }
            }
        }
        catch { }
    }
    [pscustomobject]@{
        FullName = $FullName
        Name     = [IO.Path]::GetFileName($FullName)
        Target   = $target
        Args     = $args
        Url      = $url
    }
}

function Test-YqLandingShortcut {
    param($Info)
    $blob = '{0} {1} {2}' -f $Info.Target, $Info.Args, $Info.Url
    if (-not (Test-YqTargetText $blob) -and $Info.Name -notmatch '(?i)Yandex|Яндекс|Alice|Алиса|Telemost|Телемост') {
        return $false
    }
    if ($Info.Url -match '(?i)^https?://') { return $true }
    if ($Info.Args -match '(?i)https?://') { return $true }
    if ($Info.Target -match '(?i)service_update\.exe|browser_installer') { return $true }
    return $false
}

function Test-YqStartupShortcut {
    param($Info)
    $blob = '{0} {1} {2} {3}' -f $Info.Name, $Info.Target, $Info.Args, $Info.Url
    return (Test-YqTargetText $blob) -or ($Info.Name -match '(?i)Yandex|Яндекс|Alice|Алиса|YaDisk|Telemost')
}

function Get-YqLinkFiles {
    param(
        [string] $Root,
        [switch] $Recurse
    )
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $params = @{
        LiteralPath   = $Root
        Force         = $true
        ErrorAction   = 'SilentlyContinue'
        File          = $true
    }
    if ($Recurse) { $params.Recurse = $true }
    Get-ChildItem @params | Where-Object { $_.Extension -match '^\.(lnk|url)$' }
}

function Get-YqShortcutTargets {
    $startup = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
    )
    $places = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:PUBLIC 'Desktop')
    )
    $list = @()
    $seen = @{}
    foreach ($root in $startup) {
        foreach ($file in @(Get-YqLinkFiles -Root $root)) {
            $info = Get-YqShortcutInfo $file.FullName
            if (Test-YqStartupShortcut $info) {
                $info | Add-Member -NotePropertyName Kind -NotePropertyValue 'Startup' -Force
                $list += $info
                $seen[$file.FullName] = $true
            }
        }
    }
    foreach ($root in $places) {
        foreach ($file in @(Get-YqLinkFiles -Root $root -Recurse)) {
            if ($seen.ContainsKey($file.FullName)) { continue }
            $info = Get-YqShortcutInfo $file.FullName
            if (Test-YqLandingShortcut $info) {
                $info | Add-Member -NotePropertyName Kind -NotePropertyValue 'Landing' -Force
                $list += $info
            }
        }
    }
    return $list
}

function Get-YqTargetProcesses {
    $list = @()
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $exe = [string] $p.ExecutablePath
        $cmd = [string] $p.CommandLine
        if (-not (Test-YqTargetText $exe) -and -not (Test-YqTargetText $cmd)) { continue }
        $isBrowser = (Test-YqBrowserExe $exe) -or ($p.Name -eq 'browser.exe' -and (Test-YqTargetText $exe))
        $list += [pscustomobject]@{
            Pid       = $p.ProcessId
            Name      = $p.Name
            Path      = $exe
            IsBrowser = [bool] $isBrowser
        }
    }
    return $list
}

function Get-YqPolicySnapshot {
    $obj = [pscustomobject]@{
        KeyExisted                   = $false
        AutoUpdateCheckPeriodMinutes = [pscustomobject]@{ Existed = $false; Value = $null }
        ComponentUpdatesEnabled      = [pscustomobject]@{ Existed = $false; Value = $null }
    }
    if (-not (Test-Path -LiteralPath $script:PolicyKey)) { return $obj }
    $obj.KeyExisted = $true
    $item = Get-Item -LiteralPath $script:PolicyKey
    $names = @($item.GetValueNames())
    if ($names -contains 'AutoUpdateCheckPeriodMinutes') {
        $obj.AutoUpdateCheckPeriodMinutes.Existed = $true
        $obj.AutoUpdateCheckPeriodMinutes.Value = $item.GetValue('AutoUpdateCheckPeriodMinutes')
    }
    if ($names -contains 'ComponentUpdatesEnabled') {
        $obj.ComponentUpdatesEnabled.Existed = $true
        $obj.ComponentUpdatesEnabled.Value = $item.GetValue('ComponentUpdatesEnabled')
    }
    return $obj
}

function Test-YqWatchdogPresent {
    $t = Get-ScheduledTask -TaskPath $script:WatchdogTaskPath -TaskName $script:WatchdogTaskName -ErrorAction SilentlyContinue
    return ($null -ne $t)
}

# ---------------------------------------------------------------------------
# Snapshot
# ---------------------------------------------------------------------------

function New-YqSnapshotObject {
    param(
        $Services,
        $Tasks,
        $RunKeys,
        $Shortcuts,
        $Policies
    )
    [pscustomobject]@{
        Version            = 1
        CreatedUtc         = [DateTime]::UtcNow.ToString('o')
        ToolVersion        = $script:YqVersion
        Services           = @($Services | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; StartMode = $_.StartMode; State = $_.State }
            })
        Tasks              = @($Tasks | ForEach-Object {
                [pscustomobject]@{ TaskPath = $_.TaskPath; TaskName = $_.TaskName; State = $_.State }
            })
        RunKeys            = @($RunKeys)
        Shortcuts          = @($Shortcuts | ForEach-Object {
                $backup = $null
                if ($_.PSObject.Properties.Name -contains 'Backup') { $backup = $_.Backup }
                [pscustomobject]@{ FullName = $_.FullName; Kind = $_.Kind; Backup = $backup }
            })
        Policies           = $Policies
        WatchdogWasPresent = [bool] (Test-YqWatchdogPresent)
    }
}

function Save-YqSnapshot {
    param($Snapshot)
    if ($script:WhatIf) { return }
    Initialize-YqStateDir
    $json = $Snapshot | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($script:SnapshotPath, $json, (New-Object System.Text.UTF8Encoding $true))
    Write-YqLog INFO ("Snapshot saved: " + $script:SnapshotPath)
}

function Read-YqSnapshot {
    if (-not (Test-Path -LiteralPath $script:SnapshotPath)) { return $null }
    $raw = [IO.File]::ReadAllText($script:SnapshotPath)
    return ($raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Mutators
# ---------------------------------------------------------------------------

function Stop-YqServices {
    param($Services)
    foreach ($s in @(Get-YqArray $Services)) {
        if (Test-YqShouldProcess -Target $s.Name -Action 'Stop and disable service') {
            try {
                $svc = Get-Service -Name $s.Name -ErrorAction Stop
                if ($svc.Status -ne 'Stopped') {
                    Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
                }
                Set-Service -Name $s.Name -StartupType Disabled -ErrorAction Stop
                Write-YqLog OK ("Service disabled: " + $s.Name)
            }
            catch {
                Write-YqLog ERROR ("Service " + $s.Name + ": " + $_.Exception.Message)
            }
        }
    }
}

function Disable-YqTasks {
    param($Tasks)
    foreach ($t in @(Get-YqArray $Tasks)) {
        $label = $t.TaskPath + $t.TaskName
        if (Test-YqShouldProcess -Target $label -Action 'Disable scheduled task') {
            try {
                Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
                Write-YqLog OK ("Task disabled: " + $label)
            }
            catch {
                Write-YqLog ERROR ("Task " + $label + ": " + $_.Exception.Message)
            }
        }
    }
}

function Remove-YqRunValues {
    param($RunKeys)
    foreach ($k in @(Get-YqArray $RunKeys)) {
        $label = $k.Path + ' / ' + $k.Name
        if (Test-YqShouldProcess -Target $label -Action 'Remove Run value') {
            try {
                Remove-ItemProperty -LiteralPath $k.Path -Name $k.Name -ErrorAction Stop
                Write-YqLog OK ("Run key removed: " + $label)
            }
            catch {
                Write-YqLog ERROR ("Run key " + $label + ": " + $_.Exception.Message)
            }
        }
    }
}

function Backup-YqShortcuts {
    param($Shortcuts)
    if ($script:WhatIf) { return }
    if (@(Get-YqArray $Shortcuts).Count -eq 0) { return }
    if (-not (Test-Path -LiteralPath $script:ShortcutBackupDir)) {
        New-Item -ItemType Directory -Path $script:ShortcutBackupDir -Force | Out-Null
    }
    $i = 0
    foreach ($s in @(Get-YqArray $Shortcuts)) {
        if (-not (Test-Path -LiteralPath $s.FullName)) { continue }
        $i++
        $dest = Join-Path $script:ShortcutBackupDir ('{0:D3}_{1}' -f $i, $s.Name)
        try {
            Copy-Item -LiteralPath $s.FullName -Destination $dest -Force
            $s | Add-Member -NotePropertyName Backup -NotePropertyValue $dest -Force
        }
        catch {
            Write-YqLog WARN ("Shortcut backup failed: " + $s.FullName)
        }
    }
}

function Remove-YqShortcuts {
    param($Shortcuts)
    foreach ($s in @(Get-YqArray $Shortcuts)) {
        if (Test-YqShouldProcess -Target $s.FullName -Action 'Remove landing/startup shortcut') {
            try {
                if (Test-Path -LiteralPath $s.FullName) {
                    Remove-Item -LiteralPath $s.FullName -Force -ErrorAction Stop
                    Write-YqLog OK ("Shortcut removed: " + $s.FullName)
                }
            }
            catch {
                Write-YqLog ERROR ("Shortcut " + $s.FullName + ": " + $_.Exception.Message)
            }
        }
    }
}

function Set-YqQuietPolicies {
    if (Test-YqShouldProcess -Target $script:PolicyKey -Action 'Disable Yandex Browser auto-update policy') {
        try {
            if (-not (Test-Path -LiteralPath $script:PolicyKey)) {
                New-Item -Path $script:PolicyKey -Force | Out-Null
            }
            New-ItemProperty -Path $script:PolicyKey -Name 'AutoUpdateCheckPeriodMinutes' -PropertyType DWord -Value 0 -Force | Out-Null
            New-ItemProperty -Path $script:PolicyKey -Name 'ComponentUpdatesEnabled' -PropertyType DWord -Value 0 -Force | Out-Null
            Write-YqLog OK 'Policy: auto-update disabled'
        }
        catch {
            Write-YqLog ERROR ("Policy: " + $_.Exception.Message)
        }
    }
}

function Stop-YqProcesses {
    param($Processes)
    foreach ($p in @(Get-YqArray $Processes)) {
        if ($p.IsBrowser -and -not $script:KillBrowser) { continue }
        if (Test-YqShouldProcess -Target ('{0} pid={1}' -f $p.Name, $p.Pid) -Action 'Stop process') {
            try {
                Stop-Process -Id $p.Pid -Force -ErrorAction Stop
                Write-YqLog OK ("Stopped {0} (pid {1})" -f $p.Name, $p.Pid)
            }
            catch {
                Write-YqLog WARN ("Process {0} pid {1}: {2}" -f $p.Name, $p.Pid, $_.Exception.Message)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Watchdog
# ---------------------------------------------------------------------------

function Install-YqWatchdog {
    if ($script:WhatIf) {
        Write-YqLog INFO 'WhatIf: would install watchdog'
        return
    }
    Initialize-YqStateDir
    Copy-Item -LiteralPath $PSCommandPath -Destination $script:InstalledScript -Force
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Apply -Once -Quiet' -f $script:InstalledScript
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $t1 = New-ScheduledTaskTrigger -AtLogOn
    $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Trigger @($t1, $t2) -Principal $principal -Settings $settings
    try {
        $existing = Get-ScheduledTask -TaskPath $script:WatchdogTaskPath -TaskName $script:WatchdogTaskName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Unregister-ScheduledTask -TaskPath $script:WatchdogTaskPath -TaskName $script:WatchdogTaskName -Confirm:$false
        }
        Register-ScheduledTask -TaskPath $script:WatchdogTaskPath -TaskName $script:WatchdogTaskName -InputObject $task -Force | Out-Null
        Write-YqLog OK 'Watchdog installed (SYSTEM, at logon + hourly)'
    }
    catch {
        Write-YqLog ERROR ("Watchdog install: " + $_.Exception.Message)
    }
}

function Uninstall-YqWatchdog {
    if ($script:WhatIf) {
        Write-YqLog INFO 'WhatIf: would remove watchdog'
        return
    }
    $existing = Get-ScheduledTask -TaskPath $script:WatchdogTaskPath -TaskName $script:WatchdogTaskName -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        Write-YqLog INFO 'Watchdog was not installed'
        return
    }
    try {
        Unregister-ScheduledTask -TaskPath $script:WatchdogTaskPath -TaskName $script:WatchdogTaskName -Confirm:$false
        Write-YqLog OK 'Watchdog removed'
    }
    catch {
        Write-YqLog ERROR ("Watchdog remove: " + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Apply / Restore / Status
# ---------------------------------------------------------------------------

function Invoke-YqApply {
    param([bool] $WithWatchdog)

    $services = @(Get-YqTargetServices)
    $tasks = @(Get-YqTargetTasks)
    $runKeys = @(Get-YqRunValues)
    $shortcuts = @(Get-YqShortcutTargets)
    $policies = Get-YqPolicySnapshot
    $processes = @(Get-YqTargetProcesses)

    Backup-YqShortcuts -Shortcuts $shortcuts

    if (-not (Test-Path -LiteralPath $script:SnapshotPath)) {
        $snap = New-YqSnapshotObject -Services $services -Tasks $tasks -RunKeys $runKeys -Shortcuts $shortcuts -Policies $policies
        Save-YqSnapshot -Snapshot $snap
    }
    else {
        Write-YqLog INFO 'Existing snapshot kept (first Apply). Delete snapshot.json to recapture.'
    }
    Stop-YqServices -Services $services
    Disable-YqTasks -Tasks $tasks
    Remove-YqRunValues -RunKeys $runKeys
    Remove-YqShortcuts -Shortcuts $shortcuts
    Set-YqQuietPolicies
    Stop-YqProcesses -Processes $processes

    if ($WithWatchdog) {
        Install-YqWatchdog
    }

    Write-YqLog OK 'Apply finished. Yandex Browser itself was not uninstalled.'
}

function Invoke-YqRestore {
    $snap = Read-YqSnapshot
    if ($null -eq $snap) {
        Write-YqLog ERROR ('No snapshot at ' + $script:SnapshotPath)
        Write-YqLog ERROR 'Restore undoes the first Apply of this tool. Nothing to undo.'
        return
    }

    Uninstall-YqWatchdog

    foreach ($s in @(Get-YqArray $snap.Services)) {
        $label = [string] $s.Name
        if (Test-YqShouldProcess -Target $label -Action 'Restore service start mode') {
            try {
                $mode = [string] $s.StartMode
                $startup = 'Manual'
                switch ($mode) {
                    'Auto' { $startup = 'Automatic' }
                    'Automatic' { $startup = 'Automatic' }
                    'Disabled' { $startup = 'Disabled' }
                    'Manual' { $startup = 'Manual' }
                    default { $startup = 'Manual' }
                }
                Set-Service -Name $s.Name -StartupType $startup -ErrorAction Stop
                if (([string] $s.State) -eq 'Running') {
                    Start-Service -Name $s.Name -ErrorAction SilentlyContinue
                }
                Write-YqLog OK ("Service restored: {0} -> {1}" -f $s.Name, $startup)
            }
            catch {
                Write-YqLog WARN ("Service restore {0}: {1}" -f $s.Name, $_.Exception.Message)
            }
        }
    }

    foreach ($t in @(Get-YqArray $snap.Tasks)) {
        $label = $t.TaskPath + $t.TaskName
        if (Test-YqShouldProcess -Target $label -Action 'Restore scheduled task state') {
            try {
                $state = [string] $t.State
                if ($state -eq 'Disabled') {
                    Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
                }
                else {
                    Enable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
                }
                Write-YqLog OK ("Task restored: {0} -> {1}" -f $label, $state)
            }
            catch {
                Write-YqLog WARN ("Task restore {0}: {1}" -f $label, $_.Exception.Message)
            }
        }
    }

    foreach ($k in @(Get-YqArray $snap.RunKeys)) {
        $label = $k.Path + ' / ' + $k.Name
        if (Test-YqShouldProcess -Target $label -Action 'Restore Run value') {
            try {
                if (-not (Test-Path -LiteralPath $k.Path)) {
                    New-Item -Path $k.Path -Force | Out-Null
                }
                New-ItemProperty -LiteralPath $k.Path -Name $k.Name -Value $k.Value -PropertyType String -Force | Out-Null
                Write-YqLog OK ("Run key restored: " + $label)
            }
            catch {
                Write-YqLog WARN ("Run key restore {0}: {1}" -f $label, $_.Exception.Message)
            }
        }
    }

    $pol = $snap.Policies
    if ($null -ne $pol) {
        if (Test-YqShouldProcess -Target $script:PolicyKey -Action 'Restore YandexBrowser policies') {
            try {
                $keyExisted = $false
                if ($pol.PSObject.Properties.Name -contains 'KeyExisted') { $keyExisted = [bool] $pol.KeyExisted }
                if (-not $keyExisted) {
                    if (Test-Path -LiteralPath $script:PolicyKey) {
                        Remove-Item -LiteralPath $script:PolicyKey -Recurse -Force
                        Write-YqLog OK 'Policy key removed (it did not exist before Apply)'
                    }
                }
                else {
                    if (-not (Test-Path -LiteralPath $script:PolicyKey)) {
                        New-Item -Path $script:PolicyKey -Force | Out-Null
                    }
                    foreach ($propName in @('AutoUpdateCheckPeriodMinutes', 'ComponentUpdatesEnabled')) {
                        $prop = $pol.$propName
                        if ($null -eq $prop) { continue }
                        $existed = $false
                        if ($prop.PSObject.Properties.Name -contains 'Existed') { $existed = [bool] $prop.Existed }
                        if ($existed) {
                            New-ItemProperty -Path $script:PolicyKey -Name $propName -PropertyType DWord -Value ([int] $prop.Value) -Force | Out-Null
                        }
                        else {
                            Remove-ItemProperty -Path $script:PolicyKey -Name $propName -ErrorAction SilentlyContinue
                        }
                    }
                    Write-YqLog OK 'Policies restored'
                }
            }
            catch {
                Write-YqLog WARN ("Policy restore: " + $_.Exception.Message)
            }
        }
    }

    if (Test-Path -LiteralPath $script:ShortcutBackupDir) {
        foreach ($s in @(Get-YqArray $snap.Shortcuts)) {
            $original = [string] $s.FullName
            $src = $null
            if ($s.PSObject.Properties.Name -contains 'Backup' -and $s.Backup -and (Test-Path -LiteralPath ([string] $s.Backup))) {
                $src = [string] $s.Backup
            }
            else {
                $leaf = [IO.Path]::GetFileName($original)
                $candidates = @(Get-ChildItem -LiteralPath $script:ShortcutBackupDir -Filter ('*_' + $leaf) -ErrorAction SilentlyContinue)
                if ($candidates.Count -eq 0) {
                    $candidates = @(Get-ChildItem -LiteralPath $script:ShortcutBackupDir -Filter $leaf -ErrorAction SilentlyContinue)
                }
                if ($candidates.Count -gt 0) { $src = $candidates[0].FullName }
            }
            if ([string]::IsNullOrWhiteSpace($src)) { continue }
            if (Test-YqShouldProcess -Target $original -Action 'Restore shortcut') {
                try {
                    $dir = [IO.Path]::GetDirectoryName($original)
                    if (-not (Test-Path -LiteralPath $dir)) {
                        New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    }
                    Copy-Item -LiteralPath $src -Destination $original -Force
                    Write-YqLog OK ("Shortcut restored: " + $original)
                }
                catch {
                    Write-YqLog WARN ("Shortcut restore {0}: {1}" -f $original, $_.Exception.Message)
                }
            }
        }
    }

    Write-YqLog OK 'Restore finished. Snapshot file was kept for another Apply/Restore cycle.'
}

function Show-YqStatus {
    Write-Host ''
    Write-Host ("Yandex Quiet {0}  status" -f $script:YqVersion) -ForegroundColor Cyan
    Write-Host ('Snapshot : ' + $(if (Test-Path $script:SnapshotPath) { $script:SnapshotPath } else { '(none — Restore unavailable until first Apply)' }))
    Write-Host ('Watchdog : ' + $(if (Test-YqWatchdogPresent) { 'installed' } else { 'not installed' }))
    Write-Host ('Log      : ' + $script:LogPath)
    Write-Host ''

    $services = @(Get-YqTargetServices)
    Write-Host 'Services' -ForegroundColor Cyan
    if ($services.Count -eq 0) { Write-Host '  (none found)' }
    else { $services | Format-Table Name, State, StartMode, DisplayName -AutoSize | Out-Host }

    $tasks = @(Get-YqTargetTasks)
    Write-Host 'Scheduled tasks' -ForegroundColor Cyan
    if ($tasks.Count -eq 0) { Write-Host '  (none found)' }
    else { $tasks | Select-Object State, TaskPath, TaskName | Format-Table -AutoSize | Out-Host }

    $run = @(Get-YqRunValues)
    Write-Host 'Run keys' -ForegroundColor Cyan
    if ($run.Count -eq 0) { Write-Host '  (none found)' }
    else { $run | Format-Table Hive, Name, Value -AutoSize | Out-Host }

    $sc = @(Get-YqShortcutTargets)
    Write-Host 'Landing / startup shortcuts' -ForegroundColor Cyan
    if ($sc.Count -eq 0) { Write-Host '  (none found)' }
    else { $sc | Format-Table Kind, Name, FullName -AutoSize | Out-Host }

    $pr = @(Get-YqTargetProcesses)
    Write-Host 'Processes' -ForegroundColor Cyan
    if ($pr.Count -eq 0) { Write-Host '  (none found)' }
    else { $pr | Format-Table Pid, Name, IsBrowser, Path -AutoSize | Out-Host }

    $pol = Get-YqPolicySnapshot
    Write-Host 'Update policy' -ForegroundColor Cyan
    if (-not $pol.KeyExisted) {
        Write-Host '  (no HKLM:\SOFTWARE\Policies\YandexBrowser)'
    }
    else {
        Write-Host ("  AutoUpdateCheckPeriodMinutes = {0}" -f $pol.AutoUpdateCheckPeriodMinutes.Value)
        Write-Host ("  ComponentUpdatesEnabled      = {0}" -f $pol.ComponentUpdatesEnabled.Value)
    }
    Write-Host ''
}

function Show-YqMenu {
    Write-Host ''
    Write-Host ("Yandex Quiet {0}" -f $script:YqVersion) -ForegroundColor Cyan
    Write-Host 'Браузер остаётся на диске. Гасятся апдейтер, SoftLanding, автозапуск и клиенты.'
    Write-Host 'Первый Apply пишет снимок. Restore возвращает именно его, не «завод Яндекса».'
    Write-Host ''
    Write-Host '  1) Состояние'
    Write-Host '  2) Применить и поставить сторожок'
    Write-Host '  3) Применить один раз (без сторожка)'
    Write-Host '  4) Откатить к снимку'
    Write-Host '  5) Снять сторожок'
    Write-Host '  6) Выход'
    Write-Host ''
    return (Read-Host 'Выбор')
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

$needAdmin = $true
if ($PSCmdlet.ParameterSetName -eq 'Status') { $needAdmin = $false }
if ($needAdmin) { Request-YqAdmin }

switch ($PSCmdlet.ParameterSetName) {
    'Status' {
        Show-YqStatus
    }
    'Apply' {
        if (-not (Confirm-Yq 'Отключить фон Яндекса (браузер не удаляется)?')) { exit 0 }
        Invoke-YqApply -WithWatchdog:(-not $Once)
    }
    'Restore' {
        if (-not (Confirm-Yq 'Откатить к снимку первого Apply и снять сторожок?')) { exit 0 }
        Invoke-YqRestore
    }
    'WatchdogOn' {
        Install-YqWatchdog
    }
    'WatchdogOff' {
        Uninstall-YqWatchdog
    }
    default {
        :menuLoop while ($true) {
            $choice = Show-YqMenu
            switch ($choice) {
                '1' { Show-YqStatus }
                '2' {
                    if (Confirm-Yq 'Отключить фон Яндекса и поставить сторожок?') {
                        Invoke-YqApply -WithWatchdog:$true
                    }
                }
                '3' {
                    if (Confirm-Yq 'Отключить фон Яндекса один раз, без сторожка?') {
                        Invoke-YqApply -WithWatchdog:$false
                    }
                }
                '4' {
                    if (Confirm-Yq 'Откатить к снимку первого Apply и снять сторожок?') {
                        Invoke-YqRestore
                    }
                }
                '5' { Uninstall-YqWatchdog }
                '6' { break menuLoop }
                'q' { break menuLoop }
                'Q' { break menuLoop }
                default { Write-Host 'Нет такого пункта.' -ForegroundColor Yellow }
            }
        }
    }
}
