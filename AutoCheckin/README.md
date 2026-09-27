# AutoCheckin · WorkBuddy  &  TRAE 每日自动签到

> 接口直签，无 GUI / 无点击 / 零第三方依赖，幂等（已签自动跳过，绝不重复领取）。
> 本地完成，token 不外传；只读登录态、日志只记结果。

## 当前架构（2026-09-25 更新）

WorkBuddy 客户端 5.6.2 起登录态改为加密存储（AtRestEncryption），旧明文 token 方案失效。
现由 **SkillHub「WorkBuddy签到助手」skill**（`~\.workbuddy\skills\totorosir-workbuddy-checkin`）
负责 WorkBuddy 签到：自动识别明文/加密登录态，加密时通过运行中客户端内存定位密钥解密。
TRAE 方案不变（读 storage.json 解密 token）。

**统一执行策略**（WorkBuddy 与 TRAE 完全一致）：

```
触发 → 查共享日志 checkin.log：今天已有 [OK] ？
   ├─ 有 → 静默退出（不执行、不重复、不拉客户端）
   └─ 没有 → 执行签到 → 结果写共享日志
```

WorkBuddy 侧签到前会自动确保 `WorkBuddy.exe` 在运行（不在则启动并等待登录态加载约 80 秒）。

## 目录结构

```
D:\AIAppData\AutoTasks\AutoCheckin\
├── checkin.log                      共享日志（所有来源汇总，带前缀；"当天已签"守卫依据）
├── checkin_all.ps1                  手动一键签到（同时触发两者）
├── register_tasks.ps1               一键注册/重注册计划任务（幂等覆盖）
├── WorkBuddy\
│   └── workbuddy_checkin.ps1        包装脚本 v2：查日志跳过 → 确保客户端运行 → 调 skill 签到 → 写日志
└── TraeWork\
    ├── checkin.js                   TRAE 签到脚本（读 storage.json 解密 token）
    ├── trae_task.ps1                TRAE 计划任务入口：查日志跳过 → 跑 checkin.js → 写日志
    └── run_checkin.cmd              手动运行入口（显示结果并停留；计划任务不再直接用它）
```

## 触发层（四重冗余，互不重复）

| 层 | 时间 | 入口 | 说明 |
|---|---|---|---|
| WorkBuddy 内自动化 | 每天 00:05 | WorkBuddy 会话内 | 双签兜底：WorkBuddy + TRAE 查日志没签才补签 + skill 版本更新检查 + 失败醒目提醒 |
| 计划任务 ×6 | 00:10 / 09:10 / 20:10 | 两个包装脚本 | WorkBuddy、TRAE 各 3 档 |
| 手动 | 任意 | checkin_all.ps1 / 对话 | 随时 |

> **为什么不会重复**：所有入口共享同一份 `checkin.log`，动手前先查"今天是否已有 `[OK]`"。
> 先成功的写入日志，后到的全部静默跳过；即使两层几乎同时触发，签到接口本身也是幂等的
> （`action=skip_already_signed`，只查不领），最坏情况是多一次查询。
>
> **Windows 不会自动清理失效任务**：计划任务即使连续失败、脚本路径丢失也只会留在
> 任务计划程序里记录错误，不会被删除或禁用（除非建任务时显式勾选"到期删除"）。
> 所以改动脚本路径后必须重跑 register_tasks.ps1；长期不用的任务要手动 `schtasks /Delete`。

## 手动执行（验证是否可用）

### 一键签到（推荐，同时触发 WorkBuddy + TRAE）
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AIAppData\AutoTasks\AutoCheckin\checkin_all.ps1"
```

### 单独签一个
```powershell
# WorkBuddy（包装脚本，自动查日志/拉客户端）
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AIAppData\AutoTasks\AutoCheckin\WorkBuddy\workbuddy_checkin.ps1"

# TRAE（手动运行会显示结果并停留；计划任务走 trae_task.ps1）
"D:\AIAppData\AutoTasks\AutoCheckin\TraeWork\run_checkin.cmd"
```

预期输出（今天已签时）：
- WorkBuddy：`[OK] 今天已签到，获得 100 积分（幂等跳过，不重复领取）`
- TRAE：`[OK] Already checked in today. Credits: 150`

## 一键注册每日计划任务

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AIAppData\AutoTasks\AutoCheckin\register_tasks.ps1"
```

注册 6 个任务（普通用户即可，无需管理员），WorkBuddy 与 TRAE 在同一 3 个时点两两同时触发：
| 任务名 | 时间 | 入口 |
|---|---|---|
| `AutoCheckin.WorkBuddy.0010` | 00:10 | WorkBuddy\workbuddy_checkin.ps1 |
| `AutoCheckin.TRAE.0010` | 00:10 | TraeWork\trae_task.ps1 |
| `AutoCheckin.WorkBuddy.0910` | 09:10 | 同上 |
| `AutoCheckin.TRAE.0910` | 09:10 | 同上 |
| `AutoCheckin.WorkBuddy.2010` | 20:10 | 同上 |
| `AutoCheckin.TRAE.2010` | 20:10 | 同上 |

> 重复注册是幂等覆盖，无副作用。**改过任务入口/路径后必须重跑一次**（Windows 不会自动
> 同步已注册任务的指向）。

## 验证是否签到成功

看共享日志（WorkBuddy 带 `[WorkBuddy]`，TRAE 带 `[TRAE]` 前缀）：
```powershell
Get-Content "D:\AIAppData\AutoTasks\AutoCheckin\checkin.log" -Tail 20 -Encoding UTF8
```

查任务状态（注意任务名是 .0010/.0910/.2010 后缀）：
```powershell
schtasks /Query /FO TABLE | findstr AutoCheckin
schtasks /Query /TN "AutoCheckin.WorkBuddy.0910" /V /FO LIST
```

## 前置条件
- WorkBuddy：本机已登录一次（登录态在 `%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info`，5.6.2+ 为加密格式）；**计划任务触发时客户端可以不开**——包装脚本会自动启动它
- WorkBuddy skill：`~\.workbuddy\skills\totorosir-workbuddy-checkin`（升级 = 从 SkillHub 重下 ZIP 替换该目录，WorkBuddy 内自动化每天 00:05 会检查新版本并提醒）
- TRAE：本机已登录 TRAE SOLO CN（登录态在 `%APPDATA%\TRAE SOLO CN\User\globalStorage\storage.json` 的 `iCubeAuthInfo://icube.cloudide`）
- 电脑每天在 00:05-00:10 / 09:10 / 20:10 任一窗口开机且联网

> **TRAE 关键说明**：签到接口需真实设备 ID（来自 storage.json 顶层 `iCubeAuthInfo://icube-dc:xxxx` 键，脚本自动提取），并携带请求体 `req_source:1`，否则报 9004（订单参数错误）。脚本已按实测 `code:0` 判定成功，接口开放、无需风控规避。

## 安全
- 全程只读取本机登录态，不修改、不删除、不外传
- 脚本绝不打印真实 token / uid，只显示脱敏信息
- WorkBuddy skill 已人工审计 + 腾讯科恩/云鼎实验室公开审计（均无风险）；密钥定位只用 DPAPI/内存扫描，均在脚本目录留痕
- token 会随客户端长期登录自动刷新；如连续失败，先看 `checkin.log` 末尾错误行，再考虑重开客户端登录一次
