# chore-scan.ps1 — 差事汇总执行器（封装原自动化 7395cdd6 的 5 步流水线）
# 约束（与原自动化一致）：
#   对 Buddy 数据只读；git 不 push / reset / checkout；
#   不删除任何差事/源文件；不碰 sources/.kb/看板/模板；
#   不新建文件（仅允许 scan_changes.py 写 change_report.*，以及向 auto_scan_log.md 追加一行）。
$ErrorActionPreference = 'Stop'

# 本机配置(vault / python 等路径外置于 config.local.json, gitignored);向上查找并 dot-source
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

$Vault            = $cfg.vault
$ScanPy           = Join-Path $cfg.vault '30_projects\库维护\差事自动更新\scan_changes.py'
$AutoLog          = Join-Path $cfg.vault '30_projects\库维护\差事自动更新\auto_scan_log.md'
$ChangeReportJson = Join-Path $cfg.vault '30_projects\库维护\差事自动更新\change_report.json'
$ChangeReportMd   = Join-Path $cfg.vault '30_projects\库维护\差事自动更新\change_report.md'

# 托管 Python 优先；版本号勿写死，失效时取最新
$Py = $cfg.python
if (-not (Test-Path $Py)) {
  $Py = (Get-ChildItem 'C:\Users\GD\.workbuddy\binaries\python\versions\*\python.exe' |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

# 1) 扫描（只读 git，生成 change_report.json / .md）
& $Py -B $ScanPy
if ($LASTEXITCODE -ne 0) { throw "scan_changes 扫描失败 (exit $LASTEXITCODE)" }

# 2) 确定性更新各 差事进度.md 的 frontmatter + 日志块
& $Py -B $ScanPy --update
if ($LASTEXITCODE -ne 0) { throw "scan_changes --update 失败 (exit $LASTEXITCODE)" }

# 3) 有改动才本地提交（绝不 push）
$report = Get-Content $ChangeReportJson -Encoding UTF8 | ConvertFrom-Json
if ($report.git_error) { throw "git 读取错误: $($report.git_error)" }
if ($report.add_targets -and $report.add_targets.Count -gt 0) {
  # 逐个 add，避免 -join ' ' 把多路径并成单个 pathspec 导致 git 报 “No such file or directory”
  foreach ($t in $report.add_targets) {
    & git -C $Vault add -- $t
    if ($LASTEXITCODE -ne 0) { throw "git add 失败: $t" }
  }
  & git -C $Vault commit -m $report.commit_message
  if ($LASTEXITCODE -ne 0) { throw 'git commit 失败' }
}

# 4) 追加一行运行总结（UTF-8 无 BOM 追加，避免文件被插入 BOM）
$summary = $report.result_summary
$line = "$(Get-Date -Format 'yyyy-MM-dd')  $summary"
[System.IO.File]::AppendAllText($AutoLog, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

# 5) 清理（无异常才删 change_report.*）
Remove-Item $ChangeReportJson -Force -ErrorAction SilentlyContinue
Remove-Item $ChangeReportMd   -Force -ErrorAction SilentlyContinue

Write-Host "[chore-scan] 完成: $summary"
