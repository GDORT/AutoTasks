# ⚠️ DEPRECATED / 已废弃 —— 勿运行本脚本
# 本脚本会重新创建 6 个 Windows 计划任务（AutoCheckin.WorkBuddy/TraeWork × {0010,0910,2010}），
# 那正是统一任务层(AutoTasks + run-task)要消除的"重复触发"。2026-09-27 已将它们 Unregister-ScheduledTask 注销。
# 日常签到现由 WorkBuddy 自动化 31e98286 单一触发(must/ai)，经 run-task --run daily-checkin 领号/记终态。
# 如确需本地计划任务兜底，请改用 run-task 的 --catchup 机制，而非本脚本。
#
# Register AutoCheckin daily scheduled tasks (WorkBuddy & TRAE) - v2
# Uses Register-ScheduledTask with StartWhenAvailable: if the machine is
# asleep/off at trigger time, the task runs as soon as possible after wake.
# Idempotent: re-running overwrites the 6 tasks in place. No admin needed.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\register_tasks.ps1

$Root = "D:\AIAppData\AutoTasks\AutoCheckin"
$wbCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Root\WorkBuddy\workbuddy_checkin.ps1`""
$trCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Root\TraeWork\trae_task.ps1`""

$targets = @(
    @{ Name = "AutoCheckin.WorkBuddy"; Cmd = $wbCmd; Desc = "WorkBuddy daily checkin (wrapper v2: log-guard -> ensure client -> skill script)" },
    @{ Name = "AutoCheckin.TRAE";      Cmd = $trCmd; Desc = "TRAE daily checkin (trae_task.ps1: log-guard -> checkin.js)" }
)

$times = @("00:10", "09:10", "20:10")

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$results = @()
foreach ($t in $targets) {
    foreach ($time in $times) {
        $suffix = $time -replace ":", ""
        $tn = "$($t.Name).$suffix"
        try {
            $trigger = New-ScheduledTaskTrigger -Daily -At $time
            $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ($t.Cmd -replace '^powershell.exe ', '')
            Register-ScheduledTask -TaskName $tn -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Description $t.Desc -Force | Out-Null
            $results += "OK      $tn @ $time"
        } catch {
            $results += "FAILED  $tn @ $time : $($_.Exception.Message)"
        }
    }
}

$out = "$env:TEMP\register_result.txt"
@("register @ $(Get-Date)") + $results | Out-File $out -Encoding utf8
Get-Content $out -Encoding UTF8 | Write-Output
