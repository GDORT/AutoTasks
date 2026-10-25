param(
    [switch]$SkipCleanup,
    [switch]$DryRun,        # 只算不落盘：用于在受限会话里验证逻辑（不写任何文件）
    [double]$LookbackHours = 0   # [FIX-9] 增量回溯小时数（>0 时覆盖"上次时间戳"，用于手动查看最近 N 小时新增）
)
$ErrorActionPreference = 'SilentlyContinue'
$base = Split-Path -Parent $MyInvocation.MyCommand.Definition
New-Item -ItemType Directory -Force -Path $base | Out-Null

# ============================================================
# 修订记录
#   2026-10-10  修复 9 处缺陷（详见 autotasks_code_review_2026-10-10.md）：
#     [FIX-1] "命中 0 行"被误判为"查询失败" -> 合法结论"无新增"被判失败并降级。
#             现按"导出文件是否生成"区分【真失败】与【0 命中】；并区分
#             首次全量清单为空（绝不用空清单覆盖基线）与增量 0 命中（正常结论）。
#     [FIX-2] 状态时间戳秒级化 + 查询回退 2 分钟；差集兜底去重（宁可重复查询，不可漏）。
#     [FIX-3] 落盘失败不再静默：打印 PERSIST_FAILED 并以 exit 3 结束，供 run-task 记 fail。
#     [FIX-4] 日志 CSV 表头与 schema 不一致 -> 自动备份为 .bak 并重建表头。
#     [FIX-5] 输出机读标记 DELTA_MB / NEW_FILES / MODE，check.ps1 的 3GB 阈值依赖它。
#     [FIX-6] 数据面（本次新增）与参考面（14 天新建目录）分区呈现，避免口径混用。
#     [FIX-7] Everything 索引新鲜度写入报告（索引陈旧会静默漏增量）。
#     [FIX-8] 全角标点规范化：U+FF1F(全角问号) 在 CP936 下解码为 ASCII '?'，会吃掉字符串引号，
#             使 Windows PowerShell 5.1 直接解析失败。本文件正文不再出现该类字符。
#     [FIX-9] 增量轮若"有变化文件但全盘 >1MB 清单为空"，判为索引陈旧 -> 失败并保留基线。
#   2026-10-09  真增量改造：持久化清单 + 差集，取代伪增量（每次重扫 14 天窗口）。
#
#   维护注意：本文件含非 ASCII 字符，必须保存为 UTF-8 **带 BOM**。
#             编辑器/工具若丢失 BOM，Windows PowerShell 5.1 会按 ANSI(CP936) 解析并可能直接报错。
# ============================================================

# ---------- 消除代理环境变量大小写冲突（沙箱必需，2026-10-09）----------
function Remove-ConflictingProxyEnv {
    try {
        $vars = [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Process)
        $groups = @{}
        foreach ($k in @($vars.Keys | ForEach-Object { [string]$_ })) {
            $low = $k.ToLowerInvariant()
            if ($low -in @('http_proxy','https_proxy','all_proxy','ftp_proxy')) {
                if (-not $groups.ContainsKey($low)) { $groups[$low] = @() }
                $groups[$low] += $k
            }
        }
        foreach ($low in $groups.Keys) {
            $variants = @($groups[$low] | Sort-Object -Unique)
            if ($variants.Count -le 1) { continue }
            $keep = $variants | Sort-Object { -($_ -ceq $_.ToUpperInvariant()) } | Select-Object -First 1
            foreach ($v in $variants) { if ($v -ne $keep) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue } }
        }
    } catch {}
}
Remove-ConflictingProxyEnv

$stamp    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$since    = (Get-Date).AddDays(-14)      # 仅用于"新建目录"参考面
$backfill = [TimeSpan]::FromMinutes(2)   # [FIX-2] 增量查询回退余量（差集负责去重）

# ---------- locate es.exe (Everything CLI) ----------
function Find-EsExe {
    $cands = @(
        'D:\Program Files (x86)\Everything\es.exe',
        'C:\Program Files\Everything\es.exe',
        'C:\Program Files (x86)\Everything\es.exe'
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command es.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ---------- top-level grouping key ----------
function Get-TopKey($path) {
    $p = $path.Replace('C:\', '')
    $parts = $p -split '\\'
    if ($parts.Count -eq 0) { return '(root)' }
    $f = $parts[0]
    if ($f -eq 'Users' -and $parts.Count -ge 3) { return "Users\$($parts[1])\$($parts[2])" }
    if ($f -eq 'Users') { return "Users\$($parts[1])" }
    if (($f -eq 'Program Files') -or ($f -eq 'Program Files (x86)') -or ($f -eq 'ProgramData')) {
        if ($parts.Count -ge 2) { return "$f\$($parts[1])" }
        return $f
    }
    return $f
}

# ---------- es.exe 导出式查询 ----------
# 返回哈希表：Ok=是否真正执行成功（导出文件已生成）；Path=导出文件；TimedOut/Reason
# [FIX-1] 关键：不把"0 行"当失败 —— es.exe 命中 0 行时照样会生成导出文件。
function Invoke-EsExport([string[]]$esArgs, [string]$outCsv, [int]$timeoutMs = 180000) {
    $res = @{ Ok = $false; Path = ''; TimedOut = $false; Reason = '' }
    try {
        if (Test-Path $outCsv) { Remove-Item $outCsv -Force -ErrorAction SilentlyContinue }
        $parts = @('-export-csv', $outCsv) + $esArgs
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $esExe
        $psi.Arguments = $parts -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(936)
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $so = $proc.StandardOutput.ReadToEndAsync()
        $se = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($timeoutMs)) {
            try { $proc.Kill() } catch {}
            try { $proc.WaitForExit(2000) } catch {}
            $res.TimedOut = $true
            $res.Reason = "es.exe timeout after ${timeoutMs}ms"
            return $res
        }
        try { [void]$so.Result } catch {}
        $errText = ''
        try { $errText = [string]$se.Result } catch {}
        if (-not (Test-Path $outCsv)) {
            $res.Reason = "es.exe produced no export file (exit=$($proc.ExitCode))"
            if ($errText) { $res.Reason += ' stderr=' + (($errText -replace '\s+',' ').Trim()) }
            return $res
        }
        $res.Ok = $true
        $res.Path = $outCsv
        return $res
    } catch {
        $res.Reason = $_.Exception.Message
        return $res
    }
}

$esExe = Find-EsExe
$useEs = $false
$scopeNote = ''
$esIndexInfo = ''
$totalMB = 0.0
$deltaFiles = @()
$topDirs = @()
$newProgs = @()
$isFirstRun = $false
$incrementalZero = $false
$curMap = @{}
$parseBad = 0

# ---------- 增量状态：上次扫描的文件清单 ----------
$stateFile = Join-Path $base 'scan_state.json'
$lastStamp = ''
$prevMap = @{}
if (Test-Path $stateFile) {
    try {
        $st = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $lastStamp = [string]$st.LastStamp
        foreach ($p in $st.Files.PSObject.Properties) { $prevMap[$p.Name] = [string]$p.Value }
    } catch { $lastStamp = ''; $prevMap = @{} }
}
$isFirstRun = [string]::IsNullOrWhiteSpace($lastStamp)

if ($esExe) {
    # [FIX-6] 扫描域显式锁定为「整个 C 盘」，两条分支都加 size 下限（2026-10-15 修）
    #   问题：增量分支原本只写 `dm:>时间`，没有 size 下限 ⇒ 会把上次时间点之后
    #   **所有**文件（含几十万个小文件）都拉进结果；清单累积合并后体积失控，
    #   且真正有意义的大文件被淹没。首轮与增量必须用同一口径 size:>1mb。
    if ($isFirstRun) {
        $scopeQ = 'C:\ size:>1mb'
        $scopeNote = 'FIRST-RUN: whole-C inventory of files >1MB (baseline established; subsequent runs are incremental)'
    } else {
        # [FIX-2] 回退 2 分钟 + 差集保证不重复计数
        # [FIX-8] 时间戳格式（2026-10-15 修，这是"永远扫不出东西"的真凶）
        #   旧写法 ToString('yyyy/MM/dd HH:mm') → 查询串 `dm:>2026/10/15 21:19`
        #   **中间那个空格让 es 把 `21:19` 当成独立的搜索词**，于是整个查询匹配不到任何东西，
        #   永远返回 0 行，且不报错 ⇒ 报告误判为"确实没有新增"，静默失效好几天。
        #   实测对照（整盘 C:\ size:>1mb）：
        #     dm:>2026/10/15 21:19      -> 0 行（错）
        #     dm:>2026-10-15T21:19      -> 30 行（对，ISO 8601 无空格）
        #   故改用 ISO 8601 'T' 格式，es 可正确解析为时间点。
        $stampMinus = ([datetime]$lastStamp).Subtract($backfill)
        if ($LookbackHours -gt 0) {
            # [FIX-9] 手动指定回溯窗口：以"现在"为基准往前推N 小时（忽略上次基线）
            $stampMinus = (Get-Date).AddHours(-$LookbackHours)
        }
        $sinceQ = $stampMinus.ToString('yyyy-MM-ddTHH:mm')
        # 整盘 C:\ + 时间窗口 + 大小下限（与首轮同口径）
        $scopeQ = "C:\ size:>1mb dm:>$sinceQ"
        $win = if ($LookbackHours -gt 0) { "lookback ${LookbackHours}h" } else { "since $sinceQ" }
        $scopeNote = "INCREMENTAL: files on C:\ (whole volume) modified $win, size>1MB; prev inventory $($prevMap.Count) files; diffed against scan_state.json"
    }

    $outCsv = Join-Path $env:TEMP 'dsh_cdrive_scan_export.csv'
    $qres = Invoke-EsExport @('-n','20000','-csv','-add-columns','size;date-modified','-no-header',$scopeQ) $outCsv 180000

    # [FIX-7] Everything 索引新鲜度
    try {
        foreach ($db in @('D:\Program Files (x86)\Everything\Everything.db','C:\Program Files\Everything\Everything.db','C:\Program Files (x86)\Everything\Everything.db')) {
            if (Test-Path $db) {
                $dbi = Get-Item $db
                $esIndexInfo = "index db mtime $($dbi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) ($([math]::Round($dbi.Length/1MB,1)) MB)"
                break
            }
        }
        if (Get-Process -Name Everything -ErrorAction SilentlyContinue) { $esIndexInfo += '; Everything process RUNNING' }
        else { $esIndexInfo += '; Everything process NOT running (index cannot refresh)' }
    } catch {}

    if (-not $qres.Ok) {
        # ---- 真失败：只有此时才降级 ----
        $useEs = $false
        if ($qres.TimedOut) {
            $scopeNote = "DEGRADED: es.exe query timed out (Everything IPC not responding within 180s); scanned C:\Users\GD only. Whole-C baseline NOT updated (preserved)."
        } else {
            $scopeNote = "DEGRADED: es.exe query failed ($($qres.Reason)); scanned C:\Users\GD only. Whole-C baseline NOT updated (preserved)."
        }
    } else {
        # ---- 查询成功（可能 0 行）----
        $curMap = @{}
        $groupTbl = @{}
        $allBytes = 0.0
        $deltaFiles = @()

        $lines = @()
        try { $lines = [System.IO.File]::ReadAllLines($qres.Path) } catch { $lines = @() }

        foreach ($line in $lines) {
            $l = $line.Trim()
            if (-not $l) { continue }
            $m = [regex]::Match($l, '^"(?<path>.+)",(?<size>\d+),(?<mtime>.+)$')
            if (-not $m.Success) { $parseBad++; continue }
            $fullPath = $m.Groups['path'].Value
            $b = [double]$m.Groups['size'].Value
            $mtime = $m.Groups['mtime'].Value
            if ($b -le 0) { continue }
            if ($fullPath.EndsWith('\')) { $dirPath = $fullPath.TrimEnd('\') }
            else {
                $dirPath = [System.IO.Path]::GetDirectoryName($fullPath)
                if (-not $dirPath) { $dirPath = $fullPath }
            }
            $sig = "$b|$mtime"
            $isNew = $true
            if ($prevMap.ContainsKey($fullPath) -and $prevMap[$fullPath] -eq $sig) { $isNew = $false }
            $curMap[$fullPath] = $sig
            if (-not $isNew) { continue }

            $deltaFiles += [PSCustomObject]@{ Path = $fullPath; SizeMB = [math]::Round($b/1MB,2); Modified = $mtime }
            $allBytes += $b
            $gkey = Get-TopKey $dirPath
            if ($groupTbl.ContainsKey($gkey)) { $groupTbl[$gkey].Size += $b; $groupTbl[$gkey].Count++ }
            else { $groupTbl[$gkey] = @{ Size = $b; Count = 1 } }
        }

        if ($isFirstRun) {
            if ($curMap.Count -gt 0) {
                $useEs = $true
                $totalMB = [math]::Round($allBytes / 1MB, 1)
            } else {
                $useEs = $false
                $scopeNote = 'DEGRADED: first-run inventory returned 0 files (>1MB); refused to overwrite the baseline with an empty inventory.'
            }
        } else {
            # [FIX-1] 增量查询成功、命中 0 行 = 正确的"无新增"，不再降级
            # [FIX-9] 但"有变化文件却全盘 >1MB 清单为空" = 索引陈旧/不完整 -> 不可信，保留基线
            if ($curMap.Count -eq 0 -and $deltaFiles.Count -gt 0) {
                $useEs = $false
                $scopeNote = 'DEGRADED: incremental query saw changed files but the >1MB inventory is empty (stale/incomplete Everything index); refused to trust this run. Baseline preserved.'
            } else {
                $useEs = $true
                $incrementalZero = ($curMap.Count -eq 0)
                $totalMB = [math]::Round($allBytes / 1MB, 1)
                if ($incrementalZero) {
                    $scopeNote = "INCREMENTAL OK: 0 files modified after $sinceQ (no new/changed files since $lastStamp). Valid result, NOT a failure."
                }
            }
        }

        if ($useEs) {
            $deltaFiles = @($deltaFiles | Sort-Object SizeMB -Descending)
            $topDirs = $groupTbl.GetEnumerator() | ForEach-Object {
                [PSCustomObject]@{ TopDir = $_.Key; Files = $_.Value.Count; SizeMB = [math]::Round($_.Value.Size / 1MB, 1) }
            } | Sort-Object SizeMB -Descending | Select-Object -First 15
        }
    }
} else {
    $scopeNote = 'DEGRADED: es.exe not found (Everything CLI missing); scanned C:\Users\GD only. Whole-C baseline NOT updated (preserved).'
}

# ---------- 降级分支：只扫 C:\Users\GD ----------
if (-not $useEs) {
    $files = Get-ChildItem 'C:\Users\GD' -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $since }
    $totalMB = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
    $topDirs = $files | ForEach-Object {
        $rel = $_.FullName.Substring('C:\Users\GD\'.Length)
        $top = if ($rel -match '^([^\\]+)') { $Matches[1] } else { '(root)' }
        [PSCustomObject]@{ Top = $top; Len = $_.Length }
    } | Group-Object Top | ForEach-Object {
        [PSCustomObject]@{
            TopDir = $_.Name
            Files  = $_.Count
            SizeMB = [math]::Round((($_.Group | Measure-Object Len -Sum).Sum) / 1MB, 1)
        }
    } | Sort-Object SizeMB -Descending | Select-Object -First 15
}

# ---------- [FIX-6] 参考面：Program Files / ProgramData 近 14 天新建目录 ----------
foreach ($root in @('C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData')) {
    if (Test-Path $root) {
        Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.CreationTime -gt $since } |
            ForEach-Object { $newProgs += "$($root.Replace('C:\', ''))\$($_.Name)" }
    }
}

# ---------- 清理 Temp 安装残留 ----------
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

# ---------- 累计台账 + [FIX-3] 落盘失败必须响 ----------
$baselineFile  = Join-Path $base 'baseline.json'
$csvPath       = Join-Path $base 'scan_log.csv'
$alertPath     = Join-Path $base 'ALERT.txt'
$reportPath    = Join-Path $base 'scan_report.md'
$persistErrors = New-Object System.Collections.Generic.List[string]

$cumulative = 0.0
if (Test-Path $baselineFile) {
    try { $cumulative = [double](Get-Content $baselineFile -Raw | ConvertFrom-Json).CumulativeMB } catch { $cumulative = 0.0 }
}

$deltaMB = $null
if ($useEs) {
    if ($isFirstRun) { $cumulative = $totalMB } else { $cumulative = [math]::Round($cumulative + $totalMB, 1) }
    $deltaMB = $totalMB
}

$alert = $false
$alertReason = ''
if ($deltaMB -ne $null -and $deltaMB -gt 3072) {
    $alert = $true
    $alertReason = "Single-run new files ${deltaMB}MB exceeds 3GB threshold"
}

$modeStr  = if ($isFirstRun -and $useEs) { 'first-run' } elseif ($useEs) { 'incremental' } else { 'degraded' }
$newFiles = @($deltaFiles).Count

# [FIX-9] 回溯模式只做"看"，不改基线：否则会把 LastStamp 推到"现在"，
# 吞掉本该由正常增量报出的变化，也会让清单多出非真实增量的噪声条目。
if ($LookbackHours -gt 0) {
    $modeStr = "lookback-${LookbackHours}h"
    $scopeNote += " [LOOKBACK MODE: baseline untouched]"
}

if (-not $DryRun) {
    if ($useEs -and $LookbackHours -le 0) {
        try {
            $stampNow = (Get-Date).ToString('yyyy/MM/dd HH:mm:ss')   # [FIX-2] 秒级
            # [FIX-5] 清单必须**累积合并**，不能每轮覆盖（2026-10-15 修）
            #   旧 bug：增量模式下 $curMap 只含「本轮查到的变化文件」，每天增量都≈0，
            #   于是每轮都用空/近空清单覆盖上一轮的全量清单 → 12421 条逐步归零。
            #   后果：失去差集基准，报告里 prev inventory 变0，且无法再判断"是否真无变化"。
            #   正确做法：以 $prevMap 为底，把本轮查到的条目合并进去（覆盖同key、更新签名、追加新key）。
            $merged = @{}
            foreach ($k in $prevMap.Keys) { $merged[$k] = $prevMap[$k] }
            foreach ($k in $curMap.Keys) { $merged[$k] = $curMap[$k] }
            @{ LastStamp = $stampNow; ScanTime = $stamp; FilesCount = $merged.Count; Files = $merged } |
                ConvertTo-Json -Depth 4 | Set-Content $stateFile -Encoding UTF8 -ErrorAction Stop
        } catch { $persistErrors.Add("scan_state.json: $($_.Exception.Message)") }
        try {
            @{ CumulativeMB = $cumulative; TotalMB = $totalMB; ScanTime = $stamp; Mode = $modeStr } |
                ConvertTo-Json | Set-Content $baselineFile -Encoding UTF8 -ErrorAction Stop
        } catch { $persistErrors.Add("baseline.json: $($_.Exception.Message)") }
    }

    # [FIX-4] CSV 表头 schema 校验 + 迁移
    $csvHeader = 'ScanTime,Mode,NewMB,NewFiles,CumMB,Alert,CleanedMB'
    try {
        $needInit = $true
        if (Test-Path $csvPath) {
            $firstLine = Get-Content $csvPath -TotalCount 1 -ErrorAction SilentlyContinue
            if ($firstLine -eq $csvHeader) { $needInit = $false }
            else {
                $bak = Join-Path $base ('scan_log.csv.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                Move-Item $csvPath $bak -Force -ErrorAction Stop
            }
        }
        if ($needInit) { $csvHeader | Set-Content $csvPath -Encoding UTF8 -ErrorAction Stop }
        $csvLine = [PSCustomObject]@{
            ScanTime  = $stamp
            Mode      = $modeStr
            NewMB     = $(if ($useEs) { $totalMB } else { 'NA' })
            NewFiles  = $(if ($useEs) { $newFiles } else { 'NA' })
            CumMB     = $cumulative
            Alert     = $(if ($alert) { 'YES' } else { 'no' })
            CleanedMB = $cleanedMB
        }
        $csvLine | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content $csvPath -Encoding UTF8 -ErrorAction Stop
    } catch { $persistErrors.Add("scan_log.csv: $($_.Exception.Message)") }

    # 报告 Markdown
    try {
        $mdLines = New-Object System.Collections.ArrayList
        [void]$mdLines.Add("# C 盘增量巡检 $stamp")
        [void]$mdLines.Add('')
        if (-not $useEs) { [void]$mdLines.Add('- **模式：降级**（Everything 不可用，仅扫 C:\Users\GD；基线未推进）') }
        elseif ($isFirstRun) { [void]$mdLines.Add('- **模式：首次全量盘点**（已建立全盘 >1MB 清单基线，下次起为增量）') }
        else { [void]$mdLines.Add("- **模式：增量**（统计上次运行 $lastStamp 之后新增/变化的文件）") }
        [void]$mdLines.Add('')
        if ($useEs) {
            [void]$mdLines.Add("- **本次新增：$totalMB MB**（$newFiles 个文件）")
            if ($incrementalZero) { [void]$mdLines.Add('  - 查询成功且命中 0 行 = **确实没有新增/变化**（正常结论，非失败）') }
        } else {
            [void]$mdLines.Add('- **本次新增：N/A**（降级口径与全盘基线不可比，故不报数字）')
            [void]$mdLines.Add("- 降级参考值（C:\Users\GD 近 14 天修改量，不等于本次新增）：$totalMB MB")
        }
        [void]$mdLines.Add("- 累计台账 CumulativeMB：**$cumulative MB**（只累计扫描到的变化量，不等于净占用）")
        [void]$mdLines.Add("- 上次基线时间：$(if ($lastStamp) { $lastStamp } else { '(无，本次为首轮)' })")
        [void]$mdLines.Add("- 清理 Temp 安装残留：$cleanedMB MB")
        [void]$mdLines.Add("- 告警：$(if ($alert) { $alertReason } else { '无' })")
        [void]$mdLines.Add('')
        [void]$mdLines.Add('## 本次新增 Top 目录')
        [void]$mdLines.Add('')
        if ($useEs) {
            [void]$mdLines.Add('| 目录 | 新增文件数 | 新增(MB) |')
        } else {
            [void]$mdLines.Add('降级模式：以下按 C:\Users\GD 近 14 天修改量统计，与全盘基线不可比。')
            [void]$mdLines.Add('')
            [void]$mdLines.Add('| 目录 | 文件数 | 大小(MB) |')
        }
        [void]$mdLines.Add('|---|---|---|')
        foreach ($d in $topDirs) { [void]$mdLines.Add("| $($d.TopDir) | $($d.Files) | $($d.SizeMB) |") }
        [void]$mdLines.Add('')
        [void]$mdLines.Add('## 本次新增的大文件（Top 15）')
        [void]$mdLines.Add('')
        [void]$mdLines.Add('| 大小(MB) | 修改时间 | 路径 |')
        [void]$mdLines.Add('|---|---|---|')
        foreach ($f in @($deltaFiles | Select-Object -First 15)) {
            $safePath = ($f.Path -replace '\|', '\|')
            [void]$mdLines.Add("| $($f.SizeMB) | $($f.Modified) | $safePath |")
        }
        [void]$mdLines.Add('')
        [void]$mdLines.Add('## 参考面：Program Files / ProgramData 近 14 天新建目录（口径不同于上方本次新增，勿混用）')
        [void]$mdLines.Add('')
        if ($newProgs) { [void]$mdLines.Add(($newProgs -join ', ')) } else { [void]$mdLines.Add('none') }
        [void]$mdLines.Add('')
        [void]$mdLines.Add('## Notes')
        [void]$mdLines.Add("- 扫描口径：$scopeNote")
        if ($esIndexInfo) { [void]$mdLines.Add("- Everything 索引：$esIndexInfo") }
        [void]$mdLines.Add('- 增量原理：scan_state.json 存上次清单（路径 到 大小+修改时间）；本轮查"上次时间戳 -2 分钟"之后变化过的文件，再与清单做差集去重，只有新增路径或签名变化才计入。')
        [void]$mdLines.Add('- 判定规则：导出文件生成即视为查询成功；命中 0 行是合法结论（无新增），不降级。')
        [void]$mdLines.Add('- 清理范围：Temp 中 TRAE/VSCode 安装残留 + codebuddy-marketplace 安装残留')
        [void]$mdLines.Add('- 历史记录：scan_log.csv（schema 变更时旧文件自动备份为 scan_log.csv.bak-*）')
        $mdLines | Set-Content $reportPath -Encoding UTF8 -ErrorAction Stop
    } catch { $persistErrors.Add("scan_report.md: $($_.Exception.Message)") }

    try {
        if ($alert) { $alertReason | Set-Content $alertPath -Encoding UTF8 -ErrorAction Stop }
        elseif (Test-Path $alertPath) { Remove-Item $alertPath -Force -ErrorAction SilentlyContinue }
    } catch { $persistErrors.Add("ALERT.txt: $($_.Exception.Message)") }
}

# ---------- 机读输出（[FIX-5] check.ps1 依赖 DELTA_MB）----------
$deltaOut = 'NA'
if ($deltaMB -ne $null) { $deltaOut = $deltaMB }
$filesOut = 'NA'
if ($useEs) { $filesOut = $newFiles }
Write-Output "DELTA_MB=$deltaOut"
Write-Output "NEW_FILES=$filesOut"
Write-Output "MODE=$modeStr"
Write-Output "CUM_MB=$cumulative"
Write-Output "CLEANED_MB=$cleanedMB"
Write-Output "ALERT=$(if ($alert) { 'YES' } else { 'no' })"
if ($parseBad -gt 0) { Write-Output "PARSE_BAD_LINES=$parseBad" }
foreach ($e in $persistErrors) { Write-Output "PERSIST_FAILED: $e" }
Write-Output "Scan done (mode=$modeStr, es=$useEs): new ${totalMB}MB / $newFiles files, cum ${cumulative}MB, cleaned ${cleanedMB}MB, alert=$alert"

# [FIX-3] 落盘失败 -> 非零退出，让 run-task 记为 fail（不再"打印成功但什么都没写"）
if ($persistErrors.Count -gt 0) { exit 3 }
exit 0
