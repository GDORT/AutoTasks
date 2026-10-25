$ErrorActionPreference = 'SilentlyContinue'
$base = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Trigger source 1: periodic day (1st or 15th of month)
$day = (Get-Date).Day
$periodic = ($day -eq 1 -or $day -eq 15)

# Trigger source 2: 3GB delta threshold (scan.ps1 also refreshes baseline + cleans Temp)
# [FIX-A1 2026-10-10] 原实现匹配 'delta ([-\d.]+)MB'，但 scan.ps1 的输出里从来没有这个片段，
# 于是 $deltaMB 恒为 0、3GB 告警永不触发、ALERT.txt 永不生成 -- "可靠性兜底"实际是死的。
# 现改为读取 scan.ps1 显式打印的机读标记 DELTA_MB=<数值|NA>。
$scanOut = & "$base\scan.ps1" 2>&1 | Out-String
$scanExit = $LASTEXITCODE

$deltaMatch = [regex]::Match($scanOut, 'DELTA_MB=(?<v>[-\d.]+|NA)')
$deltaMB = 0.0
$deltaKnown = $false
if ($deltaMatch.Success -and $deltaMatch.Groups['v'].Value -ne 'NA') {
    $deltaMB = [double]$deltaMatch.Groups['v'].Value
    $deltaKnown = $true
}
$over3G = ($deltaKnown -and $deltaMB -gt 3072)

# 降级时数据面不可信（DELTA_MB=NA），不静默放过，单独标注
$degraded = ($scanOut -match 'MODE=degraded')

$alertFile = Join-Path $base 'ALERT.txt'
$reasons = @()
if ($periodic) { $reasons += "periodic day (day $day)" }
if ($over3G) { $reasons += "delta ${deltaMB}MB > 3GB" }
if ($degraded) { $reasons += "scan DEGRADED (Everything unavailable; delta unknown)" }
if ($scanExit -ne 0) { $reasons += "scan exit=$scanExit (persist failure?)" }

if ($reasons.Count -gt 0) {
    $reasons -join '; ' | Set-Content $alertFile -Encoding UTF8
    # 只在真正需要人介入时弹窗：超阈 / 降级 / 落盘失败。
    # 纯"周期性日期"(1/15) 只写 ALERT.txt 不弹窗，否则若该任务由每日触发器运行会天天弹。
    $needsPopup = ($over3G -or $degraded -or $scanExit -ne 0)
    if ($needsPopup) {
        try {
            $ws = New-Object -ComObject WScript.Shell
            $ws.Popup("C drive monitor: $($reasons -join ', '). Ask TRAE to analyze when ready.", 8, "C drive alert", 0x40) | Out-Null
        } catch {}
    }
} else {
    Remove-Item $alertFile -Force -ErrorAction SilentlyContinue
}

# 结论透出给 run-task / 日志（与 scan.ps1 相同的机读风格）
$deltaTxt = 'NA'
if ($deltaKnown) { $deltaTxt = $deltaMB }
Write-Output "CHECK_DELTA_MB=$deltaTxt"
Write-Output "CHECK_PERIODIC=$periodic"
Write-Output "CHECK_OVER3G=$over3G"
Write-Output "CHECK_DEGRADED=$degraded"
Write-Output "CHECK_ALERT=$($reasons.Count -gt 0)"
Write-Output "CHECK_REASONS=$($reasons -join '; ')"
exit 0
