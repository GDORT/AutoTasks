# AutoCheckin · WorkBuddy / TRAE / 豆包 每日自动签到

> 三家各自独立、各自幂等（当天已成功则 no-op，绝不重复领取）。
> 本地完成，凭据不外传；日志只记结果，不记 token。
> 最后一次与代码对齐：**2026-11-01 17:45**（豆包 v4.1 / WorkBuddy v3.2 / TRAE 不变）

## 一、三家一览

| 家 | 后端 | 需要 GUI 窗口吗 | 结果日志 | 成功判据 |
|---|---|---|---|---|
| WorkBuddy | `vendor/workbuddy-auto-signin/signin.py auto`（上游 88lin，MIT） | **不需要**。凭据靠 `ELECTRON_RUN_AS_NODE=1` 起一次性无窗口 helper 解密，跑完即退 | `WorkBuddy\checkin.log` | `result` ∈ `CLAIMED/ALREADY/INACTIVE` |
| TRAE | `TraeWork\checkin.js`（读 storage.json 解密 token） | 不需要 | `AutoCheckin\checkin.log` | js 自身写 `[TRAE] [OK]` |
| 豆包 | `vendor/doubao-cdp`（上游 bluechonk，MIT，npm 零依赖） | **需要客户端在线，但窗口进独立桌面**，你的桌面看不到、也不抢焦点 | `Doubao\checkin.log` | `result.status` ∈ `checked_in/already_checked_in/dry_run` |

> ⚠️ **三家的"当天已签"守卫各看各的日志文件**，不是同一份。排障时先确认看的是哪个文件。

## 二、执行链（唯一执行路径）

```
触发（计划任务 wscript → hidden-run.vbs @00:05）
  └→ run-task.ps1 --run daily-checkin      跨进程文件锁 + 周期去重 + 终态记录
       └→ checkin_all.ps1                  串联三家，任一失败整体非零
            ├→ [1/3] WorkBuddy\workbuddy_checkin.ps1
            ├→ [2/3] TraeWork\trae_task.ps1
            └→ [3/3] Doubao\doubao_checkin.ps1
```

- **入口只负责触发**，不得自行执行 `checkin_all.ps1`，也不得再调 `--done`（`executorType=shell` 时 run-task 自动记终态）。
- 退出码语义：`0` 成功（含今日已签）/ `5` 失败 / `6` 跳过（该家脚本未部署，**不算失败**）。

## 三、触发层

| 来源 | 时间 | 入口 | 说明 |
|---|---|---|---|
| Windows 计划任务 `AutoTasks.daily-checkin` | 每天 00:05 | `wscript.exe hidden-run.vbs daily-checkin` | **主兜底**，不依赖任何 GUI 是否在运行；`StartWhenAvailable=True` 关机日开机补跑；`MultipleInstances=IgnoreNew` |
| WorkBuddy 自动化 `31e98286` | 每天 00:05 | `run-task.ps1 --run daily-checkin` | 需 WorkBuddy 在运行 |
| 手动 | 任意 | `checkin_all.ps1` | 排障用 |

> 两条入口同为 00:05 是刻意的：由 `run-task.ps1` 的跨进程文件锁 `task-status.lock`（抢锁后重读状态）保证只有一方真正执行，另一方 no-op。
>
> **任务动作必须是 `wscript.exe + vbs`**，不能直接注册 `powershell.exe`：后者是 console 子系统程序，Task Scheduler 启动时会**先创建可见控制台再隐藏**（实测差 ~240ms），每天整点闪一次窗抢焦点。vbs 走 `WScript.Shell.Run(cmd, 0, True)`，控制台从创建起就不可见。

## 四、目录结构

```
D:\AIAppData\AutoTasks\AutoCheckin\
├── checkin.log                       TRAE 结果 + 手工汇总（`[TRAE]` 前缀）
├── checkin_all.ps1                   一键三签（串联 + 汇总失败）
├── README.md                         本文件
├── WorkBuddy\
│   ├── workbuddy_checkin.ps1         v3.2：守卫 → 代理变量清理 → signin.py auto（失败重试 1 次）
│   └── checkin.log                   WorkBuddy 结果（`[WorkBuddy]` 前缀）
├── TraeWork\
│   ├── checkin.js                    TRAE 签到本体
│   ├── trae_task.ps1                 守卫 → 跑 checkin.js
│   └── run_checkin.cmd               手动入口（显示结果并停留）
└── Doubao\
    ├── doubao_checkin.ps1            v4.1：守卫 → 互斥锁 → 独立桌面启动 → CDP 签到 → 收尾
    └── checkin.log                   豆包结果（`[Doubao]` 前缀）
```

## 五、豆包签到（v4.1，2026-11-01）

### 5.1 为什么要独立桌面

豆包是 Electron 客户端，靠 CDP（`--remote-debugging-port=9222`）接管页面点击。若按常规方式启动：

- `STARTUPINFO.wShowWindow = SW_SHOWMINNOACTIVE(7)` → **Electron 直接忽略**，实测启动后 +0.9s 前台就被切走；
- 启动后再最小化/挪到屏幕外 → 焦点已经被抢走，事后 `SWP_NOACTIVATE` 只阻止再次激活，**不归还已有焦点**（2026-11-01 发生过输入法被占用、键盘重复输入的事故）。

现做法：`CreateDesktop("DoubaoBotDesktop")` 建一个不属于你桌面的 Desktop，`CreateProcess` 的 `STARTUPINFO.lpDesktop` 指过去 → 窗口存在于另一个桌面，**你的桌面既看不到也不会被抢焦点**（实测全程前台 hwnd 变化 0 次）。CDP 不受影响：页面照常渲染，点击走 `Input.dispatchMouseEvent` 注入渲染器，与桌面/焦点无关。

> **PowerShell 坑**：把 `$null` 传给 .NET `string` 参数会变成空串 `""` 而非 NULL 指针 → `CreateDesktop` 报 `err=87`。必须传 `[NullString]::Value`。

### 5.2 桌面不会被残留

Windows **没有** `DeleteDesktop`。桌面是引用计数对象：关闭最后一个句柄、且其上没有窗口再持有引用时，由内核自动销毁。

| 情况 | 谁清理 | 结果 |
|---|---|---|
| 正常签完 | `finally` 里 `CloseDesktop` | 立即销毁 |
| 脚本被强杀 / 断电 | 句柄随进程回收，引用计数归零 | 同样销毁 |
| 豆包进程没退净（窗口持有引用） | 下次 `OpenDesktop` 接管同名桌面，签完一起清 | 不堆积 |

桌面名固定 `DoubaoBotDesktop`，所以即使某次残留同名桌面，下次也是**接管**而不是新建第二个。收尾时用 `OpenDesktop` 反查一次：打不开（`err=2 ERROR_FILE_NOT_FOUND`）= 已销毁，结果写进日志。

### 5.3 可控性措施

| 措施 | 解决什么 |
|---|---|
| 单实例互斥锁 `Local\AutoTasks-DoubaoCheckin` | 手动跑与计划任务撞车（A 的 taskkill 会打断 B 的签到）；锁本身不可用时降级为无锁继续并留 WARN，不因此放弃签到 |
| 主流程整体 `try/finally` | 成功/失败/超时/异常**任何**分支都执行收尾（关进程 + 释放桌面） |
| 双超时 | 等调试端口 45s、CLI 300s，超时即收尾退出 |
| **不回退弹窗** | 独立桌面起不来就直接判 FAIL——宁可本次不签，也不为签到抢你的前台 |
| 当天守卫 | 日志里今天已有 `[Doubao] [OK]` → 直接 exit 0，完全不碰客户端（不会反复重试） |
| 收尾自证 | 进程数 + 桌面对象是否销毁，逐项写日志 |

### 5.4 客户端生命周期（2026-11-01 用户决定）

1. 今天已记 `[OK]` → 不碰客户端；
2. 调试端口已开 → 复用现有实例，签完关闭；
3. 其余 → 结束已有实例 → 独立桌面启动 → 等端口 → 签到 → **一律关闭**。

> 已接受的代价：若 00:05 正开着豆包，会被直接结束（聊天记录不丢，未发送的输入可能丢）。

### 5.5 已知边界（如实标注）

- **真实点击已实测通过（2026-11-02 00:05 首次真跑）**：`result=checked_in`，额度 `200 -> 600`，10s 完成；收尾 `进程 14 -> 0`、桌面对象已销毁。即「独立桌面里注入点击」这条路成立，不只是能读状态。若后续 FAIL，按上游 `vendor/doubao-cdp/docs/04-verification.md` 与 `SKILL.md` 排障表查（最常见是客户端改版导致入口文案变化，改 `src/checkin.mjs` 的 `ANCHORS.signinEntryText` 一处即可）。
- 客户端升级若改变 `Doubao.exe` 路径，`config.local.json` 的 `doubaoExe` 需同步。
- 锁屏状态下 CDP 渲染是否可用未实测（00:05 通常醒着）。

## 六、WorkBuddy 签到（v3.2）

- **不再启动 GUI**：凭据通过 `WorkBuddy.exe -e <helper>` + `ELECTRON_RUN_AS_NODE=1` 在无窗口 helper 进程里解密，跑完即退。因此**不存在「用完关闭客户端」的问题**（旧版会拉起 WorkBuddy.exe 等 80 秒，已废弃）。
- 覆盖：每日签到 + 成长中心（旅行礼物 / 任务 / 断登补登 / 连登兑换 / 盲盒）。
- **一次重试**：读凭据偶发 `PermissionError`（2026-11-01 实测同一条命令先 ERROR 后 ALREADY），而本脚本一天只跑一次、失败即当天断签，故失败重试 1 次（间隔 5s）。签到接口幂等，重试不会重复领取。
- **两路取 JSON**：正常结果在 stdout，但实测偶发「JSON 只出现在 stderr」导致 ALREADY 被误判成 FAIL，现在 stdout / stderr 都扫。
- **代理变量清理**：环境块同时存在 `HTTPS_PROXY` 与 `https_proxy` 时，.NET 构造子进程环境字典抛「已添加项，字典中的关键字重复」，表现为连 `cmd` 都起不来。脚本自己清一次（`run-task` 路径也有一份同样的清理）。

## 七、验证是否签到成功

```powershell
# 三家分别看
Get-Content "D:\AIAppData\AutoTasks\AutoCheckin\WorkBuddy\checkin.log" -Tail 5 -Encoding UTF8
Get-Content "D:\AIAppData\AutoTasks\AutoCheckin\checkin.log"         -Tail 5 -Encoding UTF8
Get-Content "D:\AIAppData\AutoTasks\AutoCheckin\Doubao\checkin.log"  -Tail 5 -Encoding UTF8

# 统一任务终态
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AIAppData\AutoTasks\run-task.ps1" --status
schtasks /Query /TN "AutoTasks.daily-checkin" /V /FO LIST
```

## 八、手动执行

```powershell
# 三签一起（推荐排障用）
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AIAppData\AutoTasks\AutoCheckin\checkin_all.ps1"

# 单签一家（-Force 绕过当天守卫，仅排障）
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AIAppData\AutoTasks\AutoCheckin\WorkBuddy\workbuddy_checkin.ps1" -Force
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AIAppData\AutoTasks\AutoCheckin\TraeWork\trae_task.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AIAppData\AutoTasks\AutoCheckin\Doubao\doubao_checkin.ps1" -Force
```

## 九、前置条件

- 机器 00:05 开机 + 已登录（交互式会话）+ 联网；关机日由 `StartWhenAvailable` 在开机登录后补跑。
- 锁屏状态（未登录）不发起——任务 `LogonType=Interactive`，需交互式会话。
- `config.local.json` 需存在且路径有效（`python` / `signinScript` / `nodeExe` / `doubaoScript` / `doubaoNode` / `doubaoExe` / `traeExe`），模板见 `config.local.example.json`。

## 十、已知问题与修复记录

| 日期 | 问题 | 处置 |
|---|---|---|
| 2026-10-01 | 双入口重复执行 | `run-task` 跨进程文件锁 + 抢锁后重读状态 |
| 2026-10-01 | TRAE 守卫日期格式不一致 | `appendLog` 固定 `yyyy-MM-dd HH:mm:ss`，守卫兼容两种格式 |
| 2026-10-01 | 守卫多模式是 OR，FAIL 行被当成功 | 改 `Where-Object` 显式三者 AND |
| 2026-10-01 | `checkin_all` 绕过 TRAE 守卫 | TRAE 段改走 `trae_task.ps1` |
| 2026-10-25 | 计划任务整点闪窗抢焦点 | 任务动作全改 `wscript.exe + hidden-run.vbs`（`Run(cmd,0,True)`） |
| 2026-11-01 | 豆包窗口抢前台、导致输入法被占用 | 改独立桌面（见 5.1） |
| 2026-11-01 | 豆包收尾可能被异常跳过 | 主流程包 `try/finally` + 收尾自证 |
| 2026-11-01 | 豆包互斥锁用 `Global\` 在受限令牌下会抛异常 | 改 `Local\`，且锁不可用时降级继续 |
| 2026-11-01 | `run-task` 子进程 `WaitForExit()` 无限等待 | 加 25min 超时 + 按进程树强杀（exit=124） |
| 2026-11-01 | WorkBuddy 偶发 PermissionError / 代理变量字典冲突 | 失败重试 1 次 + 自身清理代理变量 + 两路取 JSON |

## 十一、安全

- 全程只读本机登录态，不修改、不删除、不外传；脚本不打印真实 token / uid。
- `vendor/` 下两个后端均为 MIT 开源，本地只做了最小改动（豆包：`ANCHORS.signinEntryText` 一处；WorkBuddy：无改动）。
- 豆包命令行不落凭据：CDP 只操作已登录客户端，密钥材料不经过本仓库。
