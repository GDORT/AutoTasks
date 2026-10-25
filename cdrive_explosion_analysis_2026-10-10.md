# C 盘「爆炸」归因：近 45 天到底发生了什么（2026-10-10）

> 口径：本文件所有数字来自**两次独立全盘枚举**（`robocopy /L` 全盘，451,635 个文件）+ 全量台账 `scan_state.json`（12,421 个 >1MB 文件）交叉统计。
> 结论先行：**不是某一天"突然"爆炸，而是 2026-09-10 之后一连串"更新 + AI 运行时 + 缓存"持续堆积**；近 45 天有 **51.16 GB** 的 >1MB 文件被新增或改写（占整盘 117 GB 的 **44%**）。

---

## 一、时间线：爆炸是从 9 月中旬开始的

| 时间 | 事件（实测证据） | 体量 |
|---|---|---|
| 2026-09-10 | 一批基础组件集中更新：`MRT.exe`、VS Code 的 codex/claude 扩展、`Windows\System32` 大量文件被改写 | 数 GB |
| 2026-09-19 03:17 | 累积更新安装**一次性往 `Windows\System32` 落了 285 个文件**（含一批按需功能 FoD：Notepad/WordPad/Paint/ISE/StepsRecorder 等） | 3.77 GB |
| 2026-09-25 | **Claude Code 虚拟机被创建**：`claudevm.bundle`（rootfs.vhdx 8.37 GB + sessiondata.vhdx 0.63 GB） | **9.20 GB** |
| 2026-09-29~30 | NVIDIA 驱动 617.14 整包下载（756.6 MB）+ Edge/Chrome/GoogleUpdater 新版本 + WSL 3.0.1.0 安装包（350.6 MB） | ~3 GB |
| 2026-10-01~04 | Edge `154.0.4258.53` → `154.0.4258.62` 双版本并存；Chrome 更新；Windows 累积更新 | ~4 GB |
| 2026-10-06 17:43 | 全量盘点：**已用 127,328.4 MB，剩余仅 3,744.6 MB** | — |
| 2026-10-07~09 | NVIDIA DXCache 又写 4×256 MB；`NetLimiter` 统计库持续膨胀；`pagefile.sys` 涨到 10.47 GB | ~2 GB |
| 2026-10-09 23:00 | 全量台账复核：`C:\` >1MB = 12,421 个 / 117,441.7 MB；**剩余 0.93 GB** | — |

> 关键判断：10-06 那天就已经只剩 3.7 GB 了，说明**"爆炸"发生在 10-06 之前**；10-06 之后只是把最后 2.8 GB 也吃掉了。

## 二、按"近 45 天被改写的 >1MB 文件"拆账（合计 51.16 GB / 3,664 个文件）

| 排序 | 位置 | 体量 | 性质 |
|---|---|---|---|
| 1 | `C:\Users\GD\AppData` | **20.16 GB** | ↓ 见第三节，最大头 |
| 2 | `C:\pagefile.sys` + `swapfile.sys` | **6.28 GB** | 系统托管页文件随提交量膨胀（10-06 时 6.16 GB → 现在 10.47 GB） |
| 3 | `C:\Windows\System32` | **3.77 GB** | 9-19 累积更新 + FoD |
| 4 | `C:\ProgramData\NVIDIA Corporation` | **2.74 GB** | NVIDIA App 驱动下载缓存（617.14 整包 756.6 MB 等） |
| 5 | `C:\Program Files\WindowsApps` | **2.57 GB** | 商店应用更新（OneDrive/Claude/PC Manager/WindowsAppRuntime…） |
| 6 | `C:\ProgramData\Microsoft` | **2.05 GB** | 含 `Search\...\Windows.edb` 1.26 GB（已于 10-09 被系统清掉） |
| 7 | `C:\Program Files\Microsoft Office` | **1.81 GB** | Office 更新（含 `vfs\...\AI\lmgpu*.dll` 34 MB×3 等） |
| 8 | `C:\Users\GD\Documents` | **1.45 GB** | 含戴森球存档 `DS-8.dsv` 781 MB |
| 9 | `C:\Users\GD\.vscode` | **1.20 GB** | 扩展（codex/claude 二进制各 200~280 MB） |
| 10 | `C:\Users\GD\Downloads` | **0.91 GB** | 下载的安装包 |
| 11 | `C:\Program Files\Tencent` | **0.91 GB** | 腾讯会议 3.46.11.413 |
| 12 | `C:\ProgramData\Locktime` | **0.80 GB** | NetLimiter 统计库（仍在增长） |
| 13 | `C:\Windows\WinSxS` / `Installer` | **0.63 / 0.39 GB** | 组件与 MSI 缓存 |
| 14 | `C:\Program Files (x86)\Google`、`Microsoft` | **0.97 GB** | GoogleUpdater crx 缓存 495 MB + EdgeCore 等 |
| 15 | 其余（GOG/OneDrive/NGX/PSPC_SDK/WeMod…） | ~2 GB | 各自更新残留 |

## 三、最大单点：`AppData` 近 45 天 20.16 GB（62,894 个文件被改写）

| 位置 | 体量 | 说明 |
|---|---|---|
| `AppData\Local\Claude-3p` | **10.79 GB** | **Claude Code 的 Linux 虚拟机镜像**（`vm_bundles\claudevm.bundle\rootfs.vhdx` 8.37 GB + `sessiondata.vhdx` 0.63 GB + 旧的 `rootfs.vhdx.zst` 1.20 GB）。这是**安装类新增**，不是缓存 |
| `AppData\LocalLow\Gamfs` | 2.38 GB | 棕色尘埃 II 的音效补丁包（`BrownDust II.bak`） |
| `AppData\Local\Microsoft` | 1.40 GB | Edge/OneDrive/Explorer 缓存与图标库 |
| `AppData\Local\NVIDIA` | 1.08 GB | **着色器缓存 4×256 MB**（`DXCache\*.nvph`，可删、会自动重建） |
| `AppData\Local\Programs` | 0.83 GB | 用户态安装的程序（Notion 等） |
| `AppData\Roaming\Notion` | 0.79 GB | Notion 缓存 |
| `AppData\Local\RHI` | 0.70 GB | 驱动/渲染相关缓存 |
| `AppData\Local\Temp` | 0.57 GB | 临时文件残留（含 245.7 MB `nsk3E2B.tmp\app-64.7z`、233 MB VSCode 安装器） |
| `AppData\Roaming\Tencent` | 0.43 GB | QQ/会议/游戏缓存 |
| `AppData\Local\Steam` | 0.41 GB | Steam htmlcache |
| 其余（quark-updater 285 MB、deepseek-desktop-updater 269 MB、WeMod 226 MB、Rime 183 MB、uv 91 MB…） | ~2 GB | 各类更新器/缓存 |

## 四、铁证：这台机器已经因为 C 盘太满开始"报错"了

系统日志里有一条**直接相关**的记录：

```
2026/10/8 2:02:20   Service Control Manager (事件 7023)
The Windows Error Reporting Service service terminated with the following error:
  The paging file is too small for this operation to complete
```

即：**"页文件太小，无法完成此操作"** —— Windows 错误报告服务因此启动失败。
这与前面的账完全对得上：物理内存 31.82 GB，提交量已到 29~31 GB，页文件被压着不够用。
**C 盘满 → 页文件长不大 → 系统级服务开始失败**，这就是"爆炸"已经产生实际后果的证据。

> 另一处交叉印证：`Microsoft-Windows-Resource-Exhaustion-Detector` 有多次 start/stop（10-02、10-03、10-06），
> 说明这段时间系统反复进入过资源紧张状态。

## 五、一句话结论

- **9 月中旬到 10 月上旬这一个月，C 盘被"更新 + AI 运行时 + 缓存"吃掉了约 40~50 GB**：累积更新（System32 3.8 GB）、Claude 虚拟机（9.2 GB）、NVIDIA 驱动包与着色器缓存（~3.8 GB）、Edge/Chrome/WebView2 多版本（~4 GB）、商店应用更新（2.6 GB）、页文件（+4.3 GB）、以及散布在 AppData 里的十几处"更新器 + 缓存"（~8 GB）。
- 这些**没有一处是"垃圾文件"意义上的意外**：全都是正常软件安装/更新/运行产生的，只是**从没人清理**，叠加在一台只有 128 GB 的 C 盘上。
- 所以"爆炸"的真相是：**持续性堆积**（每月 ~20 GB 量级），不是某一天的单一事件。这也是为什么 10-06 那次盘点时已经只剩 3.7 GB。

## 五、针对"近期新增"的清理优先级（只列本文件新发现的项）

```powershell
# A. 已确认可删/应删的"新增残留"（约 2.5 GB，低风险）
Remove-Item 'C:\Users\GD\AppData\Local\NVIDIA\DXCache\*.nvph' -Force -EA 0                      # 1.08 GB 着色器缓存，自动重建
Remove-Item 'C:\Users\GD\AppData\Local\Temp\nsk3E2B.tmp' -Recurse -Force -EA 0                  # 245.7 MB 安装器临时目录
Remove-Item 'C:\Users\GD\AppData\Local\Temp\vscode-stable-user-x64' -Recurse -Force -EA 0       # 233 MB VSCode 安装器
Remove-Item 'C:\Users\GD\AppData\Local\@deepseek-aidsh-desktop-updater' -Recurse -Force -EA 0   # 269 MB 更新器残留
Remove-Item 'C:\Users\GD\AppData\Local\quark-cloud-drive-updater\pending' -Recurse -Force -EA 0 # 285 MB 待安装包
Remove-Item 'C:\Users\GD\AppData\Local\notion-updater' -Recurse -Force -EA 0                    # 101 MB
Remove-Item 'C:\Users\GD\AppData\Local\lx-music-desktop-updater' -Recurse -Force -EA 0          # 113 MB

# B. 观察后再决定（占 1.2 GB）
#   C:\Users\GD\AppData\Local\Claude-3p\vm_bundles\claudevm.bundle\rootfs.vhdx.zst
#   ↑ 这是 rootfs.vhdx 的旧压缩包，已经有了解压后的 vhdx，通常可删；但请先确认 Claude Code 能正常用

# C. 真正的大头仍在结构性回收（见 cdrive_cleanup_paths_2026-10-10.md）
#   页文件移 D:（10.47 GB）、Claude VM 移 D:（9.2 GB，可与 .zst 一起搬）、
#   卸载不用软件（腾讯会议 838 MB / WSL 723 MB / Epic 1.08 GB）、WinSxS DISM 清理
```

> 提醒：`AppData\Local\Claude-3p`（10.79 GB）与 `pagefile.sys`（10.47 GB）合计 21 GB，都适合**搬到 D:** 而不是删除。
> 两者相加 ≈ 21 GB，足以把 C: 剩余从 0.93 GB 抬到 22 GB 左右。

## 六、给"监控新增"任务的两个改进建议

1. **当前口径只统计"新增/变化"，看不出"谁在持续膨胀"**。建议在报告里增加"**近 N 天累计写入量 TOP 目录**"（本文件第二、三节就是这种表），这样一眼能看出是 Claude VM、NVIDIA 缓存还是临时目录在长。
2. **`AppData` 需要单独分组下钻**。整盘统计里 `Users\GD\AppData` 是一个 20 GB 的黑盒；按二级目录（`Local\Claude-3p`、`Local\NVIDIA`、`Local\Temp`…）展开才有用——本次已证明这个视角最有效。
