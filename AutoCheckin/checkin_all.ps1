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

# ---- 1) WorkBuddy（结果由子脚本写入 checkin.log）----
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "WorkBuddy\workbuddy_checkin.ps1")

# ---- 2) TRAE（结果由 checkin.js 写入 checkin.log）----
$node = $cfg.nodeExe
if (-not (Test-Path $node)) { $node = $cfg.traeExe }
& $node (Join-Path $Root "TraeWork\checkin.js") 2>&1 | Out-Host

Write-Host "===== 手动一键签到结束 ====="