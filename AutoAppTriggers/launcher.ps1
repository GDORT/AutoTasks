param(
    [Parameter(Mandatory = $true)][string]$AppName
)
$ErrorActionPreference = 'SilentlyContinue'
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$regFile = Join-Path $base "app-registry.json"

$reg = Get-Content $regFile -Raw | ConvertFrom-Json
$app = $reg.apps | Where-Object { $_.name -eq $AppName }
if (-not $app) { exit 1 }

# 1. Launch the app itself (non-blocking)
Start-Process -FilePath $app.exePath -WorkingDirectory $app.workDir

# 2. Run all registered hooks in background (hidden, non-blocking)
foreach ($hook in $app.hooks) {
    $hookPath = if ([System.IO.Path]::IsPathRooted($hook)) { $hook } else { Join-Path $base $hook }
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $hookPath -WindowStyle Hidden
}
