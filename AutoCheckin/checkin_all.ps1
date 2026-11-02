# ============================================================
# 手动一键签到：依次触发 WorkBuddy / TRAE / 豆包
# 幂等安全：各自先查状态，已签则跳过（当天已 OK 的整家直接 no-op）
# 日志：各子脚本写入 checkin.log，一次运行每家一行结果
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

# ---- 1) WorkBuddy（签到 + 成长中心；结果由子脚本写入 checkin.log）----
# 子脚本成功 exit 0 / 失败 exit 5；任一失败则让整体任务标红（不再静默掩盖）
Write-Host "--- [1/3] WorkBuddy 签到 ---"
& powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "WorkBuddy\workbuddy_checkin.ps1")
if ($LASTEXITCODE -ne 0) {
    $failed += "WorkBuddy"
    Write-Warning "WorkBuddy 签到失败（exit=$LASTEXITCODE），详见 WorkBuddy\checkin.log"
}

# ---- 2) TRAE（走 trae_task.ps1，复用「当天已签则跳过」守卫）----
# 原实现直接调 checkin.js，绕过了 trae_task.ps1 的守卫；入口被重复触发时会重复请求。
# 改走 trae_task.ps1 后，与定时路径共用同一守卫，重复触发自动 no-op。
Write-Host "--- [2/3] TRAE 签到 ---"
& powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "TraeWork\trae_task.ps1")
if ($LASTEXITCODE -ne 0) {
    $failed += "TRAE"
    Write-Warning "TRAE 签到失败（exit=$LASTEXITCODE），详见 AutoCheckin\checkin.log"
}

# ---- 3) 豆包（CDP 接管客户端；启动走独立桌面，窗口不进你的桌面）----
# 已在运行 → 先结束旧实例；再到独立桌面 DoubaoBotDesktop 启动 → 签到 → 关闭。
# 全程不抢前台焦点（实测前台变化 0 次）。exit 6 = 未部署，属「跳过」而非失败。
Write-Host "--- [3/3] 豆包签到 ---"
& powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "Doubao\doubao_checkin.ps1")
$dbCode = $LASTEXITCODE
if ($dbCode -eq 6) {
    Write-Host "豆包签到已跳过（脚本未部署），详见 Doubao\checkin.log"
} elseif ($dbCode -ne 0) {
    $failed += "Doubao"
    Write-Warning "豆包签到失败（exit=$dbCode），详见 Doubao\checkin.log"
}

Write-Host "===== 手动一键签到结束 ====="

if ($failed.Count -gt 0) {
    Write-Error ("签到部分失败：$($failed -join ' / ')（已分别写入各自 checkin.log，上方有 WARNING 提示）")
    exit 1
}
