param(
    [switch]$SkipCleanup
)
$ErrorActionPreference = 'SilentlyContinue'
$base = Split-Path -Parent $MyInvocation.MyCommand.Definition
New-Item -ItemType Directory -Force -Path $base | Out-Null

$since = (Get-Date).AddDays(-14)
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

# ---------- 1. Scan user profile files changed in last 14 days ----------
$files = Get-ChildItem "C:\Users\GD" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt $since }
$totalMB = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)

$topDirs = $files | ForEach-Object {
    $rel = $_.FullName.Substring("C:\Users\GD\".Length)
    $top = if ($rel -match '^([^\\]+)') { $Matches[1] } else { '(root)' }
    [PSCustomObject]@{ Top = $top; Len = $_.Length }
} | Group-Object Top | ForEach-Object {
    [PSCustomObject]@{
        TopDir = $_.Name
        Files  = $_.Count
        SizeMB = [math]::Round((($_.Group | Measure-Object Len -Sum).Sum) / 1MB, 1)
    }
} | Sort-Object SizeMB -Descending | Select-Object -First 15

# ---------- 2. Newly created dirs under Program Files (install traces) ----------
$newProgs = Get-ChildItem "C:\Program Files", "C:\Program Files (x86)" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.CreationTime -gt $since } | Select-Object -ExpandProperty Name

# ---------- 3. Cleanup Temp installer leftovers ----------
$cleanedMB = 0.0
if (-not $SkipCleanup) {
    $patterns = @(
        "$env:TEMP\solo-cn-user-x64\*.exe",
        "$env:TEMP\vscode-stable-user-x64\*.exe",
        "$env:TEMP\codebuddy-marketplace-install-*"
    )
    foreach ($p in $patterns) {
        Get-Item $p -ErrorAction SilentlyContinue | ForEach-Object {
            $sz = (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $cleanedMB += $sz / 1MB
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $cleanedMB = [math]::Round($cleanedMB, 1)
}

# ---------- 4. Baseline comparison ----------
$baselineFile = Join-Path $base "baseline.json"
$baseline = 0.0
if (Test-Path $baselineFile) {
    try { $baseline = (Get-Content $baselineFile -Raw | ConvertFrom-Json).TotalMB } catch { $baseline = 0.0 }
}
$deltaMB = [math]::Round($totalMB - $baseline, 1)
@{ TotalMB = $totalMB; ScanTime = $stamp } | ConvertTo-Json | Set-Content $baselineFile -Encoding UTF8

# ---------- 5. 3GB threshold alert ----------
$alert = $false
$alertReason = ""
if ($deltaMB -gt 3072) { $alert = $true; $alertReason = "New files grew ${deltaMB}MB, exceeding 3GB threshold" }

# ---------- 6. Output: CSV log (append) + MD snapshot (overwrite) ----------
$alertStr = "no"
if ($alert) { $alertStr = "YES" }
$csvLine = [PSCustomObject]@{
    ScanTime = $stamp
    TotalMB  = $totalMB
    DeltaMB  = $deltaMB
    Alert    = $alertStr
    CleanedMB = $cleanedMB
}
$csvPath = Join-Path $base "scan_log.csv"
if (-not (Test-Path $csvPath)) {
    "ScanTime,TotalMB,DeltaMB,Alert,CleanedMB" | Set-Content $csvPath -Encoding UTF8
}
$csvLine | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content $csvPath -Encoding UTF8

$mdLines = New-Object System.Collections.ArrayList
[void]$mdLines.Add("# C drive scan snapshot $stamp")
[void]$mdLines.Add("")
[void]$mdLines.Add("- New files in last 14 days: **$totalMB MB** (delta vs baseline: $deltaMB MB)")
[void]$mdLines.Add("- Temp cleanup this run: $cleanedMB MB")
[void]$mdLines.Add("- Alert: $(if ($alert) { "WARNING: $alertReason" } else { "none" })")
[void]$mdLines.Add("")
[void]$mdLines.Add("## Top directories by new file size")
[void]$mdLines.Add("")
[void]$mdLines.Add("| Directory | Files | Size(MB) |")
[void]$mdLines.Add("|---|---|---|")
foreach ($d in $topDirs) {
    [void]$mdLines.Add("| $($d.TopDir) | $($d.Files) | $($d.SizeMB) |")
}
[void]$mdLines.Add("")
[void]$mdLines.Add("## New software traces (Program Files new dirs)")
[void]$mdLines.Add("")
if ($newProgs) { [void]$mdLines.Add(($newProgs -join ", ")) } else { [void]$mdLines.Add("none") }
[void]$mdLines.Add("")
[void]$mdLines.Add("## Notes")
[void]$mdLines.Add("- Scope: files under C:\Users\GD with LastWriteTime within 14 days; new dirs under Program Files within 14 days")
[void]$mdLines.Add("- Cleanup scope: TRAE/VSCode installer leftovers and codebuddy-marketplace install leftovers in Temp")
[void]$mdLines.Add("- Full history: scan_log.csv")

$mdLines | Set-Content (Join-Path $base "scan_report.md") -Encoding UTF8

# Alert marker file (read by the TRAE weekly task)
if ($alert) { $alertReason | Set-Content (Join-Path $base "ALERT.txt") -Encoding UTF8 }

Write-Output "Scan done: total ${totalMB}MB, delta ${deltaMB}MB, cleaned ${cleanedMB}MB, alert=$alert"
