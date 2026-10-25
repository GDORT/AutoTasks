# C 盘清理：完整路径清单 + 可执行命令（2026-10-10）

> 配套文档：`cdrive_cleanup_advice_2026-10-10.md`（归因分析） / `cdrive_incremental_verify_2026-10-09.md`（增量验证）
> 本文件只给**可直接执行的完整路径与命令**。当前 **C: 128.0 GB / 已用 127.05 GB / 剩余 0.94 GB**。
> 执行前请逐条确认；标 🔴 的是"收益最大但也最需要你点头"的。

---

## 第 0 步（收益最大，10.47 GB）：把页文件移到 D:

**这是唯一一条能一次拿回两位数 GB 的操作**，而且 D: 有 424.5 GB 空闲。

```powershell
# 需要管理员权限的 PowerShell
# 1) 查看现状（应为 ?:\pagefile.sys = 系统自动管理）
Get-CimInstance Win32_PageFileSetting | Format-List Name,InitialSize,MaximumSize
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management').PagingFiles

# 2) 关掉"自动管理"，在 D: 建 16GB 固定页文件
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{AutomaticManagedPagefile=$false} }
Set-CimInstance -Query "SELECT * FROM Win32_PageFileSetting WHERE Name='D:\\pagefile.sys'" -Property @{InitialSize=16384; MaximumSize=16384} -ErrorAction SilentlyContinue
if (-not (Get-CimInstance Win32_PageFileSetting -Filter "Name='D:\\pagefile.sys'")) {
  New-CimInstance -ClassName Win32_PageFileSetting -Property @{Name='D:\pagefile.sys'; InitialSize=16384; MaximumSize=16384}
}

# 3) C: 保留一个小的固定页文件（避免"无页文件"告警、并保留崩溃转储能力）
Set-CimInstance -Query "SELECT * FROM Win32_PageFileSetting WHERE Name='C:\\pagefile.sys'" -Property @{InitialSize=4096; MaximumSize=4096} -ErrorAction SilentlyContinue

# 4) 确认注册表（应为 C:\pagefile.sys 4096 4096 与 D:\pagefile.sys 16384 16384）
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management').PagingFiles

# 5) 重启后生效：C: 的 pagefile.sys 会缩到约 4GB（释放约 6.5GB）；
#    若把 C: 设为 0 0（最小 16MB）则可释放约 10.4GB，但会失去内核转储。
Restart-Computer
```

> 说明：页文件正在使用中，**必须重启**才会真正缩小。重启后回来核对
> `Get-Item C:\pagefile.sys -Force | Select Length` 即可。
> 为什么不能"直接关掉"：见本文件末尾"页文件为什么开着"。

---

## 第一梯队：高价值 + 低风险（约 2.2 GB）

```powershell
# 1) 游戏着色器预编译缓存（霍格沃茨之遗）—— 760 MB，删了进游戏自动重建
Remove-Item 'C:\ProgramData\D3DGraphics_V4318_D10115_S415897457_R161.ushaderprecache' -Recurse -Force

# 2) 用户临时目录（只清 7 天前的，避免删到正在写的文件）—— 约 580 MB
Get-ChildItem 'C:\Users\GD\AppData\Local\Temp' -Recurse -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
# 明确的单个大件（Playnite 更新器残留，144 MB）：
Remove-Item 'C:\Users\GD\AppData\Local\Temp\Playnite\update.exe' -Force -ErrorAction SilentlyContinue

# 3) 系统临时目录 —— 约 320 MB（含 140.2MB wct8DC6.tmp、134.7MB tmp4D4E.tmp 等安装器残留）
Get-ChildItem 'C:\Windows\Temp' -Recurse -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-3) } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# 4) Windows 更新下载缓存 —— 约 53 MB
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -ErrorAction SilentlyContinue
Start-Service wuauserv -ErrorAction SilentlyContinue

# 5) 回收站 —— 187.7 MB（161 个旧文件）
Clear-RecycleBin -DriveLetter C -Force -ErrorAction SilentlyContinue

# 6) 更新回滚残留 —— 约 1 MB
Remove-Item 'C:\WRP5BFA.tmp' -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\$WinREAgent' -Recurse -Force -ErrorAction SilentlyContinue

# 7) 浏览器缓存 —— 251 MB
Remove-Item 'C:\Users\GD\AppData\Local\Microsoft\Edge\User Data\Default\Cache\*' -Recurse -Force -ErrorAction SilentlyContinue
```

## 第二梯队：需要一点判断（约 1.7 ~ 2.5 GB）

```powershell
# 8) 百度网盘：整个目录实测 1797.6 MB；优先用客户端"清理缓存"。
#    只删自动更新下载的安装包最安全（别删 module\ 与 *.dll）：
Get-ChildItem 'C:\Users\GD\AppData\Roaming\baidu\BaiduNetdisk\AutoUpdate\Download' -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in '.cab','.exe','.zip' } | Select-Object FullName,Length
#   -> 确认后： ... | Remove-Item -Force
#   缓存目录（可清）：
Remove-Item 'C:\Users\GD\AppData\Roaming\baidunetdisk\Cache\Cache_Data\*' -Recurse -Force -ErrorAction SilentlyContinue

# 9) Edge 旧版本（当前已升到 154.0.4258.62；旧版 154.0.4258.53 占 872.5 MB）
#    ★ 先确认 Edge 能正常启动，再删；更稳是等 Edge 自己清理（约 10 天）
Get-ChildItem 'C:\Program Files (x86)\Microsoft\Edge\Application' -Directory |
  Where-Object { $_.Name -match '^\d+\.' } | Select-Object Name,LastWriteTime
#   确认当前版本号后再删旧目录：
# Remove-Item 'C:\Program Files (x86)\Microsoft\Edge\Application\154.0.4258.53' -Recurse -Force

# 10) 下载目录里能重新下载的安装包 —— 约 1.2 GB（确认软件已装好再删）
$dl = 'C:\Users\GD\Downloads'
'象棋软件.rar','QuarkCloudDrive_v3.23.2_release_(Build2383348-20250821173039).exe',
'Flow-Launcher-Setup.exe','Notion Setup 7.20.0.exe','app-Windows-arm.asar',
'sikulixide-2.0.5-win.jar','TokenTracker-Setup.exe','BD2_auto_fishing.v4.2.exe',
'BD2_auto_fishing v4.1 beta.exe','Git-2.53.0-64-bit.exe','tsetup-x64.7.0.5.exe',
'UsbEAm_Hosts_Editor_V5.0.1.zip','UsbEAm_Hosts_Editor_V4.0.3.zip',
'windowsdesktop-runtime-8.0.10-win-x64.exe','windowsdesktop-runtime-6.0.33-win-x64.exe' |
  ForEach-Object { $p = Join-Path $dl $_; if (Test-Path $p) { "{0,10:N1} MB  {1}" -f ((Get-Item $p).Length/1MB), $p } }

# 11) NVIDIA 安装残留 —— 201.3 MB
Remove-Item 'C:\Program Files\NVIDIA Corporation\Installer2\Display.PhysX.{74B1EBBF-0353-41EA-BC00-4E756515C611}' -Recurse -Force -ErrorAction SilentlyContinue

# 12) pip 缓存 —— 215 MB
& "$env:LOCALAPPDATA\Programs\Python\Python*\python.exe" -m pip cache purge 2>$null
# 或直接删：
Remove-Item 'C:\Users\GD\AppData\Local\pip\cache\*' -Recurse -Force -ErrorAction SilentlyContinue
```

## 第三梯队：结构性回收（10.5 GB+）

| 目标 | 完整路径 / 命令 | 可回收 | 说明 |
|---|---|---|---|
| 页文件移 D: | 见第 0 步 | **10.47 GB** | 🔴 首选 |
| 腾讯会议（不用就卸） | `C:\Program Files\Tencent\WeMeet`（838 MB） | 838 MB | 走"应用和功能"卸载 |
| WSL（未装发行版） | `C:\Program Files\WSL`（system.vhd 722.9 MB） | 723 MB | 不用就卸载 |
| Epic Online Services | `C:\Program Files (x86)\Epic Online Services`（1083.1 MB） | 1.08 GB | 不用 Epic 就卸 |
| WeMod | `C:\Users\GD\AppData\Local\WeMod`（168.7 MB） | 169 MB | 不用就卸 |
| WinSxS 组件清理 | `DISM /Online /Cleanup-Image /StartComponentCleanup` | 1~3 GB? | 先 `/AnalyzeComponentStore`；代价：不能卸载已装更新 |
| 用户大目录迁 D: + junction | `C:\Users\GD\AppData\Local`（39.5 GB）、`C:\Users\GD\Documents`（12.5 GB，含戴森球存档 ≈12 GB）、`C:\Users\GD\Downloads`（2.3 GB） | 20 GB+ | 长期正解，逐个迁移并验证 |

### 不要动（会坏事）

- ❌ `C:\Windows\Installer\*.msi`（2,273.4 MB / 205 个）：手删会导致 Office / NVIDIA **无法修复、无法卸载、更新失败**。
- ❌ `C:\Windows\WinSxS`（10,151.2 MB）：只能用 DISM，不能手删。
- ❌ `C:\Windows\System32\DriverStore\FileRepository\*.inf_*`：旧驱动由系统管理。
- ❌ 关闭/删除页文件（见下）。
- ❌ `C:\Program Files (x86)\Microsoft\EdgeWebView`（WebView2 运行时，2,873.9 MB）：大量应用依赖。

---

## 附：页文件为什么是开着的？——默认如此，而且不能真关

1. **Windows 默认就创建并管理页文件**，从来不需要用户去"打开"。注册表里是
   `PagingFiles = ?:\pagefile.sys`，其中 `?` 表示"**由 Windows 自动管理大小**"——这是出厂/装机默认值。
   你印象里的"没开过"是对的：**它不需要你开**。
2. **页文件不等于"内存不够才用到"**。它承担三件事，与内存够不够无关：
   - 存放**提交量（commit）中超过物理内存的那部分**；
   - 支撑**内存压缩/换出**的落地页；
   - 承载**崩溃转储**（本机 `CrashDumpEnabled=3` 小转储）。
3. 本机当前实测（用 `GlobalMemoryStatusEx` 取的精确值）：
   - 物理内存 **31.82 GB**（32 GB 规格，差值属正常保留）
   - 提交上限（内存+页文件）= **42.05 GB**
   - **已提交 29.47 GB** ← 距 31.82 GB 物理内存只剩约 2.3 GB
   - 因此页文件**必须**存在，且被用到 **37.6%**；这也是它从 6.16 GB 长到 10.47 GB 的直接原因。
4. 所以：**不要设成"无页文件"**，正确做法是"**移到 D:**"（第 0 步）。真设成无页文件，在 29.5 GB 提交量下部分游戏/模拟器会直接崩，且蓝屏时拿不到转储。

## 附：关于内存"好像只有 16G"

- **Windows 识别到的是 31.82 GB**（≈32 GB 规格），没有被 BIOS 限制、也没有被 msconfig 的"最大内存"截断：
  读取方式 `GlobalMemoryStatusEx().ullTotalPhys`，与物理内存条容量一致。
- 你感觉"只跑了 16G"，最可能来自这两处显示：
  - 任务管理器/系统信息里看到的 **"可用内存 15.37 GB"**（这是"当前空闲"，不是总量；当前内存负载 **51%**）；
  - 或"可用 X GB"里的"可用"被读成了总量。
- **真正值得注意的是提交量**：已提交 **29.47 GB**（≈物理内存的 93%）。这台机器（i5-12600KF + RTX 4070 SUPER 12GB + Maxsun 主板 / BIOS H6.1G 2024-04）日常背着
  VS Code、msedgewebview2、Steam、Wallpaper Engine、NetLimiter、百度网盘、Notion、Listary、LeiGod、TokenTracker、Karing/虚拟网卡、OneDrive、腾讯会议等常驻项；
  提交量逼近物理上限，是页文件膨胀与"感觉内存不够用"的共同根源。
- 如果确实想确认物理内存条是否为 32 GB（两条 16 GB / 单条 32 GB），
  以管理员身份运行：`wmic memorychip get BankLabel,Capacity,Speed,PartNumber`
  （本会话沙箱拒绝访问 WMI 的物理内存类，故无法在此代查）。

## 附：执行后如何复核

```powershell
# 剩余空间
$d = New-Object System.IO.DriveInfo 'C'; "free = {0:N2} GB" -f ($d.AvailableFreeSpace/1GB)

# 复核扫描（任务自己的口径；需在有写权限的会话/计划任务里跑才会落盘）
powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\AIAppData\AutoTasks\AutoCDriveMonitor\scan.ps1' -DryRun
# 期望输出：DELTA_MB=<数值|0>  MODE=incremental|first-run|degraded
```
