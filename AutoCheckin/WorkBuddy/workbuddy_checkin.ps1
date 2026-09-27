# ============================================================
# WorkBuddy check-in wrapper (thin shim) v2
# Strategy (consistent with TRAE side):
#   1) If today's [WorkBuddy] [OK] already exists in the shared
#      log  ->  exit silently (no duplicate execution, no client
#      launch).
#   2) Otherwise ensure the WorkBuddy client is running (the
#      skill script locates the at-rest key by scanning the
#      running client's process memory). Start it if needed.
#   3) Run the skill script (idempotent) and append the result
#      to the shared log.
# Scheduled tasks AutoCheckin.WorkBuddy.* keep pointing at THIS
# file, so no task re-registration is needed.
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

$Py          = $cfg.python
if (-not (Test-Path $Py)) { $Py = "python" }
$SkillScript = $cfg.skillScript
$SkillLog    = $cfg.skillLog
$SharedLog   = Join-Path $PSScriptRoot 'checkin.log'
$WbExe       = $cfg.workbuddyExe

$today = Get-Date -Format "yyyy-MM-dd"

# ---- 1) Skip if today's WorkBuddy success is already logged ----
if (Test-Path $SharedLog) {
    $hit = Select-String -Path $SharedLog -Encoding UTF8 -Pattern ([regex]::Escape($today)) |
           Select-String -SimpleMatch "[WorkBuddy]", "[OK]"
    if ($hit) { exit 0 }
}

# ---- 2) Ensure the client is running (needed for key scan) ----
$wbProc = Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue
if (-not $wbProc) {
    if (Test-Path $WbExe) {
        Start-Process -FilePath $WbExe | Out-Null
        # wait for the process to appear (up to 60s)
        $deadline = (Get-Date).AddSeconds(60)
        while (-not (Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue)) {
            if ((Get-Date) -gt $deadline) { break }
            Start-Sleep -Seconds 3
        }
        # give the client time to finish login-state loading
        Start-Sleep -Seconds 20
    }
}

# ---- 3) Run the skill script and log the result ----
if (Test-Path $SkillLog) { Remove-Item $SkillLog -Force -ErrorAction SilentlyContinue }

& $Py $SkillScript *> $null

$now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$detail = "no-result"
$status = "fail"
if (Test-Path $SkillLog) {
    $last = Get-Content $SkillLog -Tail 1 -Encoding UTF8
    if ($last -match "status=(\w+)\s*\|\s*action=([a-z_]+)\s*\|\s*(.*)$") {
        $status = $Matches[1]
        $detail = "action=" + $Matches[2] + " | " + $Matches[3]
    } elseif ($last) {
        $detail = $last
    }
}

if ($status -eq "ok") {
    Add-Content -Path $SharedLog -Value "$now  [WorkBuddy]  [OK] $detail" -Encoding UTF8
} else {
    Add-Content -Path $SharedLog -Value "$now  [WorkBuddy]  [FAIL] $detail" -Encoding UTF8
}
exit $(if ($status -eq "ok") { 0 } else { 5 })
