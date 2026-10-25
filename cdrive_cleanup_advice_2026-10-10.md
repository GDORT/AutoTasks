# C 盘新增占用归因 + 清理建议（2026-10-10 00:20）

> 配套：`cdrive_incremental_verify_2026-10-09.md`（增量验证）。本文件回答两件事：**新增的东西是怎么来的** + **能清多少、怎么清**。
> 所有数字为实测（robocopy 全盘枚举 + 注册表 + 事件日志 + 目录实测）。当前 **C: 128.0 GB，已用 127.05 GB，剩余 0.94 GB**。

## 一、pagefile.sys：10,474.6 MB（本次净增最大单项，+4,319 MB）

### 现状与原因

| 项 | 值 |
|---|---|
| 注册表 `PagingFiles` | `?:\pagefile.sys`（**带 `?` = 由 Windows 自动管理大小/位置**） |
| 实际文件 | `C:\pagefile.sys` = **10,474.6 MB**，`C:\swapfile.sys` = 272 MB |
| 当前使用率 | **37.6%**（活跃在用，不是空占） |
| 崩溃转储配置 | `CrashDumpEnabled=3`（小内存转储）、`AutoReboot=1`、`MinidumpDir=C:\Windows\Minidumps` |
| 现存 minidump | **无**（9 月 29 日那次 41 事件没有留下转储） |

**为什么会长大**：系统托管页文件会按"提交量（commit charge）压力"自动扩张——看当前已用 37.6%，说明这台机器（游戏 + VM/模拟器 + 浏览器 + 百度网盘/QQ 常驻）的提交量确实需要这个体量。它**不会自动缩回去**，Windows 托管只在重启后按需重新计算，所以下次重启有可能缩到 6~8 GB。

**不是崩溃撑大的**：`Microsoft-Windows-Resource-Exhaustion-Detector` 日志里只有常规的 start/stop（1001/1002），**没有任何"资源耗尽"告警**；`C:\Windows\Minidump` 为空。→ 属于正常增长，不是故障征兆。

### 建议（唯一一条能立刻拿回两位数 GB 的）

| 优先级 | 做法 | 立即可回收 | 说明 |
|---|---|---|---|
| ★★★ | **把页文件整体挪到 D:** | **10.47 GB** | D: 剩余 **424.5 GB**（803 GB 容量），放 10 GB 页文件毫无压力；本机是本地盘，不是慢速存储，无需顾虑速度 |
| ★★ | 或：C: 固定小页文件（如 4~6 GB）+ D: 再放一份 | ≈ 4.5~6.5 GB | 保留 C: 小页文件是为了支持"小内存转储"；代价是 C: 仍占 4~6 GB |
| ★ | 直接重启一次 | 不确定（可能 2~4 GB） | 系统托管页文件重启后按新压力重算；**零风险但收益不确定** |

⚠️ 不要设成"无页文件"：128 GB 内存压力场景下会导致部分游戏/模拟器崩溃，且会丢失蓝屏转储能力。**移动，不要删除。**

## 二、安装包 / 缓存的新增原因

近几天新增的是这几类，都有明确"来源"：

| 来源 | 体量 | 机制 |
|---|---|---|
| **Microsoft Edge / WebView2 更新** | Edge `Application` 现存 **154.0.4258.53 + 154.0.4258.62 两份，各 872.5 MB**；`EdgeCore` 2,100.9 MB、`EdgeWebView` 1,723.3 MB、`Edge` 1,772.7 MB | Edge 每次更新保留新旧两版做回滚，稳定后才清旧版。→ C: 上 Edge 全家桶约 **6.5 GB** |
| **百度网盘**（程序 + 自动更新包） | 程序 967 MB（`AppData\Roaming\baidu\BaiduNetdisk`），**整个 baidu 目录实测 1,797.6 MB**；本次还出现新 cab **746.5 MB** + 旧 cab 636.4 MB 同时存在 | 自动更新把完整安装包下载到 `AutoUpdate\Download\MainApp\fullpackage_*.cab`，装完**不删旧包** |
| **NVIDIA 驱动/组件缓存** | 本次清掉了 756.6 MB 的 `617.14-...-whql-g.exe`（好）；`Installer2\Display.PhysX.{74B1EBBF...}` 仍留 **201.3 MB** | 驱动安装残留 |
| **游戏 shader 预编译缓存** | `ProgramData\D3DGraphics_V4318_D10115_S415897457_R161.ushaderprecache` **760.0 MB**（霍格沃茨之遗） | 首启动预编译着色器，**删了下次进游戏自动重建** |
| **各类下载安装包** | `Downloads` 2,313.6 MB（象棋软件.rar 279.1、QuarkCloudDrive 124.7、Flow-Launcher 97.1、Notion 96.5、app-Windows-arm.asar 80.1、sikulixide 77.3、TokenTracker 77.1、两个 BD2 钓鱼脚本 114.6、Git 61.6、两份 windowsdesktop-runtime 111、tsetup 51.6…） | 装完没删 |
| **Playnite / 系统 Temp 残留** | `Local\Temp\Playnite\update.exe` 144 MB、`Windows\Temp\wct8DC6.tmp` 140.2 MB、`Windows\Temp\tmp4D4E.tmp` 134.7 MB | 更新器/安装器临时文件 |
| **Windows 更新残留** | `Windows\Installer` 2,273.4 MB / 205 个 msi、`SoftwareDistribution\Download` 53.2 MB | 系统更新与 MSI 缓存 |

## 三、清理建议

### 第一梯队：高价值 + 低风险（**≈ 4.4 GB**，可直接做）

| # | 目标（完整路径） | 可回收 | 风险与依据 |
|---|---|---|---|
| 1 | `C:\ProgramData\D3DGraphics_V4318_D10115_S415897457_R161.ushaderprecache` | **760 MB** | 低：着色器缓存，游戏自动重建（首次进游戏略卡） |
| 2 | `C:\Users\GD\AppData\Local\Temp\`（如 `Playnite\update.exe` 144 MB） | **≈ 580 MB** | 低：临时目录。建议只删 7 天前的项，别删正在写入的 |
| 3 | `C:\Windows\Temp\*` | **≈ 320 MB** | 低：`wct8DC6.tmp`、`tmp4D4E.tmp` 等安装器残留 |
| 4 | `C:\Windows\SoftwareDistribution\Download\*` | **≈ 53 MB** | 低：Windows 更新缓存（先停 wuauserv 更稳） |
| 5 | `C:\$Recycle.Bin` | **187.7 MB** | 低：回收站（161 个旧文件） |
| 6 | `C:\WRP5BFA.tmp` + `C:\$WinREAgent\` | ≈ 1 MB | 低：更新回滚残留（2026-08 / 2026-03） |
| 7 | `C:\ProgramData\NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts\` | 已清（本次已验证删除） | — |
| 8 | 浏览器缓存：`C:\Users\GD\AppData\Local\Microsoft\Edge\User Data\Default\Cache` | **251 MB** | 低：浏览器自建 |

> 小计：**≈ 2.15 GB**（不含第 7 项的已清部分）。加上"删除旧 Edge 版本"见第二梯队。

### 第二梯队：需要一点点判断（**≈ 1.7~2.5 GB**）

| # | 目标 | 可回收 | 说明 |
|---|---|---|---|
| 9 | `C:\Users\GD\AppData\Roaming\baidu\`（缓存 + `AutoUpdate\Download\*` 的 cab 包） | **≈ 1.0~1.8 GB** | 中低：**优先用百度网盘自带"清理缓存"**；只删 `AutoUpdate\Download` 下的 `fullpackage_*.cab` 与 `Cache` 也安全，别删 `module\`、`netdisk-*.dll` |
| 10 | `C:\Program Files (x86)\Microsoft\Edge\Application\154.0.4258.53`（旧版） | **≈ 872 MB** | 中：Edge 已升到 `154.0.4258.62`。**先确认 Edge 能正常启动**，再删旧版本号目录；更稳的做法是等 Edge 自己清理（约 10 天） |
| 11 | `C:\Program Files (x86)\Microsoft\EdgeCore\Optimized` 等旧版本目录 | 需逐项确认 | 中：同 Edge 多版本机制，删前确认当前版本 |
| 12 | `C:\Users\GD\Downloads\` 里明确不再需要的安装包（`象棋软件.rar` 279 MB、`QuarkCloudDrive_v3.23.2*.exe` 124.7 MB、`Flow-Launcher-Setup.exe` 97.1 MB、`Notion Setup 7.20.0.exe` 96.5 MB、`app-Windows-arm.asar` 80.1 MB、`sikulixide-2.0.5-win.jar` 77.3 MB、`TokenTracker-Setup.exe` 77.1 MB、`BD2_auto_fishing v4.1/v4.2` 114.6 MB、`Git-2.53.0-64-bit.exe` 61.6 MB、两份 `windowsdesktop-runtime-*.exe` 111 MB、`tsetup-x64.7.0.5.exe` 51.6 MB、两份 `UsbEAm_Hosts_Editor_*.zip` 83.1 MB） | **≈ 1.2 GB** | 低-中：都是能重新下载的安装包，删前确认对应软件已装好 |
| 13 | `C:\Program Files\NVIDIA Corporation\Installer2\Display.PhysX.{74B1EBBF-...}` | 201 MB | 中低：NVIDIA 安装残留 |
| 14 | `C:\Users\GD\AppData\Local\pip\cache` | 215 MB | 低：pip 缓存，可 `pip cache purge` |
| 15 | `C:\Users\GD\AppData\Roaming\Tencent\`（QQ/微信/会议缓存） | 927 MB（部分） | 中：优先在各 App 内清缓存，别整目录删 |

### 第三梯队：结构性回收（**10.5 GB+**）

| # | 做法 | 可回收 | 说明 |
|---|---|---|---|
| 16 | **页文件移到 D:**（见第一节） | **10.47 GB** | ★ 最推荐，一次手术解决主要矛盾 |
| 17 | 卸载不用的软件：`C:\Program Files\Tencent\WeMeet` 838 MB、`C:\Program Files\WSL\system.vhd` 723 MB（未装发行版）、`C:\Program Files (x86)\Epic Online Services` 1,083 MB（若不用 Epic）、`C:\Users\GD\AppData\Local\WeMod` 169 MB | **1.5~2.8 GB** | 低：走"应用和功能"卸载，别手删目录 |
| 18 | `dism /Online /Cleanup-Image /StartComponentCleanup` | 1~3 GB（不确定） | **中高**：WinSxS 现 10.15 GB。代价是**以后无法卸载已装更新**；先 `/AnalyzeComponentStore` 看建议 |
| 19 | 把用户大目录迁 D:（junction）：`AppData\Local`（39.5 GB）、`Documents`（12.5 GB 含戴森球存档 ≈12 GB）、`Downloads`（2.3 GB） | 20 GB+ | 中：长期正解，但要逐个迁移 + 建 junction，建议一次做一个并验证 |

### 不要做

- ❌ **手动删 `C:\Windows\Installer\*.msi`**（2.27 GB）：会导致 Office/NVIDIA 等**无法修复、无法卸载、更新失败**。要用专门的 PatchCleaner 类工具判断孤立 MSI。
- ❌ **手动删 `C:\Windows\WinSxS`** 或 `DriverStore\FileRepository\*.inf_*` 旧驱动（3.7 GB）：会直接搞坏系统。
- ❌ 删 `Windows\System32\vulkaninfo.exe`、`.vscode\extensions` 等看似冗余实则在用的东西。
- ❌ 关掉页文件（见第一节）。
- ❌ 用"磁盘清理"顺手勾了 `Windows.edb`（搜索索引）——它已经在本轮之前被系统清掉了，删它只是丢搜索历史，但**别再主动删**。

## 四、一句话总结

- **新增主因**：① 页文件 +4.3 GB（自动托管，正常增长）；② Edge/WebView2 多版本更新 ≈6.5 GB 存量；③ 百度网盘自动更新包 ≈1.8 GB；④ 游戏 shader 缓存 760 MB；⑤ 下载的安装包 ≈2.3 GB 没清。
- **最划算的动作**：**页文件搬到 D:（+10.47 GB）**，然后清 shader 缓存 + 各类 Temp（+2.2 GB），再谈 Edge 旧版和 Downloads（+2 GB）。
- **不动手术的前提下**，第一、二梯队合计可安全回收 **≈ 4~7 GB**；连页文件一起做，可回收 **≈ 15 GB**，把 C: 剩余从 0.94 GB 抬到 16 GB 左右，脱离危险区。
