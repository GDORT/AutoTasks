# ============================================================
# register_scheduler.ps1 — 为 must 任务 daily-checkin 创建本地「兜底」计划任务
# 定位：与 WorkBuddy 自动化 31e98286 **同点 00:05** 触发，但**不依赖 WorkBuddy 是否在运行**：
#       机器开机且已登录时，即便 WorkBuddy 没跑，本任务也会拉起它并完成签到。
#       两条入口都只调 run-task；run-task 的**跨进程文件锁 + 周期去重**保证只有一方真正执行，
#       另一方 no-op（无需再错开时间，历史上同为 00:05 并发双跑的问题已由锁根治）。
# 关机/休眠漏跑：StartWhenAvailable 会在下次开机/登录后立即补跑。
#
# 用法（需提权 / 管理员运行，因 agent 不能自绑计划任务）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AIAppData\AutoTasks\register_scheduler.ps1"
# 幂等：重复运行以 -Force 原地覆盖。
# ============================================================
$ErrorActionPreference = 'Stop'
$AutoTasks = Split-Path -Parent $MyInvocation.MyCommand.Definition
$runTask   = Join-Path $AutoTasks 'run-task.ps1'
$taskName  = 'AutoTasks.daily-checkin'

# 动作：隐藏窗口调用 run-task 闸门（executorType=shell 时 run-task 会真正执行 checkin_all.ps1）
$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runTask`" --run daily-checkin" `
    -WorkingDirectory $AutoTasks

# 触发器：每日 00:05（与主源同点；并发由 run-task 的跨进程文件锁串行化）
$trigger = New-ScheduledTaskTrigger -Daily -At '00:05'

# 设置：错过即补跑 + 笔记本不断电中断 + 单次最多 30 分钟 + 同名实例忽略
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

# 主体：当前用户、交互登录时运行（StartWhenAvailable 在登录后补跑，正好覆盖「关机日后续开机」场景）
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description 'Must 每日签到「本地兜底触发」：00:05 触发（与 WorkBuddy 自动化 31e98286 同点，但不依赖 WorkBuddy 是否在运行）；PC 关机日开机经 StartWhenAvailable 自动补跑；经 run-task 文件锁+去重，主源已成功时本任务自动跳过。' -Force

Write-Host "OK: 已创建/更新计划任务 [$taskName]"
Write-Host "验证："
& schtasks /Query /TN "$taskName" /V /FO LIST 2>$null | Select-Object -First 12
