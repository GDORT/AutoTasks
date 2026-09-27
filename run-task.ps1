# run-task.ps1 — 统一任务执行闸门
# 职责：去重校验 → 按 executorType 执行 command → 捕获 exitCode/stderr → 写统一状态
# 用法：
#   run-task.ps1 --list
#   run-task.ps1 --run <name> [--force]
#   run-task.ps1 --dry-run --run <name>
#   run-task.ps1 --status
#   run-task.ps1 --catchup          # 补跑今日未成功的 must 任务（应用启动兜底用）
# 说明：所有 Python/外部命令调用都经子进程执行，exit 语义干净；失败绝不静默。
param(
  [string]$run = '',
  [switch]$list,
  [switch]$status,
  [Alias('dry-run')][switch]$dryrun,
  [switch]$force,
  [switch]$catchup,
  [switch]$done,
  [switch]$fail,
  [string]$errmsg = ''
)
$ErrorActionPreference = 'Stop'
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RegistryPath = Join-Path $ScriptDir 'task-registry.json'
$StatusPath   = Join-Path $ScriptDir 'task-status.json'
$LogPath      = Join-Path $ScriptDir 'task-run.log'

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
$statusTbl = @{}
if (Test-Path $StatusPath) {
  try { $statusTbl = ConvertTo-Hashtable (Get-Content $StatusPath -Encoding UTF8 | ConvertFrom-Json) } catch { $statusTbl = @{} }
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
      # 子进程执行 command，干净隔离 exit 语义；隐窗避免闪烁
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = 'powershell.exe'
      $psi.WorkingDirectory = $ScriptDir
      $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `$env:PYTHONIOENCODING='utf-8'; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $($t.command)"
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.UseShellExecute = $false
      $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
      $proc = New-Object System.Diagnostics.Process
      $proc.StartInfo = $psi
      [void]$proc.Start()
      $stdOut = $proc.StandardOutput.ReadToEnd()
      $errOut = $proc.StandardError.ReadToEnd()
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      if ($stdOut) { ($stdOut -split "`n") | ForEach-Object { if ($_) { Write-Host $_ } } }
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
