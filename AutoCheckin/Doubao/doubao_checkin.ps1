# ============================================================
# 豆包签到执行器 v4
# 后端：vendor\doubao-cdp  —— bluechonk/doubao-auto-checkin（MIT，npm 零依赖）
#   https://github.com/bluechonk/doubao-auto-checkin
#   上游本身完整可用；本机只改了 src/checkin.mjs 里 ANCHORS.signinEntryText
#   一处（2.33.5 起账号菜单入口由「免费领额度」更名为「免费用豆包」）——
#   这正是 README 与 docs/04 指定给客户端改版用的维护点，不是重写逻辑。
#
# 【v4 的关键改动：客户端不进你的桌面】
#   v3 让上游 spawn 启动客户端 → 窗口弹到前台，实测启动后 +0.9 秒前台就被
#   切走（用户在打字会被打断）。
#   v4 改用 CreateDesktop 创建独立桌面 DoubaoBotDesktop，用 CreateProcess
#   把豆包启动到那个桌面上 → 窗口属于另一个桌面，你的桌面既看不到、也不会
#   被抢焦点（实测：启动全程前台 hwnd 不变、变化次数 0）。
#   页面照常渲染、CDP 照常读到 DOM（实测 450 节点），点击走 CDP
#   Input.dispatchMouseEvent 注入渲染器，与桌面/前台焦点无关。
#
# 【客户端生命周期（2026-11-01 用户决定）】
#   不管进入时豆包是开是关，签到结束后一律关闭。
#   1. 当天已记 [OK]   → exit 0，完全不碰客户端
#   2. 调试端口已开     → 复用（--no-launch），签完关闭
#   3. 其余情况         → 结束已有实例 → 独立桌面启动 → 等端口 → 签到 → 关闭
#
# 【桌面生命周期：不会被留在系统里】
#   Windows 没有 DeleteDesktop —— 桌面对象是引用计数对象，关闭最后一个句柄
#   且其上无窗口引用时，由内核自动销毁。因此：
#     · 正常路径：finally 里 CloseDesktop → 桌面立即销毁
#     · 本进程被强杀 / 断电：句柄随进程回收，引用计数归零 → 同样销毁
#     · 桌面名固定为 DoubaoBotDesktop：万一下次进入时同名桌面还在（豆包残留
#       窗口持有引用），先用 OpenDesktop 接管，签完一起清掉，不会越攒越多
#   finally 里再用 OpenDesktop 反查一次，确认「打不开 = 已销毁」，写进日志。
#
# 【可控性措施】
#   ① 单实例互斥锁 Global\AutoTasks-DoubaoCheckin —— 手动跑与计划任务不会撞车
#   ② 全流程 try/finally —— 任何分支（成功/失败/超时/异常）都执行收尾
#   ③ 两道超时 —— 等端口 45s、CLI 300s，超时即收尾退出
#   ④ 不回退弹窗 —— 独立桌面起不来就判 FAIL，绝不为了签到去抢你的前台
#   ⑤ 收尾自证 —— 进程数 + 桌面对象是否销毁，逐项写日志
#   ⑥ 当天守卫 —— 已记 [OK] 直接 exit 0，不碰客户端、不重复点击
#
# 日志：Doubao\checkin.log，一行一条
# 退出码：0 成功（含今日已签）/ 5 失败 / 6 跳过（脚本未部署）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\doubao_checkin.ps1 [-Force]
# ============================================================

param([switch]$Force)

$ErrorActionPreference = 'Continue'

$__d = Split-Path -Parent $MyInvocation.MyCommand.Definition
$__lc = $null
while ($__d) {
  $__cand = Join-Path $__d 'load-config.ps1'
  if (Test-Path $__cand) { $__lc = $__cand; break }
  $__parent = Split-Path -Parent $__d
  if ($__parent -eq $__d) { break }
  $__d = $__parent
}
if (-not $__lc) { Write-Error 'load-config.ps1 未找到'; exit 1 }
. $__lc

$Here    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogFile = Join-Path $Here 'checkin.log'
$Port    = 9222
$DeskName = 'DoubaoBotDesktop'

# 系统代理会让本地 127.0.0.1 请求走代理而失败（实测 curl 报 upstream connect failed）。
# 本脚本是独立进程，直接在本进程清掉，退出即随进程消失。
foreach ($k in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy')) {
  if (Test-Path "Env:\$k") { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue }
}

function Write-Log {
  param([string]$Tag, [string]$Msg)
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [Doubao]  [$Tag] $Msg"
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
  Write-Host $line
}

function Test-PortOpen {
  param([int]$P, [int]$TimeoutMs = 800)
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect('127.0.0.1', $P, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
    $c.EndConnect($iar)
    return $true
  } catch {
    return $false
  } finally {
    $c.Close()
  }
}

function Wait-Port {
  param([int]$P, [int]$TimeoutSec = 45)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-PortOpen -P $P -TimeoutMs 400) { return $true }
    Start-Sleep -Milliseconds 400
  }
  return $false
}

function Get-DoubaoCount {
  return @(Get-Process -Name Doubao -ErrorAction SilentlyContinue).Count
}

function Stop-Doubao {
  if ((Get-DoubaoCount) -eq 0) { return }
  & taskkill /IM Doubao.exe /F 2>$null | Out-Null
  Start-Sleep -Milliseconds 1200
}

# 用 .NET Process 捕获输出：PS 5.1 直接管道会按 GBK 解码，中文会乱
function Invoke-Cli {
  param([string]$NodeExe, [string]$ScriptPath, [string[]]$CliArgs, [int]$TimeoutSec = 300)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $NodeExe
  $all = @($ScriptPath) + $CliArgs
  $quoted = @()
  foreach ($a in $all) {
    if ($a -match '[\s"]') { $quoted += ('"' + ($a -replace '"', '\"') + '"') } else { $quoted += $a }
  }
  $psi.Arguments = ($quoted -join ' ')
  $psi.WorkingDirectory = Split-Path -Parent (Split-Path -Parent $ScriptPath)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  try { [void]$p.Start() } catch { return @{ Code = -1; Out = ''; Err = "启动 node 失败: $($_.Exception.Message)" } }
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    try { $p.Kill() } catch { }
    return @{ Code = -1; Out = ''; Err = "超时（>${TimeoutSec}s）" }
  }
  return @{ Code = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
}

# ---- 独立桌面启动器（C# P/Invoke）----
# CreateDesktop 建一个不属于你桌面的 Desktop，CreateProcess 时 lpDesktop 指过去，
# 窗口就永远不出现在你的屏幕上，也不会抢前台焦点。
$__launcherSrc = @'
using System;
using System.Runtime.InteropServices;

public static class SilentLaunch
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateDesktop(string lpszDesktop, string lpszDevice, IntPtr pDevmode, int dwFlags, int dwDesiredAccess, IntPtr lpsa);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr OpenDesktop(string lpszDesktop, int dwFlags, bool fInherit, int dwDesiredAccess);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool CloseDesktop(IntPtr hDesktop);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateProcess(string lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles,
        uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
'@

$DesktopApi = $null
try {
  if (-not ('SilentLaunch' -as [type])) {
    Add-Type -TypeDefinition $__launcherSrc -Language CSharp -ErrorAction Stop
  }
  $DesktopApi = 'SilentLaunch' -as [type]
} catch {
  $DesktopApi = $null
}

# 返回 $true 表示「已没有未关闭的桌面句柄」（压根没建过也算干净）。
# 注意：Windows 没有 DeleteDesktop。桌面对象是引用计数对象 ——
#   关闭最后一个句柄、且其上没有窗口再持有引用时，由内核自动销毁。
#   所以即使本进程被强杀，句柄随进程回收，也不会积累出「一堆僵尸桌面」。
function Close-BotDesktop {
  param($H)
  if (-not $H -or $H -eq [IntPtr]::Zero) { return $true }
  if (-not $DesktopApi) { return $false }
  try { return [bool]$DesktopApi::CloseDesktop($H) } catch { return $false }
}

# 事后核验：桌面对象是否真的已被销毁（OpenDesktop 打不开 = 已销毁）。
# 这是「桌面没残留」的硬证据，比只看 CloseDesktop 返回值更可靠。
function Test-BotDesktopGone {
  if (-not $DesktopApi) { return $true }
  $h = [IntPtr]::Zero
  try {
    $h = $DesktopApi::OpenDesktop($DeskName, 0, $false, 0x00000001)  # DESKTOP_READOBJECTS
    if ($h -and $h -ne [IntPtr]::Zero) { [void]$DesktopApi::CloseDesktop($h); return $false }
    return $true
  } catch { return $true }
}

# 返回 @{ Ok; Hwnd/Handle; Msg } —— 成功时窗口在独立桌面上
function Start-DoubaoHidden {
  param([string]$Exe, [int]$P)
  if (-not $DesktopApi) {
    return @{ Ok = $false; Handle = [IntPtr]::Zero; Msg = '独立桌面 API 不可用（Add-Type 失败）' }
  }
  $h = [IntPtr]::Zero
  try {
    # 注意：PowerShell 把 $null 绑定到 .NET string 参数时会转成空串 ""，
    # 传给 Win32 就是「非 NULL 的无效设备名」→ CreateDesktop 报 err=87。
    # 必须用 [NullString]::Value 才是真 NULL。
    $h = $DesktopApi::CreateDesktop($DeskName, [NullString]::Value, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
    if (-not $h -or $h -eq [IntPtr]::Zero) {
      # 桌面可能已被上次异常退出留下，尝试打开
      $h = $DesktopApi::OpenDesktop($DeskName, 0, $false, 0x10000000)
    }
    if (-not $h -or $h -eq [IntPtr]::Zero) {
      return @{ Ok = $false; Handle = [IntPtr]::Zero; Msg = "CreateDesktop 失败，err=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    }

    $si = New-Object "$($DesktopApi.FullName)+STARTUPINFO"
    $si.cb     = [System.Runtime.InteropServices.Marshal]::SizeOf($si)
    $si.lpDesktop = $DeskName
    $si.dwFlags   = 1        # STARTF_USESHOWWINDOW
    $si.wShowWindow = 7      # SW_SHOWMINNOACTIVE

    $pi = New-Object "$($DesktopApi.FullName)+PROCESS_INFORMATION"
    $cmdLine = '"{0}" --remote-debugging-port={1}' -f $Exe, $P
    $ok = $DesktopApi::CreateProcess([NullString]::Value, $cmdLine, [IntPtr]::Zero, [IntPtr]::Zero,
                                     $false, 0, [IntPtr]::Zero, (Split-Path -Parent $Exe),
                                     [ref]$si, [ref]$pi)
    if (-not $ok) {
      $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
      [void](Close-BotDesktop $h)
      return @{ Ok = $false; Handle = [IntPtr]::Zero; Msg = "CreateProcess 失败，err=$err" }
    }
    [void]$DesktopApi::CloseHandle($pi.hProcess)
    [void]$DesktopApi::CloseHandle($pi.hThread)
    return @{ Ok = $true; Handle = $h; Msg = "已在独立桌面 $DeskName 启动，pid=$($pi.dwProcessId)" }
  } catch {
    [void](Close-BotDesktop $h)
    return @{ Ok = $false; Handle = [IntPtr]::Zero; Msg = "独立桌面启动异常：$($_.Exception.Message)" }
  }
}

# ---- 0) 前置校验 ----
$Bin = $cfg.doubaoScript
if (-not $Bin -or -not (Test-Path $Bin)) {
  Write-Log 'SKIP' "签到脚本未部署：$Bin"
  exit 6
}
$Node = $cfg.doubaoNode
if (-not $Node -or -not (Test-Path $Node)) {
  $Node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
}
if (-not $Node) {
  Write-Log 'FAIL' '找不到 node.exe（需要 Node >= 22）'
  exit 5
}
$Exe = $cfg.doubaoExe
if (-not $Exe -or -not (Test-Path $Exe)) {
  Write-Log 'FAIL' "豆包客户端路径无效：$Exe"
  exit 5
}

# ---- 1) 当天守卫（与 WorkBuddy 同口径）----
# 必须同时含 [Doubao] 与 [OK]，日期兼容 yyyy-MM-dd / yyyy/M/d，
# 避免把 [FAIL]/[SKIP]/[INFO] 行误判成「今天签过了」。
if (-not $Force -and (Test-Path $LogFile)) {
  $todayDash  = Get-Date -Format 'yyyy-MM-dd'
  $todaySlash = Get-Date -Format 'yyyy/M/d'
  $hit = Get-Content $LogFile -Encoding UTF8 -ErrorAction SilentlyContinue |
         Where-Object { ($_ -like "*$todayDash*" -or $_ -like "*$todaySlash*") -and
                        ($_ -match '\[Doubao\]') -and ($_ -match '\[OK\]') }
  if ($hit) {
    Write-Host "今日已签到，跳过（$todayDash）"
    exit 0
  }
}

# ---- 2) 单实例锁（防「手动跑」与「计划任务」撞车）----
# 后果可控的前提：同一时刻只允许一个实例碰客户端/端口/桌面。
# 否则 A 的 taskkill 会打断 B 的签到，A 的 CloseDesktop 会让 B 的窗口失去所属桌面。
#
# 用 Local\ 而不是 Global\：Global\ 命名内核对象需要 SeCreateGlobalPrivilege
# （只有管理员令牌才有），受限/降权令牌下 New-Object 直接抛 UnauthorizedAccessException。
# 本场景只需「同一交互会话内唯一」，计划任务与手动运行本来就在同一会话，Local\ 足够。
# 互斥锁自身不可用时**不能**因此放弃签到——降级为「无并发保护」继续，并留 WARN。
$mutex    = $null
$haveLock = $false
try {
  $mutex    = New-Object System.Threading.Mutex($false, 'Local\AutoTasks-DoubaoCheckin')
  $haveLock = $mutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
  $haveLock = $true                                   # 上个进程崩溃遗留，接管
}
catch {
  Write-Log 'WARN' "互斥锁不可用（$($_.Exception.Message)），本次不加并发保护继续"
  $haveLock = $true
}
if (-not $haveLock) {
  Write-Log 'SKIP' '另一个签到实例正在运行（互斥锁被占用），本次跳过'
  exit 0
}

$cliArgs    = @('--json', '--quiet')
$deskHandle = [IntPtr]::Zero
$t0         = Get-Date
$exitCode   = 0

# 主流程整体包在 try/finally：不管成功、失败、超时还是异常，
# finally 一定执行 → 豆包必被杀、桌面句柄必释放。这是「可控」的底线。
try {
  if (Test-PortOpen -P $Port) {
    Write-Log 'INFO' "调试端口 $Port 已开启，复用现有实例"
  }
  else {
    $running = Get-DoubaoCount
    if ($running -gt 0) {
      Stop-Doubao
      Write-Log 'INFO' "结束已有豆包实例（$running 个进程）"
    }

    $launch = Start-DoubaoHidden -Exe $Exe -P $Port
    if (-not $launch.Ok) {
      # 用户硬要求：签到全程不闪窗、不抢前台。
      # 常规启动（含 SW_SHOWMINNOACTIVE）对 Electron 无效，实测 +0.9s 必抢前台，
      # 所以这里不做「回退弹窗」——宁可本次不签，也不破坏你当前的输入/激活状态。
      Write-Log 'FAIL' "独立桌面启动失败（$($launch.Msg)）——按『不闪窗』要求不回退常规启动，本次放弃"
      $exitCode = 5
    }
    else {
      $deskHandle = $launch.Handle
      Write-Log 'INFO' $launch.Msg
      if (-not (Wait-Port -P $Port -TimeoutSec 45)) {
        Write-Log 'FAIL' "调试端口 $Port 在 45s 内未就绪"
        $exitCode = 5
      }
    }
  }

  # ---- 3) 执行签到 ----
  if ($exitCode -eq 0) {
    $t1  = Get-Date
    $run = Invoke-Cli -NodeExe $Node -ScriptPath $Bin -CliArgs $cliArgs -TimeoutSec 300
    $sec = [int]((Get-Date) - $t1).TotalSeconds

    $json = $null
    if ($run.Out -and $run.Out.Trim()) {
      try { $json = $run.Out | ConvertFrom-Json } catch { $json = $null }
    }

    $status = $null
    if ($json -and $json.result) { $status = $json.result.status }

    if ($run.Code -eq 0 -and ($status -eq 'checked_in' -or $status -eq 'already_checked_in' -or $status -eq 'dry_run')) {
      $delta = ''
      if ($json.result.reward -and $json.result.reward.delta -ne $null) {
        $delta = "$($json.result.reward.pointsBefore) -> $($json.result.reward.pointsAfter)"
      }
      if ($status -eq 'checked_in') {
        Write-Log 'OK' "result=checked_in | 签到成功 ${sec}s | 额度 $delta"
      } else {
        Write-Log 'OK' "result=already | 今日已签到 ${sec}s"
      }
      $exitCode = 0
    }
    else {
      $detail = ''
      if ($status) {
        $detail = "status=$status"
        if ($json.result.message) { $detail += " | $($json.result.message)" }
      } elseif ($run.Err) {
        $detail = ($run.Err.Trim() -split "`n" | Select-Object -Last 1)
      } else {
        $detail = "exit=$($run.Code)，无 JSON 输出"
      }
      Write-Log 'FAIL' $detail
      $exitCode = 5
    }
  }
}
finally {
  # ---- 4) 收尾：无条件执行（成功/失败/超时/异常都走这里）----
  $before     = Get-DoubaoCount
  Stop-Doubao
  $deskClosed = Close-BotDesktop $deskHandle
  $deskGone   = Test-BotDesktopGone
  $left       = Get-DoubaoCount
  $cost       = [int]((Get-Date) - $t0).TotalSeconds

  if ($deskGone)       { $deskState = '桌面对象已销毁' }
  elseif ($deskClosed) { $deskState = '桌面句柄已释放，但桌面仍被窗口占用' }
  else                 { $deskState = '桌面句柄释放失败' }

  if ($left -eq 0 -and $deskGone) {
    Write-Log 'INFO' "收尾：豆包进程 $before -> 0，$deskState，本次耗时 ${cost}s"
  }
  else {
    Write-Log 'WARN' "收尾不干净：豆包残留 $left 个进程，$deskState（下次运行会先结束残留）"
  }

  if ($haveLock) { try { [void]$mutex.ReleaseMutex() } catch { } }
}

exit $exitCode
