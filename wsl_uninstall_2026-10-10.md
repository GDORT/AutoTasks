# WSL 正确卸载步骤（针对本机实测情况）

> 本机实测结论（2026-10-10）：
> - WSL 是 **Store/MSI 形态的包**：`C:\Program Files\WindowsApps\MicrosoftCorporationII.WindowsSubsystemForLinux_3.0.1.0_x64__8wekyb3d8bbwe`
> - `wsl --version` = **WSL 3.0.1.0**，内核 6.18.40.1-1，WSLg 1.0.79
> - **没有安装任何 Linux 发行版**（`wsl --list` 返回空）→ 所以没有 `ext4.vhdx` 之类的大映像，**总占用只有约 1.5 GB**
> - 服务 `WslService` 正在运行（Automatic）、`LxssManager` 已停止（Manual）
> - 体积：`C:\Program Files\WSL` 1,167.4 MB（含 `system.vhd` 722.9 MB、`tools\artifacts.vhd` 96.5 MB）+ WindowsApps 包 366.0 MB

---

## 第 0 步：先确认没有发行版（避免误删数据）

```powershell
wsl --list --verbose          # 输出为空 = 没有发行版
wsl --status
```
> 如果这里**列出了发行版**（如 Ubuntu），先做第 0.5 步备份再继续，否则第 3 步的 `--uninstall` 会把它们一起删掉。

### 第 0.5 步（仅当有发行版）：先导出备份，再注销

```powershell
mkdir D:\WSL-Backup -Force
wsl --export Ubuntu D:\WSL-Backup\ubuntu-backup.tar     # 发行版名换成 wsl -l 里显示的
wsl --unregister Ubuntu                                  # 注销并删除该发行版的虚拟磁盘
```

## 第 1 步：停掉 WSL（管理员 PowerShell）

```powershell
wsl --shutdown
Stop-Service WslService -Force -ErrorAction SilentlyContinue
```

## 第 2 步：卸载 WSL 包本体（这是主要占用）

```powershell
# 方式 A（推荐，适用于 Store 版 WSL）
wsl --uninstall

# 方式 B：如果方式 A 报错（例如包是 MSI 装的），走 Appx 卸载
Get-AppxPackage -Name MicrosoftCorporationII.WindowsSubsystemForLinux | Remove-AppxPackage

# 方式 C：如果它其实是"Windows 功能"装的，先查再关
Get-WindowsOptionalFeature -Online | Where-Object FeatureName -match 'Linux'
#   若 Microsoft-Windows-Subsystem-Linux 是 Enabled：
# Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
```

## 第 3 步：按需关闭底层虚拟化功能（可选）

```powershell
# 只有在你不再需要任何虚拟化（Docker Desktop / 安卓模拟器 / Windows 沙盒 / Hyper-V）时才关
Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
# 不用 Hyper-V 的话：
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
```
⚠️ `VirtualMachinePlatform` 是**共享底座**：
- 若你装了 **Docker Desktop**（当前未发现 Docker 目录）或**安卓模拟器**，关掉它们会一起坏。
- 只卸 WSL、保留虚拟化是完全可以的（第 2 步做完就已足够回收空间）。

## 第 4 步：清理残留（重启后）

```powershell
# 重启一次，让功能关闭生效
Restart-Computer
```

重启后回来执行：

```powershell
# 删除残留目录（1.17 GB）
Remove-Item 'C:\Program Files\WSL' -Recurse -Force -ErrorAction SilentlyContinue

# 删除 WSL 的用户级数据/设置（很小，但删干净）
Remove-Item "$env:LOCALAPPDATA\Packages\MicrosoftCorporationII.WindowsSubsystemForLinux_8wekyb3d8bbwe" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\.wslconfig" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\wsl" -Recurse -Force -ErrorAction SilentlyContinue

# 清掉微软商店留下的 WSL 内核更新包（若有）
Get-AppxPackage -Name '*WindowsSubsystemForLinux*' | Remove-AppxPackage -ErrorAction SilentlyContinue
```

## 第 5 步：验证

```powershell
wsl --version                     # 期望："未找到" 或 命令不存在
Get-Service WslService -ErrorAction SilentlyContinue   # 期望：不存在
Test-Path 'C:\Program Files\WSL'  # 期望：False
$d = New-Object System.IO.DriveInfo 'C'; "C: free = {0:N2} GB" -f ($d.AvailableFreeSpace/1GB)
```

## 预期收益

| 项 | 体量 |
|---|---|
| `C:\Program Files\WSL`（含 system.vhd 722.9 MB + artifacts.vhd 96.5 MB） | 1,167.4 MB |
| `%ProgramFiles%\WindowsApps\...WindowsSubsystemForLinux_3.0.1.0...` | 366.0 MB |
| 用户级包数据（预计） | 数 MB ~ 数十 MB |
| **合计** | **≈ 1.5 GB** |

## 注意事项

1. **不会有"几十 GB 的 Linux 数据"被漏删**：本机 `wsl --list` 为空，说明从未装过发行版；WSL 的发行版数据若存在会在 `%LOCALAPPDATA%\Packages\<发行版包名>\LocalState\ext4.vhdx`，本机没有。
2. **先 `wsl --uninstall` 再关功能**：顺序反了的话，包可能残留成"孤儿"。
3. 本机 `C:\Windows\System32\lxss`（376 MB 量级）属于系统组件，**不要手删**，由功能关闭/系统更新管理。
4. 如果你的目的是**腾空间**：WSL 只值 1.5 GB，而页文件（10.47 GB）和 Claude 虚拟机（9.2 GB）才是大头 —— 见 `cdrive_cleanup_paths_2026-10-10.md` 第 0 步与第三节。
