# ============================================================
# 手动一键签到：同时触发 WorkBuddy 和 TRAE
# 幂等安全：各自先查状态，已签则跳过
# 日志：两个子脚本各自写入 checkin.log，一次运行各一行结果
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\checkin_all.ps1
# ============================================================

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

$Root  = Split-Path $MyInvocation.MyCommand.Path

Write-Host "===== 手动一键签到开始 ====="

$failed = @()

# ---- 1) WorkBuddy（结果由子脚本写入 checkin.log）----
# 子脚本成功 exit 0 / 失败 exit 5；任一失败则让整体任务标红（不再静默掩盖）
Write-Host "--- [1/2] WorkBuddy 签到 ---"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "WorkBuddy\workbuddy_checkin.ps1")
if ($LASTEXITCODE -ne 0) {
    $failed += "WorkBuddy"
    Write-Warning "WorkBuddy 签到失败（exit=$LASTEXITCODE），详见 WorkBuddy\checkin.log"
}

# ---- 2) TRAE（走 trae_task.ps1，复用「当天已签则跳过」守卫）----
# 原实现直接调 checkin.js，绕过了 trae_task.ps1 的守卫；入口被重复触发时会重复请求。
# 改走 trae_task.ps1 后，与定时路径共用同一守卫，重复触发自动 no-op。
Write-Host "--- [2/2] TRAE 签到 ---"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "TraeWork\trae_task.ps1")
if ($LASTEXITCODE -ne 0) {
    $failed += "TRAE"
    Write-Warning "TRAE 签到失败（exit=$LASTEXITCODE），详见 AutoCheckin\checkin.log"
}

Write-Host "===== 手动一键签到结束 ====="

if ($failed.Count -gt 0) {
    Write-Error ("签到部分失败：$($failed -join ' / ')（已分别写入各自 checkin.log，上方有 WARNING 提示）")
    exit 1
}