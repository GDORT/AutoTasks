# ============================================================
# WorkBuddy 签到执行器 v3.2
# 后端：vendor\workbuddy-auto-signin\signin.py
#   上游 https://github.com/88lin/workbuddy-auto-signin （MIT）
#   单文件纯标准库；凭据解密靠 ELECTRON_RUN_AS_NODE=1 起一个
#   一次性的无窗口 helper 进程，跑完即退 —— 全程不启动 GUI、
#   不创建窗口，因此不需要「用完关闭客户端」逻辑。
# 覆盖：每日签到 + 成长中心（旅行礼物 / 任务 / 断登补登 /
#       连登兑换 / 盲盒 / 能量开 Buddy）
# 幂等：先查状态，已签则跳过领取；重复运行不会多领
# 守卫：当天已记录 [WorkBuddy] [OK] 则直接 exit 0（防重复触发）
# 日志：结果追加到同目录 checkin.log（一行）
# 退出码：0 成功（含今日已签）/ 5 失败
# 用法：powershell -File workbuddy_checkin.ps1 [-Force]
#   -Force 绕过「当天已 OK 则跳过」守卫，仅用于手动排障
#
# 【为什么用 cmd 重定向而不是 & 捕获或 Start-Process】
#   1) PS 5.1 用 [Console]::OutputEncoding（本机 GBK）解码原生程序输出，
#      python 打的 UTF-8 JSON 会变成乱码，ConvertFrom-Json 随即失败。
#   2) Start-Process 会把 $env: 逐项塞进 ProcessStartInfo.EnvironmentVariables，
#      而本机环境块同时存在 HTTPS_PROXY 与 https_proxy（大小写重复），
#      该字典大小写不敏感 → 直接抛「已添加项，关键字重复」。
#   cmd /c 重定向两样都避开：管道由 cmd 建，原始字节落盘，不经 PowerShell 解码；
#   也不重建环境字典。再用 Get-Content -Encoding UTF8 读回即可稳定解析。
#   （2026-11-01 两条均实测踩到）
# ============================================================

param([switch]$Force)

$ErrorActionPreference = "Continue"

# 本机配置外置于 config.local.json;向上查找并 dot-source
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

$Py        = $cfg.python
if (-not $Py -or -not (Test-Path $Py)) { $Py = 'python' }
$Signin    = $cfg.signinScript
$SharedLog = Join-Path $PSScriptRoot 'checkin.log'
$now       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

if (-not $Signin -or -not (Test-Path $Signin)) {
    Add-Content -Path $SharedLog -Value "$now  [WorkBuddy]  [FAIL] signin.py 不存在：$Signin" -Encoding UTF8
    exit 5
}

# ---- 1) 守卫：当天已有 [WorkBuddy] [OK] 则跳过 ----
# 必须同时满足「当天 + [WorkBuddy] + [OK]」三个条件。原写法把两个 -SimpleMatch
# 模式交给同一个 Select-String（多模式之间是 OR），导致含 [WorkBuddy] 的
# [FAIL]/[提示] 行也被当成「已成功」而跳过重试，此处用 Where-Object 逐条与判断。
# 日期兼容两种格式（本脚本用 yyyy-MM-dd；历史/其它写入方可能用 yyyy/M/d）。
if (-not $Force -and (Test-Path $SharedLog)) {
    $todayDash  = Get-Date -Format 'yyyy-MM-dd'
    $todaySlash = Get-Date -Format 'yyyy/M/d'
    $hit = Get-Content $SharedLog -Encoding UTF8 -ErrorAction SilentlyContinue |
           Where-Object { ($_ -like "*$todayDash*" -or $_ -like "*$todaySlash*") -and
                          ($_ -match '\[WorkBuddy\]') -and ($_ -match '\[OK\]') }
    if ($hit) { exit 0 }
}

# ---- 1.5) 清理大小写重复的代理变量 ----
# 本机环境块可能同时存在 HTTPS_PROXY 与 https_proxy（仅大小写不同），.NET 构造子进程
# 环境字典时报「已添加项，字典中的关键字:"HTTPS_PROXY"所添加的关键字:"https_proxy"」，
# 表现为连 cmd 都起不来（2026-11-01 15:21 实测）。run-task 路径已做同样清理，但本脚本
# 可能被单独手动调用，故自己也清一次；无冲突时不做任何改动。
try {
    $envNames = @([System.Environment]::GetEnvironmentVariables('Process').Keys | ForEach-Object { [string]$_ })
    foreach ($low in @('http_proxy','https_proxy','all_proxy','ftp_proxy')) {
        $variants = @($envNames | Where-Object { $_.ToLowerInvariant() -eq $low })
        if ($variants.Count -le 1) { continue }
        $upper = @($variants | Where-Object { $_ -ceq $_.ToUpperInvariant() })
        $keep  = if ($upper.Count -gt 0) { $upper[0] } else { $variants[0] }
        foreach ($v in $variants) {
            if ($v -ne $keep) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
        }
    }
} catch { }

# ---- 2) 跑 auto（签到 + 成长中心），stdout 由 cmd 原样落文件 ----
function Invoke-SigninOnce {
    param([string]$PyExe, [string]$SigninPy)
    $tag    = [guid]::NewGuid().ToString('N')
    $tmpOut = Join-Path $env:TEMP "wb-signin-$tag.json"
    $tmpErr = Join-Path $env:TEMP "wb-signin-$tag.err"

    $cmdLine = '"' + $PyExe + '" "' + $SigninPy + '" auto > "' + $tmpOut + '" 2> "' + $tmpErr + '"'
    & cmd.exe /c $cmdLine
    $rc = $LASTEXITCODE

    $outLines = @()
    $errLines = @()
    if (Test-Path $tmpOut) { $outLines = @(Get-Content $tmpOut -Encoding UTF8 -ErrorAction SilentlyContinue) }
    if (Test-Path $tmpErr) { $errLines = @(Get-Content $tmpErr -Encoding UTF8 -ErrorAction SilentlyContinue) }
    Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue

    # 正常结果在 stdout。2026-11-01 15:19 实测偶发「JSON 只出现在 stderr」，
    # 旧逻辑只扫 stdout → 明明 ALREADY（已签）却被判成「无 JSON 结果」记 FAIL。
    # 故两路都扫，取最后一个以 { 开头的行。
    $line = @(@($outLines) + @($errLines) | Where-Object { $_ -and $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    $parsed = $null
    if ($line -and $line.Count -gt 0) {
        try { $parsed = $line[0] | ConvertFrom-Json } catch { $parsed = $null }
    }
    $errLast = @($errLines | Where-Object { $_.Trim() } | Select-Object -Last 1)
    return @{ Rc = $rc; Obj = $parsed; Err = ($errLast -join '') }
}

# 重试：signin.py 读凭据偶发 PermissionError（2026-11-01 17:4x 实测：同一条命令先 ERROR
# 后 ALREADY）。本脚本一天只跑一次、失败即当天断签，且 100 积分按连续天数累进，断一天代价大，
# 故最多尝试 3 次（间隔 5s，最坏多花约 30s，对 PT30M 无压力）；签到逻辑幂等（服务端已签返回
# ALREADY），重试不会重复领取。
$maxAttempts = 3
$attempt = 0
$run     = $null
while ($attempt -lt $maxAttempts) {
    $attempt++
    $run = Invoke-SigninOnce -PyExe $Py -SigninPy $Signin
    if ($run.Obj -and [string]$run.Obj.result -ne 'ERROR') { break }
    if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 5 }
}

$obj = $run.Obj
$now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

if (-not $obj) {
    $fallback = $run.Err
    if (-not $fallback) { $fallback = "no-json-output rc=$($run.Rc)" }
    Add-Content -Path $SharedLog -Value "$now  [WorkBuddy]  [FAIL] 无 JSON 结果（尝试 $attempt 次）：$fallback" -Encoding UTF8
    exit 5
}

# CLAIMED=本次领取成功 / ALREADY=今日已签 / INACTIVE=活动期未开（都不是故障）
$res = [string]$obj.result
$okResults = @('CLAIMED', 'ALREADY', 'INACTIVE')
$isOk = $okResults -contains $res

$detail = "result=$res"
if ($obj.PSObject.Properties.Name -contains 'report' -and $obj.report) { $detail += " | " + $obj.report }
if ($obj.PSObject.Properties.Name -contains 'growth' -and $obj.growth) { $detail += " || 成长中心：" + $obj.growth }

if ($isOk) {
    $suffix = ''
    if ($attempt -gt 1) { $suffix = " | 第${attempt}次尝试才成功" }
    Add-Content -Path $SharedLog -Value "$now  [WorkBuddy]  [OK] $detail$suffix" -Encoding UTF8
    exit 0
} else {
    Add-Content -Path $SharedLog -Value "$now  [WorkBuddy]  [FAIL] $detail（共尝试 $attempt 次）" -Encoding UTF8
    exit 5
}
