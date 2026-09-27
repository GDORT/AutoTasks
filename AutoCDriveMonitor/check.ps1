$ErrorActionPreference = 'SilentlyContinue'
$base = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Trigger source 1: periodic day (1st or 15th of month)
$day = (Get-Date).Day
$periodic = ($day -eq 1 -or $day -eq 15)

# Trigger source 2: 3GB delta threshold (scan also refreshes baseline + cleans Temp)
$scanOut = & "$base\scan.ps1" 2>&1 | Out-String
$deltaMatch = [regex]::Match($scanOut, 'delta ([-\d.]+)MB')
$deltaMB = 0.0
if ($deltaMatch.Success) { $deltaMB = [double]$deltaMatch.Groups[1].Value }
$over3G = ($deltaMB -gt 3072)

$alertFile = Join-Path $base "ALERT.txt"
$reasons = @()
if ($periodic) { $reasons += "periodic day (day $day)" }
if ($over3G) { $reasons += "delta ${deltaMB}MB > 3GB" }

if ($reasons.Count -gt 0) {
    $reasons -join "; " | Set-Content $alertFile -Encoding UTF8
    try {
        $ws = New-Object -ComObject WScript.Shell
        $ws.Popup("C drive monitor: $($reasons -join ', '). Ask TRAE to analyze when ready.", 8, "C drive alert", 0x40) | Out-Null
    } catch {}
} else {
    Remove-Item $alertFile -Force -ErrorAction SilentlyContinue
}
