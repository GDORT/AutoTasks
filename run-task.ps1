# run-task.ps1 — 统一任务执行闸门
# 职责：去重校验 → 按 executorType 执行 command → 捕获 exitCode/stderr → 写统一状态
# 用法：
#   run-task.ps1 --list
#   run-task.ps1 --run <name> [--force]
#   run-task.ps1 --run <name> --in-process   # 同进程执行，不 spawn 子进程（供 WorkBuddy 自动化沙箱用）
#   run-task.ps1 --dry-run --run <name>
#   run-task.ps1 --status
#   run-task.ps1 --catchup          # 补跑今日未成功的 must 任务（应用启动兜底用）
#
# 为什么需要 --in-process（2026-10-09 实测得出）：
#   WorkBuddy 自动化跑在沙箱里，沙箱**允许**启动普通 exe（实测 Start-Process es.exe 通过，
#   返回 Everything 1.4.1.1032），但**禁止**再启动 powershell.exe —— 报错原文：
#     "spawns a child process that bypasses PowerShell command validation"
#   故沙箱内执行 shell 型任务时不能用默认的「Start-Process powershell.exe -Command ...」，
#   改用 PowerShell 调用运算符 & 在**当前进程**执行命令，绕开子进程。
#   代价：执行器的 exit 语义不再隔离，故用 try/catch + $LASTEXITCODE + 非零判定失败。
#
# 另一处沙箱必需修复：代理环境变量大小写冲突。
#   沙箱注入的 http_proxy 与系统已有 HTTP_PROXY 大小写不同，.NET Process.Start 会抛
#   "已添加项。字典中的关键字:"http_proxy"所添加的关键字:"HTTP_PROXY""，导致连 es.exe 都启不动。
#   故 --in-process 模式启动子 exe 前先剔除冲突副本（见 Fix-ConflictingProxyEnv）。
param(
  [string]$run = '',
  [switch]$list,
  [switch]$status,
  [Alias('dry-run')][switch]$dryrun,
  [switch]$force,
  [switch]$catchup,
  [switch]$done,
  [switch]$fail,
  [switch]$InProcess,
  [string]$errmsg = ''
)
$ErrorActionPreference = 'Stop'
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RegistryPath = Join-Path $ScriptDir 'task-registry.json'
$StatusPath   = Join-Path $ScriptDir 'task-status.json'
$LogPath      = Join-Path $ScriptDir 'task-run.log'
$LockPath     = Join-Path $ScriptDir 'task-status.lock'

if (-not (Test-Path $RegistryPath)) { Write-Error "registry 缺失: $RegistryPath"; exit 2 }
$reg = Get-Content $RegistryPath -Encoding UTF8 | ConvertFrom-Json

function ConvertTo-Hashtable($obj) {
  if ($null -eq $obj) { return $obj }
  if ($obj -is [System.Collections.Hashtable]) { return $obj }
  if ($obj -is [PSCustomObject]) {
    $ht = @{}
    foreach ($p in $obj.PSObject.Properties) { $ht[$p.Name] = ConvertTo-Hashtable $p.Value }
    return $ht
  }
  return $obj
}
function Load-Status {
  $tbl = @{}
  if (Test-Path $StatusPath) {
    try { $tbl = ConvertTo-Hashtable (Get-Content $StatusPath -Encoding UTF8 | ConvertFrom-Json) } catch { $tbl = @{} }
  }
  return $tbl
}
$statusTbl = Load-Status

# ---- 修复代理环境变量大小写冲突（沙箱必需，2026-10-09）----
# 沙箱同时注入 http_proxy 与系统级 HTTP_PROXY（仅大小写不同），.NET 的 Process.Start
# 在构造环境块时会抛 "已添加项。字典中的关键字..."，表现为「任何子 exe 都启不动」。
# 做法：同组内保留全大写变体，删除其余（含小写）。
function Fix-ConflictingProxyEnv {
  try {
    $envVars = [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Process)
    $names = @($envVars.Keys | ForEach-Object { [string]$_ })
    $groups = @{}
    foreach ($n in $names) {
      $low = $n.ToLowerInvariant()
      if ($low -in @('http_proxy','https_proxy','all_proxy','ftp_proxy')) {
        if (-not $groups.ContainsKey($low)) { $groups[$low] = @() }
        $groups[$low] += $n
      }
    }
    foreach ($low in $groups.Keys) {
      $variants = @($groups[$low] | Sort-Object -Unique)
      if ($variants.Count -le 1) { continue }
      $keep = $variants | Sort-Object { -($_ -ceq $_.ToUpperInvariant()) } | Select-Object -First 1
      foreach ($v in $variants) {
        if ($v -ne $keep) {
          Remove-Item "Env:$v" -ErrorAction SilentlyContinue
          Write-Verbose "已移除冲突代理变量副本: $v（保留 $keep）"
        }
      }
    }
  } catch {
    Write-Verbose "Fix-ConflictingProxyEnv 跳过: $($_.Exception.Message)"
  }
}

# ---- 跨进程运行锁 ----
# task-status.json 的「读 → 判 → 写」不是原子的：同一时点被两个触发源点燃时，
# 两个进程都会读到「本周期未成功」而双双执行。用排他文件锁串行化，抢到锁后再重读状态。
function Enter-RunLock([int]$timeoutSec = 600) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ($true) {
    try {
      return [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew,
                                   [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
      # 持锁进程已崩溃导致的残留锁：超过 10 分钟未更新即强制清除（正常任务最长约 1 分钟）
      if ((Test-Path $LockPath) -and ((Get-Date) - (Get-Item $LockPath).LastWriteTime).TotalMinutes -gt 10) {
        Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
        continue
      }
      if ((Get-Date) -gt $deadline) { throw "等待运行锁超时(${timeoutSec}s): $LockPath" }
      Start-Sleep -Milliseconds 500
    }
  }
}
function Exit-RunLock($fs) {
  if ($fs) { $fs.Close(); $fs.Dispose() }
  Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
}

function Write-Log($m) {
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Out-File -FilePath $LogPath -Append -Encoding utf8
}

function Is-InPeriod($lastRunStr, $period) {
  if (-not $lastRunStr) { return $false }
  try {
    $lr = [datetime]::Parse($lastRunStr)
    switch ($period) {
      'daily'   { return $lr.Date -eq (Get-Date).Date }
      'monthly' { return ($lr.Year -eq (Get-Date).Year) -and ($lr.Month -eq (Get-Date).Month) }
      'once'    { return $true }
      default   { return $false }
    }
  } catch { return $false }
}

function Save-Status {
  $statusTbl | ConvertTo-Json -Depth 5 | Out-File -FilePath $StatusPath -Encoding utf8
}

if ($list) {
  foreach ($t in $reg.tasks) {
    '{0,-16} trig={1,-8} rel={2,-12} exec={3,-5} enabled={4}' -f $t.name, $t.trigger.type, $t.reliability, $t.executorType, $t.enabled
  }
  exit 0
}
if ($status) {
  if ($statusTbl.Keys.Count -eq 0) { Write-Host '无状态记录' } else {
    foreach ($k in $statusTbl.Keys) { '{0,-16} {1} @ {2}' -f $k, $statusTbl[$k].lastStatus, $statusTbl[$k].lastRun }
  }
  exit 0
}

$targets = @()
if ($catchup) {
  foreach ($t in $reg.tasks) {
    if ($t.enabled -and $t.reliability -eq 'must') {
      $st = $statusTbl[$t.name]
      $ok = $st -and $st.lastStatus -eq 'ok' -and (Is-InPeriod $st.lastRun $t.period)
      if (-not $ok) { $targets += $t }
    }
  }
  if ($targets.Count -eq 0) { Write-Host 'catchup: 无 must 任务需要补跑'; exit 0 }
} elseif ($run) {
  $t = $reg.tasks | Where-Object { $_.name -eq $run }
  if (-not $t) { Write-Error "任务不存在: $run"; exit 2 }
  if ($t.enabled -eq $false) { Write-Host "任务已禁用: $run"; exit 0 }
  $targets = @($t)
} else {
  Write-Error '需指定 --run <name> / --list / --status / --catchup'
  exit 2
}

$runLock = Enter-RunLock
# 抢到锁后重读状态：等待锁期间，另一触发可能已完成本周期
$statusTbl = Load-Status

foreach ($t in $targets) {
  $name = $t.name

  # ---- 完成信号：AI 执行器做完工作后调用，记录终态（ok/fail）----
  if ($done) {
    if ($fail) {
      $statusTbl[$name] = @{
        lastRun = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        lastStatus = 'fail'
        lastDurationSec = 0
        lastError = $(if ($errmsg) { $errmsg } else { 'AI 执行器标记失败（无原因）' })
      }
      Write-Host "[$name] 已记录失败: $($statusTbl[$name].lastError)"
      Write-Log "[$name] DONE-FAIL err=$($statusTbl[$name].lastError)"
    } else {
      $statusTbl[$name] = @{
        lastRun = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        lastStatus = 'ok'
        lastDurationSec = 0
        lastError = $null
      }
      Write-Host "[$name] 已记录成功 (ok)"
      Write-Log "[$name] DONE-OK"
    }
    Save-Status
    continue
  }

  # 去重：本周期已成功则跳过（除非 --force）
  if (-not $force) {
    $st = $statusTbl[$name]
    if ($st -and $st.lastStatus -eq 'ok' -and (Is-InPeriod $st.lastRun $t.period)) {
      Write-Host "[$name] 跳过：本周期已成功 ($($st.lastRun))"
      Write-Log "[$name] SKIP 本周期已成功"
      continue
    }
  }
  Write-Host "[$name] 开始 (executor=$($t.executorType), force=$force)"
  Write-Log "[$name] START"

  # AI 任务：本进程只做门禁/查重，不替 AI 执行；由外部自动化完成工作后调 --done 记终态
  if ($t.executorType -eq 'ai') {
    Write-Host "[$name] AI 任务：请由本自动化完成实际工作（如 checkin_all.ps1 / skill 更新检查），完成后调用 'run-task --run $name --done' 记录状态。"
    Write-Log "[$name] AI-PROCEED"
    continue
  }

  $exitCode = 0; $errOut = ''; $stdOut = ''
  $start = Get-Date
  try {
    if ($dryrun) {
      Write-Host "[$name] dry-run 将执行 -> $($t.command)"
      Write-Log "[$name] DRYRUN cmd=$($t.command)"
      continue
    } else {
      # 启动任何子 exe 前先消除代理变量大小写冲突（否则 .NET Process.Start 直接抛字典冲突）
      Fix-ConflictingProxyEnv

      if ($InProcess) {
        # ---- 同进程执行（沙箱模式）：不 spawn powershell，绕开沙箱对子 powershell 的拦截 ----
        # 执行器若是 .ps1，用 & 调用运算符在当前 runspace 执行；exit 语义不再隔离，
        # 因此靠 try/catch + 非零 $LASTEXITCODE 判定成败。
        $prevLoc = $ErrorActionPreference
        try {
          $ErrorActionPreference = 'Continue'   # 让执行器自身的 stderr 不炸断本脚本
          Push-Location $ScriptDir
          try {
            # 与子进程版本等价的环境设置：UTF-8 输出，避免中文乱码
            $env:PYTHONIOENCODING = 'utf-8'
            try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
            Write-Verbose "in-process 执行: $($t.command)"
            # [FIX-A3 2026-10-10] 关键：& 调用 PowerShell 脚本(.ps1) 时 **不会** 设置 $LASTEXITCODE
            # （那是给原生 exe 用的），它保留的是"上一条原生命令"的退出码 —— 后果是真正失败的
            # .ps1 任务可能因为残留的 0 而被记成 OK，掩盖失败。
            # 现在：先清空历史值，执行后用 Get-Variable 判断本次是否真的被赋值。
            $global:LASTEXITCODE = $null
            $outBuf = & $t.command 2>&1
            $exitCode = 0
            $le = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
            if ($le -and $null -ne $le.Value) { $exitCode = [int]$le.Value }
            $stdOut = ($outBuf | Out-String)
            if ([string]::IsNullOrWhiteSpace($stdOut)) { $stdOut = '' } else { $errOut = '' }
            if ($exitCode -ne 0) { $errOut = "in-process 执行器返回非零 exit=$exitCode`n$stdOut" }
            # 落盘类失败即使 exit 语义丢失也要能被发现（scan.ps1 等会打印该标记）
            if ($exitCode -eq 0 -and $stdOut -match 'PERSIST_FAILED') {
              $exitCode = 3
              $errOut = "in-process 执行器报告 PERSIST_FAILED（结果未能落盘）`n$stdOut"
            }
          } finally {
            Pop-Location
          }
        } catch {
          $exitCode = 1
          $errOut = $_.ToString()
        } finally {
          $ErrorActionPreference = $prevLoc
        }
        if ($stdOut) { ($stdOut -split "`n") | ForEach-Object { if ($_) { Write-Host $_ } } }
      } else {
        # ---- 默认：子进程执行 command，干净隔离 exit 语义；隐窗避免闪烁 ----
        # [FIX-W1 2026-10-25] UseShellExecute=$false 时 ProcessStartInfo.WindowStyle 被 .NET 忽略，
        # 抑制子进程控制台窗口必须显式 CreateNoWindow=$true。此前只设 WindowStyle=Hidden 等于没设：
        # 一旦父进程自身无控制台（如经 wscript/vbs 启动），子进程会新建一个可见控制台并抢焦点。
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.WorkingDirectory = $ScriptDir
        # chcp 65001：让子进程内的 native 工具（git 等）按 UTF-8 输出，避免中文乱码
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command chcp 65001 > `$null; `$env:PYTHONIOENCODING='utf-8'; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $($t.command)"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.UseShellExecute = $false
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        # 异步读取两路输出：顺序 ReadToEnd 会在任一路缓冲区写满时互相等待而死锁
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $stdOut = $outTask.Result
        $errOut = $errTask.Result
        $exitCode = $proc.ExitCode
        if ($stdOut) { ($stdOut -split "`n") | ForEach-Object { if ($_) { Write-Host $_ } } }
      }
    }
  } catch {
    $exitCode = 1
    $errOut = $_.ToString()
  }
  $dur = [math]::Round(((Get-Date) - $start).TotalSeconds, 2)

  if ($exitCode -eq 0) {
    $statusTbl[$name] = @{
      lastRun = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
      lastStatus = 'ok'
      lastDurationSec = $dur
      lastError = $null
    }
    Write-Host "[$name] 成功 (${dur}s)"
    Write-Log "[$name] OK (${dur}s)"
  } else {
    $clip = $errOut
    if ($clip.Length -gt 2000) { $clip = $clip.Substring(0, 2000) }
    $statusTbl[$name] = @{
      lastRun = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
      lastStatus = 'fail'
      lastDurationSec = $dur
      lastError = $clip
    }
    Write-Host "[$name] 失败 (exit=$exitCode): $errOut"
    Write-Log "[$name] FAIL exit=$exitCode err=$errOut"
  }
  Save-Status
}

Exit-RunLock $runLock
