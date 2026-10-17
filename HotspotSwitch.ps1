# =====================================================================
#  Windows 移动热点 通用开关 (HotspotSwitch)
#  适用场景：
#    1) 设置页「移动热点」开关是灰的 / 打不开（PPPoE 宽带拨号最常见）
#    2) 开关能开但手机连上没网
#    3) 无线网卡被禁用导致热点不可用
#  原理：直接调用系统 NetworkOperatorTetheringManager 接口启停热点，
#        绕开设置界面在 PPPoE 环境下的判断缺陷。
#  兼容：Windows 10 / 11，Windows PowerShell 5.1（系统自带）
# =====================================================================
param(
    [switch]$On,
    [switch]$Off,
    [switch]$Toggle,
    [switch]$Status,
    [switch]$Diag,
    [switch]$Repair,
    [switch]$NoGui,
    [switch]$Quiet,
    [switch]$SelfTest,
    [string]$SetSsid,
    [string]$SetPassword
)

$ErrorActionPreference = 'Stop'

$script:ScriptPath = $PSCommandPath
$script:ScriptDir  = $PSScriptRoot
if (-not $script:ScriptDir) { $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:LogPath    = Join-Path $script:ScriptDir 'HotspotSwitch.log'
$script:ResultFile = $env:HS_RESULT
if (-not $script:ResultFile) { $script:ResultFile = Join-Path $env:TEMP 'HotspotSwitch.result.txt' }

if (-not $SetSsid -and $env:HS_SSID) { $SetSsid = $env:HS_SSID }
if (-not $SetPassword -and $env:HS_PASS) { $SetPassword = $env:HS_PASS }

$script:CurrentState = 'Unknown'
$script:AsTaskGeneric = $null

# ---------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------
function Write-Log([string]$Message) {
    try {
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Write-Result([bool]$Ok, [string]$Message) {
    if (-not $script:ResultFile) { return }
    try {
        $head = 'OK'
        if (-not $Ok) { $head = 'ERR' }
        $text = $head + "`r`n" + $Message
        [System.IO.File]::WriteAllText($script:ResultFile, $text, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Show-Message([string]$Text, [string]$Title, [string]$Kind) {
    if ($Quiet -or $NoGui) { Write-Host $Text; return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $icon = [System.Windows.Forms.MessageBoxIcon]::Information
        if ($Kind -eq 'Error') { $icon = [System.Windows.Forms.MessageBoxIcon]::Error }
        [System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon) | Out-Null
        return
    } catch { }
    try {
        $sh = New-Object -ComObject WScript.Shell
        $flag = 64
        if ($Kind -eq 'Error') { $flag = 16 }
        $sh.Popup($Text, 30, $Title, $flag) | Out-Null
    } catch { Write-Host $Text }
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# ---------------------------------------------------------------------
# WinRT（移动热点 API）
# ---------------------------------------------------------------------
function Initialize-WinRT {
    if ($script:AsTaskGeneric) { return }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
    if (-not $script:AsTaskGeneric) { throw '无法初始化 WinRT 异步支持（请使用 Windows PowerShell 5.1 运行）' }
    [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringAccessPointConfiguration, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
}

function Await($Operation, $ResultType) {
    $method = $script:AsTaskGeneric.MakeGenericMethod($ResultType)
    $task = $method.Invoke($null, @($Operation))
    $task.Wait(-1) | Out-Null
    $task.Result
}

# 找到可用的网络连接并返回热点上下文
function Get-TetheringContext {
    Initialize-WinRT

    $candidates = New-Object System.Collections.Generic.List[object]
    $default = $null
    try { $default = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() } catch { }
    if ($default) { [void]$candidates.Add($default) }

    try {
        foreach ($p in [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles()) {
            if ($default -and $p.ProfileName -eq $default.ProfileName) { continue }
            $level = 'Unknown'
            try { $level = "$($p.GetNetworkConnectivityLevel())" } catch { }
            if ($level -eq 'None') { continue }
            [void]$candidates.Add($p)
        }
    } catch { }

    if ($candidates.Count -eq 0) { return $null }

    $chosen = $null
    $chosenCap = 'Unknown'
    $manager = $null
    $firstProfile = $null
    $firstCap = $null

    foreach ($p in $candidates) {
        $cap = 'Unknown'
        try {
            $cap = "$([Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::GetTetheringCapabilityFromConnectionProfile($p))"
        } catch { continue }
        if (-not $firstProfile) { $firstProfile = $p; $firstCap = $cap }
        if ($cap -eq 'Enabled') {
            try {
                $manager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($p)
                $chosen = $p
                $chosenCap = $cap
                break
            } catch { continue }
        }
    }

    if (-not $chosen) {
        if (-not $firstProfile) { return $null }
        $chosen = $firstProfile
        $chosenCap = $firstCap
        try {
            $manager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($chosen)
        } catch { return $null }
    }

    $state = 'Unknown'
    $ssid = ''
    $pass = ''
    $clients = 0
    try { $state = "$($manager.TetheringOperationalState)" } catch { }
    try {
        $ap = $manager.GetCurrentAccessPointConfiguration()
        if ($ap) {
            $ssid = "$($ap.Ssid)"
            $pass = "$($ap.Passphrase)"
        }
    } catch { }
    try { $clients = [int]$manager.ClientCount } catch { }

    return [pscustomobject]@{
        Profile     = $chosen
        ProfileName = "$($chosen.ProfileName)"
        Capability  = $chosenCap
        Manager     = $manager
        State       = $state
        Ssid        = $ssid
        Passphrase  = $pass
        ClientCount = $clients
    }
}

# 开启热点
function Start-Hotspot {
    $ctx = Get-TetheringContext
    if (-not $ctx) {
        return @{ Ok = $false; Message = '未检测到可用的网络连接。请先联网（宽带拨号 / 插网线 / 连 Wi-Fi）后再试。' }
    }
    if ($ctx.Capability -ne 'Enabled') {
        return @{ Ok = $false; Message = ("当前网络不支持创建热点（{0}）。`n`n常见原因：`n  · 无线网卡被禁用（可先点「一键修复」）`n  · 无线驱动不支持承载网络`n  · 电脑没有无线网卡`n  · 网络尚未真正连通" -f $ctx.Capability) }
    }
    if ($ctx.State -eq 'On') {
        return @{ Ok = $true; Message = ("热点已在运行中。`n`n名称：{0}`n密码：{1}`n已连设备：{2} 台" -f $ctx.Ssid, $ctx.Passphrase, $ctx.ClientCount) }
    }

    $res = Await ($ctx.Manager.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    Write-Log ('StartTethering = ' + $res.Status + ' ' + $res.AdditionalErrorMessage)

    if ("$($res.Status)" -ne 'Success') {
        return @{ Ok = $false; Message = ('开启失败：' + $res.Status + ' ' + $res.AdditionalErrorMessage) }
    }

    Start-Sleep -Milliseconds 600
    $ctx2 = Get-TetheringContext
    if (-not $ctx2) { return @{ Ok = $true; Message = '热点已开启。' } }

    return @{ Ok = $true; Message = ("热点已成功开启。`n`n名称：{0}`n密码：{1}`n已连设备：{2} 台" -f $ctx2.Ssid, $ctx2.Passphrase, $ctx2.ClientCount) }
}

# 关闭热点
function Stop-Hotspot {
    $ctx = Get-TetheringContext
    if (-not $ctx) { return @{ Ok = $false; Message = '未检测到可用的网络连接。' } }
    if ($ctx.State -eq 'Off') { return @{ Ok = $true; Message = '热点本来就是关闭状态。' } }

    $res = Await ($ctx.Manager.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    Write-Log ('StopTethering = ' + $res.Status)
    if ("$($res.Status)" -ne 'Success') {
        return @{ Ok = $false; Message = ('关闭失败：' + $res.Status + ' ' + $res.AdditionalErrorMessage) }
    }
    return @{ Ok = $true; Message = '热点已关闭。' }
}

# 切换
function Invoke-Toggle {
    $ctx = Get-TetheringContext
    if (-not $ctx) { return @{ Ok = $false; Message = '未检测到可用的网络连接。' } }
    if ($ctx.State -eq 'On') { return Stop-Hotspot }
    return Start-Hotspot
}

# 修改名称 / 密码
function Set-HotspotConfig([string]$NewSsid, [string]$NewPass) {
    if ([string]::IsNullOrWhiteSpace($NewSsid)) { return @{ Ok = $false; Message = '网络名称不能为空。' } }
    if ($NewSsid.Length -gt 32) { return @{ Ok = $false; Message = '网络名称不能超过 32 个字符。' } }
    if ([string]::IsNullOrEmpty($NewPass)) { return @{ Ok = $false; Message = '密码不能为空。' } }
    if ($NewPass.Length -lt 8) { return @{ Ok = $false; Message = '密码至少需要 8 位字符。' } }
    if ($NewPass.Length -gt 63) { return @{ Ok = $false; Message = '密码不能超过 63 位字符。' } }

    $ctx = Get-TetheringContext
    if (-not $ctx) { return @{ Ok = $false; Message = '未检测到可用的网络连接。' } }
    if ($ctx.Capability -ne 'Enabled') { return @{ Ok = $false; Message = ('当前网络不支持热点（' + $ctx.Capability + '）。') } }

    $needStart = ($ctx.State -ne 'On')
    if ($needStart) {
        $r = Await ($ctx.Manager.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
        if ("$($r.Status)" -ne 'Success') {
            return @{ Ok = $false; Message = ('修改前先开启热点失败：' + $r.Status + ' ' + $r.AdditionalErrorMessage) }
        }
        Start-Sleep -Milliseconds 600
    }

    $applyError = ''
    try {
        $cfg = $ctx.Manager.GetCurrentAccessPointConfiguration()
        if (-not $cfg) { return @{ Ok = $false; Message = '读取热点配置失败，请先开启一次热点再试。' } }
        $cfg.Ssid = $NewSsid
        $cfg.Passphrase = $NewPass

        $op = $ctx.Manager.ConfigureAccessPointAsync($cfg)
        try {
            $res = Await $op ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
            Write-Log ('ConfigureAccessPoint = ' + $res.Status + ' SSID=' + $NewSsid)
            if ("$($res.Status)" -ne 'Success') {
                $applyError = "$($res.Status) $($res.AdditionalErrorMessage)"
            }
        } catch {
            # 部分系统上该异步结果的类型投影异常，此时改为读回实际配置来判定
            Write-Log ('ConfigureAccessPoint await 失败，改用读回校验：' + $_.Exception.Message)
        }
    } catch {
        return @{ Ok = $false; Message = ('修改失败：' + $_.Exception.Message) }
    }

    # 读回校验：等待状态从 InTransition 恢复，并核对名称密码是否真的生效
    $deadline = (Get-Date).AddSeconds(10)
    $applied = $false
    $readSsid = ''
    $readPass = ''
    $readState = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        try {
            $cfg2 = $ctx.Manager.GetCurrentAccessPointConfiguration()
            $readSsid = "$($cfg2.Ssid)"
            $readPass = "$($cfg2.Passphrase)"
            try { $readState = "$($ctx.Manager.TetheringOperationalState)" } catch { }
            if ($readSsid -eq $NewSsid -and $readPass -eq $NewPass) { $applied = $true; break }
        } catch { }
    }

    if ($applyError) {
        return @{ Ok = $false; Message = ('修改失败：' + $applyError) }
    }
    if (-not $applied) {
        return @{ Ok = $false; Message = ("修改没有生效，当前仍是「{0}」。`n可以先把热点关掉，再点一次保存。`n状态：{1}" -f $readSsid, $readState) }
    }

    return @{ Ok = $true; Message = ("已修改并立即生效。`n`n名称：{0}`n密码：{1}`n`n请用手机重新搜索该 Wi-Fi。" -f $NewSsid, $NewPass) }
}

# ---------------------------------------------------------------------
# 一键修复：启用无线网卡、拉起相关服务
# ---------------------------------------------------------------------
function Invoke-RepairSteps {
    $steps = New-Object System.Collections.Generic.List[string]
    $admin = Test-IsAdmin
    if (-not $admin) { $steps.Add('提示：当前不是管理员身份，部分修复项可能失败。') }

    $targets = @()
    try {
        $targets = Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
            ($_.PhysicalMediaType -match '802\.11|Wireless') -or
            ($_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11|WLAN')
        }
    } catch { }

    if ($targets.Count -eq 0) {
        $steps.Add('未检测到无线网卡：台式机需要插 USB 无线网卡才能开热点。')
    } else {
        foreach ($n in $targets) {
            if ($n.Status -eq 'Disabled') {
                try {
                    Enable-NetAdapter -Name $n.Name -Confirm:$false -ErrorAction Stop
                    $steps.Add('已启用网卡：' + $n.Name)
                } catch {
                    $steps.Add('启用网卡失败（需要管理员）：' + $n.Name)
                }
            }
        }
        $steps.Add('无线网卡：' + (($targets | ForEach-Object { $_.Name + '=' + $_.Status }) -join '，'))
    }

    foreach ($sn in @('WlanSvc', 'icssvc', 'SharedAccess')) {
        try {
            $svc = Get-Service -Name $sn -ErrorAction Stop
            if ($svc.Status -ne 'Running') {
                try {
                    Start-Service -Name $sn -ErrorAction Stop
                    $steps.Add('已启动服务：' + $sn)
                } catch {
                    $steps.Add('启动服务失败（需要管理员）：' + $sn)
                }
            }
        } catch {
            $steps.Add('服务不存在：' + $sn)
        }
    }

    $ctx = $null
    try { $ctx = Get-TetheringContext } catch { }
    if ($ctx) {
        $steps.Add('热点能力：' + $ctx.Capability)
        if ($ctx.State -eq 'Off' -and $ctx.Capability -eq 'Enabled') {
            $r = Start-Hotspot
            if ($r.Ok) { $steps.Add('已自动开启热点。') } else { $steps.Add('自动开启失败，可手动点「开启热点」。') }
        }
    }

    return ($steps -join "`r`n")
}

# ---------------------------------------------------------------------
# 诊断报告
# ---------------------------------------------------------------------
function Get-DiagnosticText {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('===== 移动热点诊断报告 =====')
    $lines.Add('时间        : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    try {
        $v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $lines.Add('系统        : ' + $v.ProductName + ' ' + $v.DisplayVersion + ' (Build ' + $v.CurrentBuild + ')')
    } catch { }
    $lines.Add('PowerShell  : ' + $PSVersionTable.PSVersion.ToString())
    if (Test-IsAdmin) { $lines.Add('管理员身份  : 是') } else { $lines.Add('管理员身份  : 否') }
    $lines.Add('')

    $lines.Add('[网络连接]')
    $ctx = $null
    try { $ctx = Get-TetheringContext } catch { }
    if ($ctx) {
        $lines.Add('上网连接    : ' + $ctx.ProfileName)
        try {
            $t = "$($ctx.Profile.NetworkAdapter.IanaInterfaceType)"
            $map = @{ '6' = '以太网'; '71' = 'Wi-Fi'; '23' = '宽带拨号/PPP'; '243' = '宽带拨号(PPPoE)'; '244' = 'VPN'; '9' = '令牌环' }
            if ($map.ContainsKey($t)) { $lines.Add('连接类型    : ' + $map[$t]) } else { $lines.Add('连接类型    : IANA ' + $t) }
        } catch { }
        $lines.Add('热点能力    : ' + $ctx.Capability)
        $lines.Add('热点状态    : ' + $ctx.State)
        $lines.Add('热点名称    : ' + $ctx.Ssid)
        $lines.Add('热点密码    : ' + $ctx.Passphrase)
        $lines.Add('已连设备    : ' + $ctx.ClientCount + ' 台')
    } else {
        $lines.Add('未检测到可用的网络连接')
    }
    $lines.Add('')

    $lines.Add('[无线网卡]')
    $found = $false
    try {
        $nics = Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
            ($_.PhysicalMediaType -match '802\.11|Wireless') -or
            ($_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11|WLAN')
        }
        foreach ($n in $nics) {
            $found = $true
            $lines.Add('  ' + $n.Name + '  |  ' + $n.InterfaceDescription + '  |  状态=' + $n.Status)
        }
    } catch { }
    if (-not $found) { $lines.Add('  未检测到无线网卡（台式机需外接 USB 无线网卡）') }
    $lines.Add('')

    $lines.Add('[相关服务]')
    foreach ($sn in @('WlanSvc', 'icssvc', 'SharedAccess')) {
        try {
            $s = Get-Service -Name $sn -ErrorAction Stop
            $lines.Add(('  {0,-14} {1,-10} {2}' -f $s.Name, $s.Status, $s.StartType))
        } catch {
            $lines.Add(('  {0,-14} 不存在' -f $sn))
        }
    }
    $lines.Add('')

    $lines.Add('[ICS 共享地址 192.168.137.x]')
    $found2 = $false
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -like '192.168.137.*' }
        foreach ($ip in $ips) {
            $found2 = $true
            $lines.Add('  ' + $ip.IPAddress + '  ->  ' + $ip.InterfaceAlias)
        }
    } catch { }
    if (-not $found2) { $lines.Add('  未分配（热点未开启时属正常）') }
    $lines.Add('')

    $lines.Add('[诊断结论]')
    if (-not $ctx) {
        $lines.Add('  未联网。请先拨号或插网线连上网络，再开启热点。')
    } elseif ($ctx.Capability -ne 'Enabled') {
        $lines.Add('  当前网络不支持热点共享（' + $ctx.Capability + '）。')
        $lines.Add('  可按顺序排查：① 无线网卡是否被禁用 ② 无线驱动是否支持承载网络')
        $lines.Add('  ③ 电脑是否插了无线网卡 ④ 网络是否真的连通。')
        $lines.Add('  也可以直接点「一键修复」自动处理前两项。')
    } elseif ($ctx.State -eq 'On') {
        $lines.Add('  热点正常工作中。')
        $lines.Add('  若手机连上却上不了网：关闭代理软件的 TUN 模式（如 Clash），或断开 VPN 后重试。')
    } else {
        $lines.Add('  热点能力正常，当前处于关闭状态，点「开启热点」即可。')
    }
    return ($lines -join "`r`n")
}

# ---------------------------------------------------------------------
# 图形界面
# ---------------------------------------------------------------------
function Get-UiFont([single]$Size, [string]$Style) {
    $styleEnum = [System.Drawing.FontStyle]::Regular
    if ($Style -eq 'Bold') { $styleEnum = [System.Drawing.FontStyle]::Bold }
    try {
        return (New-Object System.Drawing.Font('Microsoft YaHei UI', $Size, $styleEnum))
    } catch {
        try { return (New-Object System.Drawing.Font('Microsoft YaHei', $Size, $styleEnum)) } catch { }
        return (New-Object System.Drawing.Font([System.Drawing.FontFamily]::GenericSansSerif, $Size, $styleEnum))
    }
}

function Invoke-AgentAction([string[]]$Arguments, [hashtable]$ExtraEnv) {
    $resultFile = Join-Path $env:TEMP ('HS_result_' + [Guid]::NewGuid().ToString('N') + '.txt')
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $exe)) { $exe = 'powershell.exe' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $argText = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:ScriptPath
    if ($Arguments) { $argText = $argText + ' ' + ($Arguments -join ' ') }
    $psi.Arguments = $argText
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try { $psi.EnvironmentVariables['HS_RESULT'] = $resultFile } catch { }
    if ($ExtraEnv) {
        foreach ($k in $ExtraEnv.Keys) {
            try { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } catch { }
        }
    }

    $proc = $null
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { return ('无法启动子进程：' + $_.Exception.Message) }

    $deadline = (Get-Date).AddSeconds(40)
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
        try { [System.Windows.Forms.Application]::DoEvents() } catch { }
        Start-Sleep -Milliseconds 100
    }
    if (-not $proc.HasExited) {
        try { $proc.Kill() } catch { }
        return '操作超时，请稍后再试。'
    }

    $text = ''
    try {
        if (Test-Path $resultFile) {
            $text = [System.IO.File]::ReadAllText($resultFile, [System.Text.Encoding]::UTF8)
            Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
        }
    } catch { }

    if (-not $text) { return $null }
    $parts = $text -split "`r?`n", 2
    if ($parts[0] -eq 'OK') { return $null }
    if ($parts.Count -gt 1) { return $parts[1] }
    return '操作失败。'
}

function Update-UiState {
    $ctx = $null
    try { $ctx = Get-TetheringContext } catch { $ctx = $null }

    if (-not $ctx) {
        $script:CurrentState = 'None'
        $script:LblStatus.Text = '未检测到网络'
        $script:LblStatus.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
        $script:LblDot.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
        $script:LblSsid.Text = '—'
        $script:LblPass.Text = '—'
        $script:BtnToggle.Text = '开启热点'
        $script:BtnToggle.BackColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
        $script:LblNet.Text = '请先连接网络（宽带拨号 / 网线 / Wi-Fi），再点上面的按钮'
        return
    }

    $script:CurrentState = $ctx.State
    if ($ctx.State -eq 'On') {
        $script:LblStatus.Text = '热点已开启'
        $script:LblStatus.ForeColor = [System.Drawing.Color]::FromArgb(21, 128, 61)
        $script:LblDot.ForeColor = [System.Drawing.Color]::FromArgb(34, 197, 94)
        $script:BtnToggle.Text = '关闭热点'
        $script:BtnToggle.BackColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
    } else {
        $script:LblStatus.Text = '热点已关闭'
        $script:LblStatus.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
        $script:LblDot.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
        $script:BtnToggle.Text = '开启热点'
        $script:BtnToggle.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    }

    if ($ctx.Ssid) { $script:LblSsid.Text = $ctx.Ssid } else { $script:LblSsid.Text = '（未设置）' }
    if ($ctx.Passphrase) { $script:LblPass.Text = $ctx.Passphrase } else { $script:LblPass.Text = '（未设置）' }

    $net = '当前网络：' + $ctx.ProfileName + '　｜　已连设备：' + $ctx.ClientCount + ' 台'
    if ($ctx.Capability -ne 'Enabled') {
        $net = $net + "`r`n注意：此网络暂不支持共享（" + $ctx.Capability + '），可试试点「一键修复」'
    }
    $script:LblNet.Text = $net
}

function Show-ConfigDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '修改热点名称和密码'
    $dlg.ClientSize = New-Object System.Drawing.Size(380, 236)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::White
    $dlg.Font = Get-UiFont 9 'Regular'

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = '网络名称（SSID）'
    $l1.AutoSize = $true
    $l1.Location = New-Object System.Drawing.Point(24, 20)
    $l1.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $dlg.Controls.Add($l1)

    $t1 = New-Object System.Windows.Forms.TextBox
    $t1.Location = New-Object System.Drawing.Point(24, 42)
    $t1.Size = New-Object System.Drawing.Size(332, 26)
    $t1.Text = $script:LblSsid.Text
    $dlg.Controls.Add($t1)

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = '密码（至少 8 位）'
    $l2.AutoSize = $true
    $l2.Location = New-Object System.Drawing.Point(24, 82)
    $l2.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $dlg.Controls.Add($l2)

    $t2 = New-Object System.Windows.Forms.TextBox
    $t2.Location = New-Object System.Drawing.Point(24, 104)
    $t2.Size = New-Object System.Drawing.Size(332, 26)
    $t2.Text = $script:LblPass.Text
    $dlg.Controls.Add($t2)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '保存并应用'
    $ok.Location = New-Object System.Drawing.Point(24, 156)
    $ok.Size = New-Object System.Drawing.Size(160, 38)
    $ok.FlatStyle = 'Flat'
    $ok.FlatAppearance.BorderSize = 0
    $ok.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $ok.ForeColor = [System.Drawing.Color]::White
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Location = New-Object System.Drawing.Point(196, 156)
    $cancel.Size = New-Object System.Drawing.Size(160, 38)
    $cancel.FlatStyle = 'Flat'
    $cancel.FlatAppearance.BorderSize = 1
    $cancel.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $cancel.BackColor = [System.Drawing.Color]::White
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($cancel)

    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    $r = $dlg.ShowDialog($script:Form)
    if ($r -ne [System.Windows.Forms.DialogResult]::OK) { $dlg.Dispose(); return }

    $newSsid = $t1.Text.Trim()
    $newPass = $t2.Text
    $dlg.Dispose()

    if ($newSsid.Length -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('网络名称不能为空。', '修改热点', 'OK', 'Warning') | Out-Null
        return
    }
    if ($newPass.Length -lt 8) {
        [System.Windows.Forms.MessageBox]::Show('密码至少需要 8 位字符。', '修改热点', 'OK', 'Warning') | Out-Null
        return
    }

    $script:BtnToggle.Enabled = $false
    $script:BtnToggle.Text = '正在应用…'
    [System.Windows.Forms.Application]::DoEvents()

    $err = Invoke-AgentAction -Arguments @('-NoGui', '-Quiet', '-SetSsid', '-SetPassword') -ExtraEnv @{ HS_SSID = $newSsid; HS_PASS = $newPass }

    $script:BtnToggle.Enabled = $true
    Update-UiState

    if ($err) {
        [System.Windows.Forms.MessageBox]::Show($err, '修改失败', 'OK', 'Error') | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show(("已修改并生效。`n`n名称：" + $newSsid + "`n密码：" + $newPass), '修改成功', 'OK', 'Information') | Out-Null
    }
}

function Show-DiagWindow {
    $text = Get-DiagnosticText
    $script:DiagText = $text

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '诊断信息'
    $dlg.ClientSize = New-Object System.Drawing.Size(640, 460)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::White
    $dlg.Font = Get-UiFont 9 'Regular'

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.ScrollBars = 'Both'
    $tb.WordWrap = $false
    $tb.Location = New-Object System.Drawing.Point(16, 16)
    $tb.Size = New-Object System.Drawing.Size(608, 380)
    $tb.Font = New-Object System.Drawing.Font('Consolas', ([single]9.5))
    $tb.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $tb.Text = $text
    $dlg.Controls.Add($tb)

    $copy = New-Object System.Windows.Forms.Button
    $copy.Text = '复制全部'
    $copy.Location = New-Object System.Drawing.Point(16, 408)
    $copy.Size = New-Object System.Drawing.Size(120, 36)
    $copy.FlatStyle = 'Flat'
    $copy.FlatAppearance.BorderSize = 1
    $copy.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $copy.BackColor = [System.Drawing.Color]::White
    $dlg.Controls.Add($copy)
    $copy.Add_Click({
        param($sender, $e)
        try { [System.Windows.Forms.Clipboard]::SetText($script:DiagText) } catch { }
        $sender.Text = '已复制'
    })

    $close = New-Object System.Windows.Forms.Button
    $close.Text = '关闭'
    $close.Location = New-Object System.Drawing.Point(504, 408)
    $close.Size = New-Object System.Drawing.Size(120, 36)
    $close.FlatStyle = 'Flat'
    $close.FlatAppearance.BorderSize = 0
    $close.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $close.ForeColor = [System.Drawing.Color]::White
    $close.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($close)
    $dlg.AcceptButton = $close

    $dlg.ShowDialog($script:Form) | Out-Null
    $dlg.Dispose()
}

function New-MainWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }

    $script:Form = New-Object System.Windows.Forms.Form
    $script:Form.Text = '移动热点开关'
    $script:Form.ClientSize = New-Object System.Drawing.Size(460, 436)
    $script:Form.StartPosition = 'CenterScreen'
    $script:Form.FormBorderStyle = 'FixedSingle'
    $script:Form.MaximizeBox = $false
    $script:Form.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $script:Form.Font = Get-UiFont 9 'Regular'

    $header = New-Object System.Windows.Forms.Panel
    $header.Location = New-Object System.Drawing.Point(0, 0)
    $header.Size = New-Object System.Drawing.Size(460, 100)
    $header.BackColor = [System.Drawing.Color]::White
    $script:Form.Controls.Add($header)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = 'Windows 移动热点'
    $lblTitle.AutoSize = $true
    $lblTitle.Location = New-Object System.Drawing.Point(24, 16)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
    $lblTitle.Font = Get-UiFont 9.5 'Regular'
    $header.Controls.Add($lblTitle)

    $script:LblStatus = New-Object System.Windows.Forms.Label
    $script:LblStatus.Text = '检测中…'
    $script:LblStatus.AutoSize = $true
    $script:LblStatus.Location = New-Object System.Drawing.Point(22, 44)
    $script:LblStatus.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
    $script:LblStatus.Font = Get-UiFont 17 'Bold'
    $header.Controls.Add($script:LblStatus)

    $script:LblDot = New-Object System.Windows.Forms.Label
    $script:LblDot.Text = [char]0x25CF
    $script:LblDot.AutoSize = $true
    $script:LblDot.Location = New-Object System.Drawing.Point(398, 44)
    $script:LblDot.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $script:LblDot.Font = Get-UiFont 18 'Regular'
    $header.Controls.Add($script:LblDot)

    # 信息卡片
    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point(24, 112)
    $card.Size = New-Object System.Drawing.Size(412, 138)
    $card.BackColor = [System.Drawing.Color]::White
    $script:Form.Controls.Add($card)
    $card.Add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(226, 232, 240)), 1
        $e.Graphics.DrawRectangle($pen, 0, 0, ($s.Width - 1), ($s.Height - 1))
        $pen.Dispose()
    })

    $cap1 = New-Object System.Windows.Forms.Label
    $cap1.Text = '网络名称'
    $cap1.AutoSize = $true
    $cap1.Location = New-Object System.Drawing.Point(18, 12)
    $cap1.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $card.Controls.Add($cap1)

    $script:LblSsid = New-Object System.Windows.Forms.Label
    $script:LblSsid.Text = '—'
    $script:LblSsid.AutoSize = $false
    $script:LblSsid.Size = New-Object System.Drawing.Size(376, 24)
    $script:LblSsid.Location = New-Object System.Drawing.Point(18, 30)
    $script:LblSsid.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $script:LblSsid.Font = Get-UiFont 11.5 'Bold'
    $script:LblSsid.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($script:LblSsid)

    $cap2 = New-Object System.Windows.Forms.Label
    $cap2.Text = '密码'
    $cap2.AutoSize = $true
    $cap2.Location = New-Object System.Drawing.Point(18, 64)
    $cap2.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $card.Controls.Add($cap2)

    $script:LblPass = New-Object System.Windows.Forms.Label
    $script:LblPass.Text = '—'
    $script:LblPass.AutoSize = $false
    $script:LblPass.Size = New-Object System.Drawing.Size(376, 24)
    $script:LblPass.Location = New-Object System.Drawing.Point(18, 82)
    $script:LblPass.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $script:LblPass.Font = Get-UiFont 11.5 'Bold'
    $script:LblPass.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($script:LblPass)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '点击名称或密码可复制'
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(18, 110)
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $hint.Font = Get-UiFont 8.5 'Regular'
    $card.Controls.Add($hint)

    # 主按钮
    $script:BtnToggle = New-Object System.Windows.Forms.Button
    $script:BtnToggle.Text = '开启热点'
    $script:BtnToggle.Location = New-Object System.Drawing.Point(24, 266)
    $script:BtnToggle.Size = New-Object System.Drawing.Size(412, 54)
    $script:BtnToggle.FlatStyle = 'Flat'
    $script:BtnToggle.FlatAppearance.BorderSize = 0
    $script:BtnToggle.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $script:BtnToggle.ForeColor = [System.Drawing.Color]::White
    $script:BtnToggle.Font = Get-UiFont 12.5 'Bold'
    $script:BtnToggle.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:Form.Controls.Add($script:BtnToggle)

    # 次级按钮
    $mkBtn = {
        param([string]$Text, [int]$X)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text
        $b.Location = New-Object System.Drawing.Point($X, 334)
        $b.Size = New-Object System.Drawing.Size(198, 38)
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
        $b.BackColor = [System.Drawing.Color]::White
        $b.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $script:Form.Controls.Add($b)
        return $b
    }
    $script:BtnEdit = & $mkBtn '修改名称/密码' 24
    $script:BtnRepair = & $mkBtn '一键修复' 238

    $script:LblNet = New-Object System.Windows.Forms.Label
    $script:LblNet.Text = ''
    $script:LblNet.Location = New-Object System.Drawing.Point(24, 380)
    $script:LblNet.Size = New-Object System.Drawing.Size(412, 46)
    $script:LblNet.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
    $script:LblNet.Font = Get-UiFont 8.5 'Regular'
    $script:Form.Controls.Add($script:LblNet)

    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = '诊断信息'
    $link.AutoSize = $true
    $link.Location = New-Object System.Drawing.Point(24, 348)
    $link.Visible = $false
    $link.LinkColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $script:Form.Controls.Add($link)

    # 事件
    $script:BtnToggle.Add_Click({
        if ($script:Busy) { return }
        $script:Busy = $true
        $script:BtnToggle.Enabled = $false
        $oldText = $script:BtnToggle.Text
        $script:BtnToggle.Text = '正在处理…'
        [System.Windows.Forms.Application]::DoEvents()

        $arg = '-On'
        if ($script:CurrentState -eq 'On') { $arg = '-Off' }
        $err = Invoke-AgentAction -Arguments @('-NoGui', '-Quiet', $arg)

        Update-UiState
        $script:BtnToggle.Enabled = $true
        $script:Busy = $false
        if ($err) {
            [System.Windows.Forms.MessageBox]::Show($err, '操作失败', 'OK', 'Error') | Out-Null
        }
    })

    $script:BtnEdit.Add_Click({ Show-ConfigDialog })

    $script:BtnRepair.Add_Click({
        $script:BtnRepair.Enabled = $false
        $script:BtnRepair.Text = '修复中…'
        [System.Windows.Forms.Application]::DoEvents()
        $r = $null
        try { $r = Invoke-RepairSteps } catch { $r = '修复过程出错：' + $_.Exception.Message }
        Update-UiState
        $script:BtnRepair.Enabled = $true
        $script:BtnRepair.Text = '一键修复'
        [System.Windows.Forms.MessageBox]::Show($r, '一键修复', 'OK', 'Information') | Out-Null
    })

    $script:LblSsid.Add_Click({
        $t = $script:LblSsid.Text
        if ($t -and $t -ne '—' -and $t -ne '（未设置）') {
            try {
                [System.Windows.Forms.Clipboard]::SetText($t)
                $script:LblNet.Text = '已复制网络名称：' + $t
            } catch { }
        }
    })

    $script:LblPass.Add_Click({
        $t = $script:LblPass.Text
        if ($t -and $t -ne '—' -and $t -ne '（未设置）') {
            try {
                [System.Windows.Forms.Clipboard]::SetText($t)
                $script:LblNet.Text = '已复制密码：' + $t
            } catch { }
        }
    })

    return $script:Form
}

# ---------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------
try {
    Write-Log ('==== 启动  On={0} Off={1} Toggle={2} Status={3} Diag={4} Repair={5} NoGui={6} SelfTest={7}' -f $On, $Off, $Toggle, $Status, $Diag, $Repair, $NoGui, $SelfTest)

    if ($SelfTest) {
        Initialize-WinRT | Out-Null
        $null = New-MainWindow
        Update-UiState
        $script:Form.Dispose()
        Write-Output 'SELFTEST OK'
        Write-Result $true 'SELFTEST OK'
        exit 0
    }

    if ($Status) {
        $ctx = Get-TetheringContext
        if (-not $ctx) { Write-Host '未检测到网络连接'; Write-Result $false '未检测到网络连接'; exit 1 }
        Write-Host ('网络连接 : ' + $ctx.ProfileName)
        Write-Host ('热点能力 : ' + $ctx.Capability)
        Write-Host ('热点状态 : ' + $ctx.State)
        Write-Host ('热点名称 : ' + $ctx.Ssid)
        Write-Host ('热点密码 : ' + $ctx.Passphrase)
        Write-Host ('已连设备 : ' + $ctx.ClientCount)
        Write-Result $true ('状态=' + $ctx.State)
        exit 0
    }

    if ($Diag) {
        $text = Get-DiagnosticText
        Write-Host $text
        Write-Result $true $text
        exit 0
    }

    if ($Repair) {
        $text = Invoke-RepairSteps
        Write-Host $text
        Write-Result $true $text
        if (-not $NoGui -and -not $Quiet) { Show-Message $text '一键修复' 'Info' }
        exit 0
    }

    if (-not [string]::IsNullOrEmpty($SetSsid) -or -not [string]::IsNullOrEmpty($SetPassword)) {
        $r = Set-HotspotConfig $SetSsid $SetPassword
        Write-Log ('SetConfig -> ' + $r.Ok + ' ' + $r.Message)
        if ($r.Ok) {
            Write-Host $r.Message
            Write-Result $true $r.Message
            if (-not $NoGui -and -not $Quiet) { Show-Message $r.Message '修改热点' 'Info' }
            exit 0
        } else {
            Write-Host $r.Message
            Write-Result $false $r.Message
            if (-not $NoGui -and -not $Quiet) { Show-Message $r.Message '修改热点失败' 'Error' }
            exit 1
        }
    }

    if ($On -or $Off -or $Toggle) {
        $r = $null
        if ($Off) { $r = Stop-Hotspot }
        elseif ($On) { $r = Start-Hotspot }
        else { $r = Invoke-Toggle }

        Write-Log ('操作结果 Ok=' + $r.Ok + ' : ' + $r.Message)
        Write-Host $r.Message
        if ($r.Ok) {
            Write-Result $true $r.Message
            if (-not $NoGui -and -not $Quiet) { Show-Message $r.Message '移动热点' 'Info' }
            exit 0
        } else {
            Write-Result $false $r.Message
            if (-not $NoGui -and -not $Quiet) { Show-Message $r.Message '操作失败' 'Error' }
            exit 1
        }
    }

    # 无参数：打开图形界面
    $form = New-MainWindow
    Update-UiState
    [System.Windows.Forms.Application]::Run($form)
    exit 0
} catch {
    Write-Log ('异常：' + $_.Exception.Message)
    Write-Result $false $_.Exception.Message
    Show-Message ('出错：' + $_.Exception.Message) '移动热点开关' 'Error'
    exit 1
}
