# C 盘全量空间盘点报告（2026-10-06 17:43）

> 口径：只读扫描，未改动任何文件。按 `Get-ChildItem` 逐目录 `Length` 累加。
> 数据来源：`_cdisk_probe.ps1` → `_cdisk_report.txt`
> 所有路径均为完整绝对路径。

## 一、总览
- 总计：**131,073.0 MB（≈ 128 GB）**
- 已用：**127,328.4 MB**
- 剩余：**3,744.6 MB（≈ 3.7 GB）**
- 结论：系统盘偏小（128 GB），长期偏紧是结构性问题，非单次新增造成。

## 二、C:\ 顶层目录体量
| 目录 | 大小(MB) |
|---|---|
| `C:\Windows` | 25,096.7 |
| `C:\Users` | 18,417.6 |
| `C:\Program Files` | 10,847.5 |
| `C:\Program Files (x86)` | 7,772.2 |
| `C:\XboxGames` | 37.7 |
| `C:\db` | 4.1 |
| `C:\Intel` | 0.1 |
| `C:\PerfLogs` | 0.0 |
| `C:\inetpub` | 0.0 |

> 无 `C:\pagefile.sys` / `C:\hiberfil.sys`（页面文件未背锅）。

## 三、C:\Users\GD 子目录体量（TOP）
| 目录 | 大小(MB) |
|---|---|
| `C:\Users\GD\Documents` | 12,485.5 |
| `C:\Users\GD\.workbuddy` | 7,973.2 |
| `C:\Users\GD\Downloads` | 2,559.5 |
| `C:\Users\GD\.vscode` | 1,543.1 |
| `C:\Users\GD\Saved Games` | 840.8 |
| `C:\Users\GD\.codex` | 840.5 |
| `C:\Users\GD\Videos` | 633.1 |
| `C:\Users\GD\.agent-browser` | 432.1 |
| `C:\Users\GD\.dsh` | 277.0 |
| `C:\Users\GD\.trae-cn` | 156.0 |
| `C:\Users\GD\.local` | 49.6 |
| `C:\Users\GD\.claude` | 17.4 |
| `C:\Users\GD\.tokentracker` | 15.8 |
| `C:\Users\GD\.astrbot` | 10.0 |
| （其余 Desktop / .codex-session-delete / .cc-switch / Pictures / 各类 AI 工具缓存） | 各 < 6 MB |

> 老文件大头（早过 14 天窗口，cdrive-monthly 增量扫描看不见）：
> - `C:\Users\GD\Documents\Dyson Sphere Program\Save\` 多个 `.dsv` 单文件 800 MB+，累计 ≈ 12 GB。
> - `C:\Users\GD\.workbuddy` ≈ 8 GB（WorkBuddy 运行时仍在 C 盘，未随 AIAppData 迁 D）。

## 四、C:\Users\GD 最大文件 TOP30（完整绝对路径）
| 大小(MB) | 完整路径 |
|---|---|
| 817.5 | `C:\Users\GD\Documents\Dyson Sphere Program\Save\_lastexit_.dsv` |
| 817.5 | `C:\Users\GD\Documents\Dyson Sphere Program\Save\DS-FIN.dsv` |
| 781.2 | `C:\Users\GD\Documents\Dyson Sphere Program\Save\DS-8.dsv` |
| 643.4 | `C:\Users\GD\Documents\Dyson Sphere Program\Save\DS-6.dsv` |
| 598.9 | `C:\Users\GD\Documents\Tencent Files\2472411533\nt_qq\nt_data\dataline\.tmp\Under The Witch 魔女之下1.8.7z(1).001.9B46E6355FC83973C2A28B5798A646A8.NFC` |
| 281.7 | `C:\Users\GD\.vscode\extensions\openai.chatgpt-26.903.71938-win32-x64\bin\windows-x86_64\codex.exe` |
| 279.1 | `C:\Users\GD\Downloads\象棋软件.rar` |
| 276.2 | `C:\Users\GD\Videos\NVIDIA\Desktop\Desktop 2026.04.18 - 02.03.53.01.mp4` |
| 246.7 | `C:\Users\GD\.vscode\extensions\openai.chatgpt-26.903.71938-win32-x64\bin\linux-x86_64\codex` |
| 246.2 | `C:\Users\GD\Downloads\DLSS5-Swapper-2.2.9-portable.exe` |
| 209.9 | `C:\Users\GD\.vscode\extensions\anthropic.claude-code-2.1.267-win32-x64\resources\native-binary\claude.exe` |
| 197.4 | `C:\Users\GD\Documents\Dyson Sphere Program\Save\DS-发射太阳帆.dsv` |
| 186.8 | `C:\Users\GD\Videos\NVIDIA\Desktop\Desktop 2026.04.18 - 02.08.03.02.mp4` |
| 173.5 | `C:\Users\GD\Documents\Dyson Sphere Program\Save\DS-发射火箭.dsv` |
| 149.8 | `C:\Users\GD\Documents\Dyson Sphere Program\Save\DS-1.dsv` |
| 128.3 | `C:\Users\GD\Documents\Dyson Sphere Program\Save\DS.dsv` |
| 124.7 | `C:\Users\GD\Downloads\QuarkCloudDrive_v3.23.2_release_(Build2383348-20250821173039).exe` |
| 111.0 | `C:\Users\GD\Documents\My Games\FarmingSimulator2022\shader_cache\shader_48B9554A2B4959591556FD25358EEB67_q3_s16_t3_v1_r0_v60_f60_sg_8_306.sharc` |
| 110.4 | `C:\Users\GD\Videos\NVIDIA\Death Stranding 2  On The Beach\Death Stranding 2  On The Beach 2026.04.18 - 02.13.26.03.mp4` |
| 97.1 | `C:\Users\GD\Downloads\Flow-Launcher-Setup.exe` |
| 96.5 | `C:\Users\GD\Downloads\Notion Setup 7.20.0.exe` |
| 94.5 | `C:\Users\GD\Documents\My Games\FarmingSimulator2022\shader_cache\shader_48B9554A2B4959591556FD25358EEB67_q2_s16_t3_v1_r0_v60_f60_sg_8_306.sharc` |
| 89.2 | `C:\Users\GD\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe` |
| 80.1 | `C:\Users\GD\Downloads\app-Windows-arm.asar` |
| 77.3 | `C:\Users\GD\Downloads\sikulixide-2.0.5-win.jar` |
| 77.1 | `C:\Users\GD\Downloads\TokenTracker-Setup.exe` |
| 69.1 | `C:\Users\GD\.vscode\extensions\openai.chatgpt-26.903.71938-win32-x64\bin\windows-x86_64\codex-code-mode-host.exe` |
| 67.8 | `C:\Users\GD\Documents\Rockstar Games\GTAV Enhanced\videos\clips\2025-8-18-片段-0003.clip` |
| 67.8 | `C:\Users\GD\Documents\Rockstar Games\GTAV Enhanced\videos\clips\2025-8-18-片段-0002.clip` |

## 五、清理建议（低风险优先，删除前逐条确认）
| 目标 | 完整路径 | 可回收 | 风险 |
|---|---|---|---|
| 戴森球旧存档 | `C:\Users\GD\Documents\Dyson Sphere Program\Save\` | ≈ 12 GB | 低（游戏存档，确认不需要再删） |
| 下载安装包 | `C:\Users\GD\Downloads\`（象棋软件.rar / DLSS5-Swapper-2.2.9-portable.exe / QuarkCloudDrive_*.exe / Notion Setup 7.20.0.exe / Flow-Launcher-Setup.exe / sikulixide-2.0.5-win.jar / TokenTracker-Setup.exe / app-Windows-arm.asar 等） | ≈ 2.5 GB | 低 |
| NVIDIA 录屏片段 | `C:\Users\GD\Videos\NVIDIA\` | ≈ 0.6 GB | 低 |
| WorkBuddy 运行时 | `C:\Users\GD\.workbuddy` | ≈ 8 GB | 中（先查清构成：二进制 vs 缓存，勿盲删） |
