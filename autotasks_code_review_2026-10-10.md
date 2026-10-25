# AutoTasks 脚本与说明的缺陷评审（2026-10-10）

> 方法：逐个脚本对照 `task-registry.json` 的声明、以及各脚本之间的**接口契约**（谁输出什么、谁读什么）。
> 结论：**有 4 处会出错或已经失效的硬 bug、5 处设计缺陷、3 处文档与实现不一致**。按"会不会真的坏事"排序，前 4 条建议尽快修。

## 修复状态（2026-10-10 已全部修复并验证）

| 编号 | 问题 | 状态 | 验证方式 |
|---|---|---|---|
| A1 | 3GB 告警正则失配，永不触发 | ✅ 已修 | `check.ps1` 改读 `DELTA_MB=`；实测 `CHECK_DELTA_MB=0`，落盘失败时 `CHECK_ALERT=True` |
| A2 | 计划任务触发器与 registry 矛盾 | ✅ 已修 | `register_scheduler.ps1` 改为每月 1/15（CIM `DaysOfMonth`，失败回退 `schtasks /SC MONTHLY /D 1,15`） |
| A3 | `$LASTEXITCODE` 不覆盖 .ps1，掩盖失败 | ✅ 已修 | 先清空再判断是否被赋值；原生 exit=7 测试通过；另加 `PERSIST_FAILED` 兜底 |
| A4 | `scan_log.csv` 表头与 schema 不一致 | ✅ 已修 | 表头校验 + 不匹配即备份为 `scan_log.csv.bak-<时间戳>` 并重建 |
| B1 | "0 行"被当成"查询失败" | ✅ 已修 | 改为"导出文件存在即成功"；实测 0 文件时输出 `DELTA_MB=0 MODE=incremental`（不再降级） |
| B2 | 状态时间戳只到分钟，同分钟改动会漏 | ✅ 已修 | 秒级 `LastStamp` + 查询回退 2 分钟，差集去重 |
| B3 | `CumulativeMB` 只加不减 | ✅ 已修（语义澄清） | 报告/描述明确标注"只累计扫描到的变化量，不等于净占用" |
| B4 | 落盘失败静默，状态不推进 | ✅ 已修 | 失败打印 `PERSIST_FAILED` 并 `exit 3`；实测沙箱内正确报 4 个文件落盘失败 |
| B5 | 降级数字与基线并列展示 | ✅ 已修 | 降级时"本次新增"写 `N/A`，降级参考值单独标注 |
| C1 | 文档写 60s 超时、代码是 180s | ✅ 已修 | `task-registry.json` 描述改为 180s，并同步口径说明 |
| C2 | `chore-scan.ps1` python 回退无空值保护 | ✅ 已修 | 加入空值/PATH 兜底与明确报错；实测回退成功 |
| C3 | 注释未说明"双触发是设计" | ✅ 已修 | `register_scheduler.ps1` 头注重写 |

**另外新增修复 2 处（本轮新发现，见 F 节）：**

| 编号 | 问题 | 状态 | 验证方式 |
|---|---|---|---|
| F1 | **脚本以 UTF-8 无 BOM 存盘时，Windows PowerShell 5.1 按 ANSI(CP936) 解码，含全角问号 U+FF1F 等字符会吃掉引号导致直接解析失败** | ✅ 已修 | 全仓 11 个 `.ps1` 统一 UTF-8 带 BOM；正文规避该类全角标点；`ParseFile` 全绿、5.1 实跑通过 |
| F2 | 增量轮若"有变化文件但 >1MB 清单为空"（索引陈旧），会把漏报当成"无新增" | ✅ 已修 | `scan.ps1` 判为失败并保留基线（FIX-9） |

> 验证基线：`parsefile errors=0`（全部脚本）、`scan.ps1 -DryRun` 在 PowerShell 5.1 下输出
> `DELTA_MB=0 / NEW_FILES=0 / MODE=incremental / ALERT=no`（exit 0）。
> 注意：本轮修复全部落在磁盘上，但**在本会话内无法把结果写回 `AutoCDriveMonitor`**（沙箱只放开工作区根目录的写权限，
> 子目录写入被拒）。计划任务按原上下文运行不受影响；如需在本会话内直接跑并落盘，请把会话切到完全权限(full access)。

## A. 硬 bug（已失效或会导致执行错误）

### A1 ★ 3GB 阈值告警已经完全失效 —— `AutoCDriveMonitor/check.ps1:10-13`

```powershell
$scanOut = & "$base\scan.ps1" 2>&1 | Out-String
$deltaMatch = [regex]::Match($scanOut, 'delta ([-\d.]+)MB')
if ($deltaMatch.Success) { $deltaMB = [double]$deltaMatch.Groups[1].Value }
$over3G = ($deltaMB -gt 3072)
```

`scan.ps1` 最后一行打印的是：

```
Scan done (mode=..., es=...): new 838.8MB / 0 files, cum ..., cleaned ..., alert=...
```

里面**根本没有 `delta <数字>MB` 这个片段**。→ 正则永远不匹配 → `$deltaMB` 恒为 `0.0` → `$over3G` 恒 `$false` → **增量超 3GB 的告警永远不会触发，`ALERT.txt` 永远不会生成**。这个"可靠性兜底"实际上是死的。

**修法**（任一）：让 `scan.ps1` 输出一个稳定的机读标记（如最后单独打印一行 `DELTA_MB=123.4`）再解析；或直接把阈值判断放进 `scan.ps1`（它本来就已经算出 `$deltaMB` 并在内部做了 3072 判断，见 `scan.ps1:338-344`）——`check.ps1` 只负责弹窗。

### A2 ★ 计划任务是「每月 1/15」还是「每天 09:00」——两处声明互相矛盾

| 来源 | 声明 |
|---|---|
| `task-registry.json:29` | `"rrule": "FREQ=MONTHLY;BYMONTHDAY=1,15;BYHOUR=9"` |
| `register_scheduler.ps1:62` | `New-ScheduledTaskTrigger -Daily -At $t.At` ← 用 **Daily**，`$PLAN` 里 cdrive-monthly 的 `At='09:00'` |

→ 若按 `register_scheduler.ps1` 注册，任务**每天 09:00** 都触发（比设计多约 13 次/月）。虽然 `run-task` 的 `period=daily` 去重会把它压成"每天最多一次"，但**任务意图与实现不一致**，且 1/15 弹窗语义依赖 `check.ps1` 里的日期判断（`scan.ps1` 侧无月内判断）。

> 旁证：本会话查不到已注册任务（`Get-ScheduledTask` 需提权、`schtasks` 在沙箱内被拒），但 `task-run.log` 里有 `2026-10-09 23:00:39` 这种**与 09:00 不符**的执行时刻，说明除本地计划任务外还有别的触发源（自动化/手工）。即"到底注册成什么"需要在有权限的会话里 `Get-ScheduledTask AutoTasks.cdrive-monthly | fl` 确认，本文件只指出两处声明自相矛盾。

**修法**：触发器改成 `New-ScheduledTaskTrigger -Weekly`/或注册后手工把触发器改成每月 1、15 日；或明确把设计改为"每天跑"并同步改 `task-registry.json` 的 rrule 与描述。

### A3 `run-task.ps1` 的退出码判定覆盖了去重/状态写入逻辑 —— `run-task.ps1:251`

```powershell
$outBuf = & $t.command 2>&1
$exitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } else { 0 }
```

`&` 调用 **PowerShell 脚本（.ps1）** 时不会设置 `$LASTEXITCODE`（那是给原生 exe 用的）；此时它保留的是**上一次原生命令**的退出码。后果：一个实际抛错/内部失败的 .ps1 任务（例如 `scan.ps1` 落盘失败）可能因为 `$LASTEXITCODE` 恰好是 0 而**被记成 OK**，掩盖真实失败。

**修法**：令被调用脚本显式 `exit 0/1`（`scan.ps1` 目前**没有 `exit`**），或用 `try { & $cmd; $exitCode = 0 } catch { $exitCode = 1 }`，优先以异常为准。

### A4 日志 CSV 已被写成两种表头、字段数不一致 —— `scan.ps1:350-363`

当前 `scan_log.csv` 的**表头**是旧契约：

```
ScanTime,TotalMB,DeltaMB,Alert,CleanedMB      ← 5 列
```

而 `scan.ps1` 现在每轮追加的是 **7 列**（`ScanTime,Mode,NewMB,NewFiles,CumMB,Alert,CleanedMB`），且历史里还混入过 9 列/11 列的行（`2026-10-09 22:40:40` 起可见）。因为代码只在"文件不存在"时写一次表头：

```powershell
if (-not (Test-Path $csvPath)) { "ScanTime,Mode,..." | Set-Content $csvPath }
```

→ 表头永远不会随 schema 更新。**任何按列名/列位置解析这个 CSV 的下游（人、脚本、Excel、AI）都会读错列**（例如把 `Mode` 当 `TotalMB`）。

**修法**：检测表头是否匹配当前 schema，不匹配就迁移/重写（或换 `scan_log_v2.csv`）。现在正是好时机：重写表头 + 把混入的坏行归到一个 `.bak`。

## B. 设计缺陷（不会立刻炸，但会在特定条件下给错答案）

### B1 ★ Everything 索引不新鲜时，"没有新增"和"查询失败"分不清

- `es.exe` 的数据来自 `Everything.db`（90 MB），**只有 Everything 在跑时才会更新**；实测 `Everything` 服务是 `Stopped`（StartType=Automatic 但未启动），`Everything.exe` 进程也不在。
- `scan.ps1` 用 `if ([string]::IsNullOrWhiteSpace($dirLines)) { $useEs = $false }` 判定失败，而 `Invoke-EsExport`（`scan.ps1:143-175`）把"**命中 0 行**"也返回成空串 → **合法结论"无新增"被误判为"查询失败"**，于是降级、报陈旧值、基线不推进。
- 反过来更危险：如果索引是**三天前**的快照，查询照样能返回数据，却会**静默漏掉这三天的新增**——因为 `dm:>` 是拿索引里的时间戳过滤的。

**修法**：① 失败判定改成"CSV 文件是否存在"（文件存在但 0 行 = 无新增）；② 给 Everything 配成**开机自启的服务**（或每次 `Start-Service Everything`）；③ 在报告里打印索引的最后更新时间，便于发现陈旧。

### B2 状态清单只到"分钟"，同一分钟内的改动会永久漏掉 —— `scan.ps1:186,258`

```powershell
$sinceQ = ([datetime]$lastStamp).ToString('yyyy/MM/dd HH:mm')
```

`LastStamp` 精度是分钟，但 Everything 的 `dm:` 在**分钟级**比较，下一轮用 `dm:>23:00` 时，**23:00:00~23:00:59 之间被修改的文件会被判定为"不晚于 23:00"而永久跳过**（除非它以后再被改一次且大小/时间签名变化）。

**修法**：状态里存秒级时间戳，查询时向前留 1~2 分钟余量（`dm:>上次时间-2分钟`），靠 `scan_state.json` 的签名差集去掉重复计数——差集本来就能去重，宁可重复查询也别漏。

### B3 台账只累加、从不扣减，删除释放的空间永远不体现 —— `scan.ps1:329-334`

```powershell
if ($isFirstRun) { $cumulative = $totalMB } else { $cumulative = $cumulative + $totalMB }
```

`CumulativeMB` 只加不减：**删掉的东西（本轮实测删了 ≥3.2 GB 旧包/缓存）不会从台账里扣除**，于是"累计新增"会单调增长、与实际剩余空间趋势背离，越用越误导。

**修法**：改名为"累计扫描到的变化量"并明确它≠净占用；或改为维护"当前 >1MB 占用总量"（这个才有可比性）。

### B4 `state` 写不进去 → 状态不推进 → 下一轮重复报同一窗口

`scan.ps1` 把 `scan_state.json`/`baseline.json` 的写入包在 `try{}catch{}` 里且 `$ErrorActionPreference='SilentlyContinue'`；本轮实测就发生了"打印 `Scan done` 但四个文件一个都没写"（目录写权限被拒，见增量报告第三节）。此时状态停在旧时间戳，下一轮会用**同一个旧窗口**重算，输出看起来"正常"，实则重复。

**修法**：落盘失败必须"响"——至少在 stdout 打印一行 `PERSIST_FAILED` 并以非零退出，让 `run-task` 记 fail。

### B5 降级模式报出的数字与基线不可比，却直接并列展示 —— `scan.ps1:267-292, 374-376`

降级分支统计的是"`C:\Users\GD` 里近 14 天修改的文件总量"（本轮 838.8 MB），报告里却和"全盘 >1MB 台账 117,441.7 MB"写在同一屏，只靠脚注一句"不可信"。实际已经连续两轮让读者误以为"本次新增 838.5 MB"。

**修法**：降级时"本次新增"栏直接写 `N/A（降级：仅扫 C:\Users\GD，与全盘基线不可比）`。

## C. 文档 / 描述与实现不一致

| # | 位置 | 声明 | 实现 |
|---|---|---|---|
| C1 | `task-registry.json:28` | "es 缺失/**60s 超时**则降级" | `scan.ps1:198` 实际用 **180000ms=180s** |
| C2 | `chore-scan.ps1:29-32` | 注释说 `$cfg.python` 失效时回退到 `C:\Users\GD\.workbuddy\binaries\python\versions\*\python.exe` | 该 glob 无 `-ErrorAction SilentlyContinue` 也无空值判断，路径不存在时 `$Py` 变 `$null`，后续 `& $Py` 报错难定位；`config.local.json` 当前 3.13.12 存在，暂未触发 |
| C3 | `register_scheduler.ps1:6-10` | 注释称沙箱自动化触发时 cdrive-monthly"**必然降级**" | 沙箱内确实降级，但 `register_scheduler` 同时保留自动化入口，**双触发**依赖 `run-task` 文件锁去重（`run-task.ps1:96-119`）才不重复跑——这套机制本身是对的，但注释没写清"双触发是设计而非兜底" |

## D. 确认**没有**问题的部分（避免误改）

- `AutoCheckin\checkin_all.ps1:30,40` 对子脚本用 `& powershell.exe -File`，是**原生进程**，`$LASTEXITCODE` 有效 → 这里的失败判定是对的（与 A3 不同）。
- `AutoCheckin\WorkBuddy\workbuddy_checkin.ps1:41-48` 的"当天已成功才跳过"三条件判断（日期 + `[WorkBuddy]` + `[OK]`）已修好，逻辑正确。
- `load-config.ps1` 用 `$PSScriptRoot` 定位 `config.local.json` 正确（不是 `$MyInvocation`）；`config.local.json` 就在脚本同目录。
- `run-task.ps1:64-94` 的代理环境变量大小写冲突处理、以及 `96-119` 的文件锁，都能解决真实问题。
- `AutoAppTriggers\launcher.ps1` 与 `app-registry.json` 契约一致（`app-registry.json` 里 TRAE 的 `hooks` 为空，故当前无实际行为）。

## E. 建议的修复顺序

1. **A1**（告警失效）—— 可靠性兜底现在等于没有。
2. **A2**（触发器矛盾）—— 决定到底是"每 1/15"还是"每天"，两处改一致。
3. **B1**（0 行 vs 失败）—— 不改的话，这个任务会长期停在"降级 + 报 838.5MB"。
4. **A4**（CSV 表头）—— 趁现在就把表头换对，越晚越难迁移。
5. **A3 / B2 / B3 / B4 / B5** —— 按需。
6. **C1~C3** —— 改注释即可，顺手做。
