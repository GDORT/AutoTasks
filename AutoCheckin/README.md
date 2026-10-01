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

## 触发层（2026-10-01 schtasks / workbuddy.db 实测核对）

**架构**：两条入口都只是「触发器」，职责仅为 ①确保 WorkBuddy 在跑 ②到点放行。
真正的**执行只在下游一条链上发生一次**：

```
trigger(2 条) → run-task.ps1 --run daily-checkin（跨进程锁 + 周期去重）→ checkin_all.ps1
                 ├─→ workbuddy_checkin.ps1（不在则启动 WorkBuddy.exe → skill 签到）
                 └─→ trae_task.ps1（守卫 → 内部调 checkin.js 签到）
```

| 来源 | 时间 | 入口 | 说明 |
|---|---|---|---|
| WorkBuddy 自动化 `31e98286` | 每天 00:05 | `run-task.ps1 --run daily-checkin` | 主触发源（需 WorkBuddy 在运行） |
| Windows 计划任务 `AutoTasks.daily-checkin` | 每天 00:05 | `run-task.ps1 --run daily-checkin` | 本地兜底触发（**不依赖 WorkBuddy 是否在运行**；`StartWhenAvailable` 关机日开机补跑） |
| 手动 | 任意 | `checkin_all.ps1` / 对话 | 随时 |

> **同点 00:05 是刻意的**：Windows 任务这一路在机器开机且已登录时**必然发起**（哪怕 WorkBuddy 没开，它会把 WorkBuddy 拉起来完成签到），
> 弥补「WorkBuddy 自动化只在客户端运行时才触发」的盲区。两条入口都只调 `run-task`，由
> **跨进程文件锁**（`task-status.lock`）+ 抢锁后重读状态保证只有一方真正执行，另一方 no-op——
> 所以同点并发不再需要靠错开时间去规避。
>
> ⚠️ **入口必须写成「只触发」**：WorkBuddy 自动化 `31e98286` 的 prompt 历史上把「执行」也写了进去
> （触发后又单独跑一次 `checkin_all.ps1`），造成同一次运行内 TRAE 被重复请求。入口 prompt 只应调
> `run-task.ps1 --run daily-checkin`，不要再自行执行 `checkin_all.ps1`，也不要再调 `--done`
> （`executorType=shell` 时 run-task 已自动记录终态）。
>
> 原 6 个 `AutoCheckin.*` 计划任务已确认注销（`schtasks` 查无此任务）。
>
> **Windows 不会自动清理失效任务**：计划任务即使连续失败、脚本路径丢失也只会留在
> 任务计划程序里记录错误，不会被删除或禁用。长期不用的任务要手动 `schtasks /Delete`。

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

## ~~一键注册每日计划任务~~（已废弃，勿运行）

`register_tasks.ps1` 会重新注册 6 个 `AutoCheckin.WorkBuddy/TraeWork.{0010,0910,2010}` 计划任务，
而这正是统一任务层（AutoTasks + run-task）要消除的"重复触发"。该 6 个任务已于 2026-09-27 注销。

签到触发现已统一收口到 `run-task`（见上方「触发层」表）。**请勿再运行 `register_tasks.ps1`**；
确需本地补跑兜底时，用 `run-task.ps1 --catchup` 或 Windows 计划任务的 `StartWhenAvailable`。

## 验证是否签到成功

看共享日志（WorkBuddy 带 `[WorkBuddy]`，TRAE 带 `[TRAE]` 前缀）：
```powershell
Get-Content "D:\AIAppData\AutoTasks\AutoCheckin\checkin.log" -Tail 20 -Encoding UTF8
```

查任务状态（现役任务名是 `AutoTasks.daily-checkin`）：
```powershell
schtasks /Query /FO TABLE | findstr AutoTasks
schtasks /Query /TN "AutoTasks.daily-checkin" /V /FO LIST
```

## 已知问题（2026-10-01 实测 → 已修复）

- **重复触发** → 已修复：两条入口同为 00:05，由 `run-task.ps1` 的跨进程文件锁
  （`task-status.lock`）+ 抢锁后重读状态保证只有一方真正执行，另一方 no-op。
- **TRAE 日志守卫失效（日期格式不一致）** → 已修复：`checkin.js` 的 `appendLog` 改为固定
  `yyyy-MM-dd HH:mm:ss`；守卫同时兼容 `yyyy-MM-dd` 与 `yyyy/M/d` 两种历史格式。
- **守卫多模式是"或"** → 已修复：两侧守卫改为 `Where-Object` 显式 AND
  （「当天」+ `[TRAE]`/`[WorkBuddy]` + `[OK]` 三者同时满足），含 `[FAIL]`/`[RETRY]` 的行不再被误判为已成功。
- **`checkin_all.ps1` 绕过 TRAE 守卫** → 已修复：TRAE 段改走 `TraeWork\trae_task.ps1`，
  复用「当天已签则跳过」守卫；入口被重复触发时不再重复请求。

## WorkBuddy 签到对 buddy 进程的依赖（2026-10-01 实测）

签到本身是**纯 HTTP 接口**（`POST {base}/billing/meter/daily-checkin` + `Authorization: Bearer <accessToken>`），
**不依赖 buddy 进程**；真正依赖 buddy 的只有**解密 `accessToken`** 这一步：

- 5.6.2+ 把 `accessToken` 存成 AES-GCM 信封（`$wbEncrypted:1`），密钥 `atRestSecretKey` 按序定位：
  ① 环境变量 `WORKBUDDY_ATREST_KEY` → ② `WORKBUDDY_ATREST_KEY_FILE` → ③ 磁盘 DPAPI blob →
  ④ **运行中 `WorkBuddy.exe` 进程内存**。
- 实测（屏蔽 ④ 后）：**磁盘侧定位失败（扫描到 0 个 DPAPI blob）**；只有开启 ④ 内存扫描才成功
  （`load_token_best` 返回 token_len=1334）。`~\.workbuddy\keyblob` 经查**不是** DPAPI blob，非该密钥。
  → **现状下 buddy 不在跑就无法签到**——这正是「buddy 加密导致不可用」的真身。

**若要让签到彻底脱离 buddy**：在 buddy 运行期间把 `atRestSecretKey` 取一次并持久化，
设 `WORKBUDDY_ATREST_KEY_FILE=<该文件绝对路径>`（或 `WORKBUDDY_ATREST_KEY=<44字符base64>`），
此后 ①/② 命中即无需 buddy。**代价**：buddy 重新登录可能轮换该密钥（keyId 变化）需重取；
脚本会以 keyId 不匹配明确报错，不会静默失败。

> 该密钥等同「解密登录态的钥匙」，落盘即降低安全性，是否启用需自行权衡（默认不启用）。

## 前置条件
- WorkBuddy：本机已登录一次（登录态在 `%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info`，5.6.2+ 为加密格式）；**计划任务触发时客户端可以不开**——包装脚本会自动启动它
- WorkBuddy skill：`~\.workbuddy\skills\totorosir-workbuddy-checkin`（升级 = 从 SkillHub 重下 ZIP 替换该目录，WorkBuddy 内自动化每天 00:05 会检查新版本并提醒）
- TRAE：本机已登录 TRAE SOLO CN（登录态在 `%APPDATA%\TRAE SOLO CN\User\globalStorage\storage.json` 的 `iCubeAuthInfo://icube.cloudide`）
- 机器在 00:05 时开机、已登录且联网；未开机则下次开机登录后由 `StartWhenAvailable` 立即补跑

### 开机即签到的「保证边界」（2026-10-01 核对任务 XML）

| 场景 | 结果 |
|---|---|
| 00:05 时机器开机 + 已登录 + 联网 | ✅ 必然发起（Windows 任务这一路不依赖 WorkBuddy 是否在跑） |
| 00:05 时关机/休眠 | ✅ 下次开机登录后 `StartWhenAvailable` 立即补跑 |
| 开机但未登录（停留在锁屏） | ⚠️ 不发起——任务 `LogonType=InteractiveToken`，需交互式登录会话 |
| 00:05 在机但断网 | ⚠️ 该次失败记 `fail`；**当天不会自动重试**（任务无重复间隔，`--catchup` 启动钩子未接线） |

> 后两个缺口若要补：① 给任务加「重复间隔」（如 00:05 起每 30 分钟重试至成功）；② 或把 `run-task.ps1 --catchup`
> 接到登录/启动项上（`AutoAppTriggers\app-registry.json` 的 `hooks` 目前为空，等于未启用）。

> **TRAE 关键说明**：签到接口需真实设备 ID（来自 storage.json 顶层 `iCubeAuthInfo://icube-dc:xxxx` 键，脚本自动提取），并携带请求体 `req_source:1`，否则报 9004（订单参数错误）。脚本已按实测 `code:0` 判定成功，接口开放、无需风控规避。

## 安全
- 全程只读取本机登录态，不修改、不删除、不外传
- 脚本绝不打印真实 token / uid，只显示脱敏信息
- WorkBuddy skill 已人工审计 + 腾讯科恩/云鼎实验室公开审计（均无风险）；密钥定位只用 DPAPI/内存扫描，均在脚本目录留痕
- token 会随客户端长期登录自动刷新；如连续失败，先看 `checkin.log` 末尾错误行，再考虑重开客户端登录一次
