# C 盘「新增」空间占用分析 · 2026-10-06（修正版，全路径）

> 修正上一轮结论：上一轮 TOP30 按「文件绝对大小」排序，把老游戏存档顶到最前，误导为「都是老文件」。
> 本轮按「最近14天新建/修改」扫描，且把系统区（Program Files / ProgramData / Windows）纳入——正是 cdrive-monthly 漏掉的部分。
> 所有路径均为完整绝对路径。数据来源：`_cdisk_new2.ps1` → `_cdisk_new2_report.txt`。

## 一、关键数字
- 近14天（LastWriteTime > 2026-09-22），扫描根（系统区+用户目录）被改动文件：**18,750 个，合计 10,843.1 MB（≈10.8 GB）**。
- 其中「14天内新建的目录」粗算净增 **≈12 GB**（未扣可能替换掉的旧版本）。
- cdrive-monthly 只扫 `C:\Users\GD`，故只看到 1.1GB；系统区这 ~10GB 全被漏掉。

## 二、各根目录近14天改动量
| 根目录 | 改动文件数 | 大小(MB) |
|---|---|---|
| `C:\ProgramData` | 1,446 | 1,791.9 |
| `C:\Program Files` | 3,927 | 1,533.5 |
| `C:\Program Files (x86)` | 4,376 | 5,313.2 |
| `C:\Windows\SoftwareDistribution` | 14 | 48.5 |
| `C:\Windows\Installer` | 5 | 1,014.7 |
| `C:\Windows\Temp` | 109 | 27.3 |
| `C:\Users\GD` | 8,873 | 1,114.1 |

## 三、新增大头（按 14天新建目录体量，父/子已去重）
| 项目 | 新增体量 | 完整路径 | 性质 | 可清理 |
|---|---|---|---|---|
| NVIDIA 驱动更新缓存 | ~3.8 GB | `C:\ProgramData\NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts\grd\post-processing\dc5ffd3eee1002c4977b00b0f6ffd21c` | NVIDIA App 下载的驱动包 617.14 缓存（含 `Display.Driver` 2.7GB + `.exe` 756MB） | 安全清（纯缓存） |
| WSL | 1.17 GB | `C:\Program Files\WSL` | WSL 功能安装（14天内新建；未见 vhdx，发行版未装） | 不用就卸载 |
| Microsoft Edge 154.0.4258.53 + EdgeWebView + EdgeCore（多版本） | ~4.7 GB（含旧版残留，净增更小） | `C:\Program Files (x86)\Microsoft\Edge\Application\154.0.4258.53` / `C:\Program Files (x86)\Microsoft\EdgeWebView\Application\154.0.4258.53` / `C:\Program Files (x86)\Microsoft\EdgeCore\Optimized` | 浏览器更新 | 一般留当前版 |
| Tencent WeMeet 3.46.11.413 | 835 MB | `C:\Program Files\Tencent\WeMeet\3.46.11.413` | 腾讯会议更新 | 不用可卸 |
| OneDrive 26.168.0830.0006 | 528 MB | `C:\Program Files\Microsoft OneDrive\26.168.0830.0006` | 更新 | 留 |
| Google Chrome 154.0.8037.97 | 496 MB | `C:\Program Files\Google\Chrome\Application\154.0.8037.97` | 更新 | 留 |
| GOG Galaxy | 364 MB | `C:\ProgramData\GOG.com\Galaxy` | 新装 | 不用可卸 |
| NVIDIA App CEF | 381 MB | `C:\Program Files\NVIDIA Corporation\NVIDIA App\CEF` | NVIDIA App 组件 | 随 App |
| .dsh | 277 MB | `C:\Users\GD\.dsh` | AI 运行时 | 留 |

## 四、14天修改 TOP 文件（节选，完整绝对路径，验证来源）
| 大小(MB) | 完整路径 | 修改时间 |
|---|---|---|
| 756.6 | `C:\ProgramData\NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts\grd\dc5ffd3eee1002c4977b00b0f6ffd21c\617.14-desktop-win10-win11-64bit-international-dch-whql-g.exe` | 2026-09-29 21:18 |
| 741.7 | `C:\ProgramData\Locktime\NetLimiter\4\Stats\nlstatsV4.db` | 2026-10-06 17:50（持续增长） |
| 663.9 | `C:\Windows\Installer\c9eaf.msi` | 2026-09-30 02:18 |
| 350.6 | `C:\Windows\Installer\2e26fa.msi` | 2026-09-30 17:03 |
| 495.3 | `C:\Program Files (x86)\Google\GoogleUpdater\crx_cache\cf945853449ae0ca37c47cb22d795810e615fede1bd5671cedd04e3bcfdb2f6a` | 2026-10-02 23:08 |
| 333.7 ×多份 | `C:\Program Files (x86)\Microsoft\Edge\Application\154.0.4258.53\msedge.dll` 等 | 2026-10-01 / 09-29 |
| 288.4 | `C:\Program Files\Google\Chrome\Application\154.0.8037.97\chrome.dll` | 2026-10-01 10:16 |
| 279.1 | `C:\Users\GD\Downloads\象棋软件.rar` | 2026-09-30 14:48 |
| 246.2 | `C:\Users\GD\Downloads\DLSS5-Swapper-2.2.9-portable.exe` | 2026-10-05 22:49 |

## 五、结论与建议
1. 用户判断正确：近期空间下降主因是**批量更新/安装的新增**，不是老文件。
2. 最大单块可回收：**NVIDIA ota-artifacts 缓存 ~3.8GB**（完整路径：`C:\ProgramData\NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts\`），纯更新残留，删不影响已装驱动，最安全。
3. 若不用：WSL(`C:\Program Files\WSL`,1.17GB) / 腾讯会议(`C:\Program Files\Tencent\WeMeet`,835MB) / GOG Galaxy(`C:\ProgramData\GOG.com`,364MB) 可卸载回收。
4. 长期：C 盘仅 131GB，靠删治标；根本性做法仍是把大目录迁 D 盘（junction）。

## 六、扫描方法说明
- 本轮用 `Get-ChildItem -Recurse` + `LastWriteTime > (now-14d)` 过滤，覆盖 `C:\ProgramData` / `C:\Program Files` / `C:\Program Files (x86)` / `C:\Windows\SoftwareDistribution` / `C:\Windows\Installer` / `C:\Windows\Temp` / `C:\Users\GD`。
- 未做全 `C:\` 递归（含整个 `C:\Windows`）因枚举量过大被系统 kill；系统新增集中在上述根，已覆盖。
- 全量绝对大小盘点见 `cdisk_findings_2026-10-06.md`。
