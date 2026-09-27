# ============================================================
# TRAE daily check-in task wrapper
# Strategy (identical to the WorkBuddy side):
#   1) If today's [TRAE] [OK] already exists in the shared log
#      ->  exit silently (no duplicate execution).
#   2) Otherwise run checkin.js (idempotent: it checks the
#      server state first and reports "Already checked in today"
#      instead of claiming twice). The js writes its own [TRAE]
#      line into the shared checkin.log.
# ============================================================

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

$NodeExe   = $cfg.nodeExe
$JsPath    = Join-Path $PSScriptRoot "checkin.js"
$SharedLog = Join-Path $PSScriptRoot '..\checkin.log'

$today = Get-Date -Format "yyyy-MM-dd"

# ---- 1) Skip if today's TRAE success is already logged ----
if (Test-Path $SharedLog) {
    $hit = Select-String -Path $SharedLog -Encoding UTF8 -Pattern ([regex]::Escape($today)) |
           Select-String -SimpleMatch "[TRAE]", "[OK]"
    if ($hit) { exit 0 }
}

# ---- 2) Run the js (it logs its own result line) ----
if (-not (Test-Path $NodeExe)) {
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $SharedLog -Value "$now  [TRAE]  [FAIL] node runtime not found" -Encoding UTF8
    exit 3
}

& $NodeExe $JsPath *> $null
exit $LASTEXITCODE
