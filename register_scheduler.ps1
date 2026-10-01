# ============================================================
# register_scheduler.ps1 — 为 must 任务 daily-checkin 创建本地计划任务
# 关键：StartWhenAvailable —— 若 00:05 时点机器关机/休眠，开机/登录后自动补跑
# 这是 Windows 原生的「错过计划即补跑」机制，比自写 catchup 钩子更可靠通用。
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

# 触发器：每日 00:05
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
    -Description 'Must 每日签到：00:05 触发；PC 关机日开机经 StartWhenAvailable 自动补跑。经 run-task 闸门去重/记状态。' -Force

Write-Host "OK: 已创建/更新计划任务 [$taskName]"
Write-Host "验证："
& schtasks /Query /TN "$taskName" /V /FO LIST 2>$null | Select-Object -First 12
