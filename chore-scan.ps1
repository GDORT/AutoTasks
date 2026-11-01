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

# 失败日志落在**运行目录**（可配置），不写进库内文档：
#   config.local.json 里加 "choreScanLog": "<路径>" 即可覆盖；
#   缺省 = 本脚本同目录下的 chore-scan.run.log。
# 此前失败日既无日志也无报告，10-24 连挂两次后完全无从复盘。
# 注：change_report.* 故意不在失败时删除，保留现场供次日排查。
if ($cfg.choreScanLog) {
  $RunLog = $cfg.choreScanLog
} else {
  $RunLog = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'chore-scan.run.log'
}
trap {
  $__msg = ($_.Exception.Message -replace '\s+', ' ').Trim()
  try {
    $__dir = Split-Path -Parent $RunLog
    if ($__dir -and -not (Test-Path $__dir)) { New-Item -ItemType Directory -Force -Path $__dir | Out-Null }
    $__line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [失败] $__msg"
    [System.IO.File]::AppendAllText($RunLog, $__line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Write-Host "[chore-scan] 失败日志: $RunLog"
  } catch { }
  Write-Host "[chore-scan] 失败: $__msg"
  exit 1
}

# 原生命令的 stderr 在 $ErrorActionPreference='Stop' 下会变成终止错误，
# 导致真正的 git 报错被警告行顶掉（10-24 的 FAIL 就是这样只剩一句 CRLF 警告）。
# 这里临时降级为 Continue，把 stdout/stderr 一并收进错误信息。
function Invoke-GitText([string[]]$GitArgs) {
  $__prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    # 用 "$_" 逐条转字符串：Out-String 会把 git 的 stderr 渲染成带
    # NativeCommandError/CategoryInfo 的多行块，反而盖住真正的报错。
    return ((& git -C $Vault @GitArgs 2>&1 | ForEach-Object { "$_" }) -join ' ').Trim()
  } finally {
    $ErrorActionPreference = $__prev
  }
}

# 托管 Python 优先；版本号勿写死，失效时取最新
# [FIX-C2 2026-10-10] 原写法在 glob 无匹配、或 $cfg.python 为 $null 时会让 $Py 变成 $null，
# 后续 `& $Py` 只抛难定位的错误。现逐级兜底并给出明确报错。
$Py = $cfg.python
if ([string]::IsNullOrWhiteSpace($Py) -or -not (Test-Path $Py)) {
  $cand = @(Get-ChildItem 'C:\Users\GD\.workbuddy\binaries\python\versions\*\python.exe' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
  if ($cand.Count -gt 0) {
    $Py = $cand[0].FullName
  } else {
    $onPath = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($onPath) { $Py = $onPath.Source }
  }
}
if ([string]::IsNullOrWhiteSpace($Py) -or -not (Test-Path $Py)) {
  Write-Error "找不到可用 Python：config.local.json 的 python 不存在，且托管目录与 PATH 均未命中"
  exit 1
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
$committed = $false
if ($report.add_targets -and $report.add_targets.Count -gt 0) {
  # 安全边界：本任务只允许提交 10_差事/ 下的差事全目录。
  # 即使 scan_changes.py 未来误把 20_notes/30_projects 等路径放进 add_targets，也在这里直接拒绝。
  $outside = @($report.add_targets | Where-Object { $_ -notmatch '^10_差事/' })
  if ($outside.Count -gt 0) {
    throw "scan_changes 返回了 10_差事 之外的提交目标：$($outside -join ', ')"
  }
  # 逐个 add，避免 -join ' ' 把多路径并成单个 pathspec 导致 git 报 “No such file or directory”
  foreach ($t in $report.add_targets) {
    $addOut = Invoke-GitText @('add', '--', $t)
    if ($LASTEXITCODE -ne 0) { throw "git add 失败: $t | $addOut" }
  }
  # 用临时文件传提交说明，规避 PowerShell 把「含双引号/换行的字符串」传给 git.exe 时
  # 引号转义失效、被 Windows 命令行解析拆成多个 argv 元素、进而被 git 当成 pathspec 的 bug
  # （2026-10-24 实测：scan_changes 生成的改名描述含字面 " ，触发 pathspec '→' 报错）。
  $tmpMsg = Join-Path $env:TEMP ("chore-scan-commit-" + [guid]::NewGuid().ToString('N') + ".txt")
  [System.IO.File]::WriteAllText($tmpMsg, $report.commit_message, [System.Text.UTF8Encoding]::new($false))
  try {
    $commitOut = Invoke-GitText @('commit', '-F', $tmpMsg)
    if ($LASTEXITCODE -ne 0) { throw "git commit 失败 | $commitOut" }
  } finally {
    Remove-Item $tmpMsg -Force -ErrorAction SilentlyContinue
  }
  $committed = $true
}

# 4) 追加一行运行总结（提交后按实际结果生成，避免“已提交却写待更新”）
#    scan_changes.py 的 result_summary 只代表“扫描已识别”，不能直接当最终结果。
$changedCount = @($report.add_targets | Where-Object { $_ }).Count
if ($changedCount -eq 0) {
  $summary = '今日无差事变更，未改动'
} elseif ($committed) {
  $summary = "今日 $changedCount 个差事变更，已更新并提交"
} else {
  $summary = "今日 $changedCount 个差事变更，已更新（未提交）"
}
$line = "$(Get-Date -Format 'yyyy-MM-dd')  $summary"
[System.IO.File]::AppendAllText($AutoLog, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

# 5) 清理（无异常才删 change_report.*）
Remove-Item $ChangeReportJson -Force -ErrorAction SilentlyContinue
Remove-Item $ChangeReportMd   -Force -ErrorAction SilentlyContinue

# 6) Agent 对话自动总结（2026-10-28 起）：差事扫描收尾后跑，独立任务、失败不影响本任务结果。
#    只输出一行执行情况；正文写 30_projects/库维护/Agent对话自动总结/日志/<日期>.md。
try {
  $digestPy = Join-Path $Vault '30_projects\库维护\Agent对话自动总结\daily_digest.py'
  if (Test-Path $digestPy) {
    $digestLines = @(& $Py -B $digestPy 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
      Write-Host "[chore-scan] Agent 对话失败(exit $LASTEXITCODE)：$($digestLines -join ' ')"
    } else {
      $digestLines | ForEach-Object { Write-Host $_ }
    }
  } else {
    Write-Host "[chore-scan] Agent 对话跳过：找不到 $digestPy"
  }
} catch {
  Write-Host "[chore-scan] Agent 对话异常：$($_.Exception.Message)"
}

Write-Host "[chore-scan] 完成: $summary"
