# ============================================================
# register_scheduler.ps1 - 为 AutoTasks 的本地计划任务统一注册入口
#
# 为什么需要本地计划任务（2026-10-09 定）：
#   WorkBuddy 自动化跑在**沙箱**里，会拦截子进程 spawn 与 GUI 调用。本仓库任务依赖子进程：
#     · cdrive-monthly → scan.ps1 用 ProcessStartInfo 启 es.exe（Everything IPC，整盘分析）
#                        + check.ps1 用 WScript.Shell.Popup 弹窗告警
#     · chore-scan     → scan_changes.py 等子链路
#   沙箱拦截 => 自动化触发时**必然降级**。故把「需要权限的任务」改由本地计划任务触发；
#   WorkBuddy 自动化仅作可见性入口。
#
# 幂等：重复运行以 -Force 原地覆盖。
# 用法（需提权 / 管理员运行，因 agent 不能自绑计划任务）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AIAppData\AutoTasks\register_scheduler.ps1"
#   powershell -NoProfile -ExecutionPolicy Bypass -File "D:\AIAppData\AutoTasks\register_scheduler.ps1" -Only cdrive-monthly
#
# 2026-10-10 修复：
#   [FIX-A2] cdrive-monthly 原写成 -Daily，与 task-registry.json 的 FREQ=MONTHLY;BYMONTHDAY=1,15
#            矛盾（实际每天 09:00 触发）。New-ScheduledTaskTrigger **没有** Monthly 参数集
#            （实测只有 Once/Daily/Weekly/Startup/Logon），故月内多日走：
#              首选 分配 CIM 触发器 DaysOfMonth；失败则回退 schtasks.exe /SC MONTHLY /D 1,15。
#   注：本文件含非 ASCII 字符，必须保存为 UTF-8 **带 BOM**；否则 Windows PowerShell 5.1 会按
#       ANSI(CP936) 解码且可能直接解析失败（同时正文避免出现 U+FF1F 等会解码成 ASCII 标点的全角符号）。
# ============================================================
param(
    [string[]]$Only = @()      # 可选：只为指定任务注册（留空 = 全部）
)
$ErrorActionPreference = 'Stop'
$AutoTasks = Split-Path -Parent $MyInvocation.MyCommand.Definition
$runTask   = Join-Path $AutoTasks 'run-task.ps1'

# ---- 任务清单：Name / 触发时间 / 可选 DaysOfMonth / 说明----
# DaysOfMonth 非空 => 每月指定日；为空 => 每日。
$PLAN = @(
    @{
        Name    = 'chat-sync'
        At      = '00:05'
        Desc    = 'OBDOC 全部 AI 对话同步「本地主源」：每日 00:05 调用 60_inbox/AIChatData/同步全部对话.bat，刷新各平台对话成品。TRAE 未运行时会由平台入口自动启动，已运行则不关闭；只导出，不做差事判断、不提交 git。'
    },
    @{
        Name    = 'daily-checkin'
        At      = '00:05'
        Desc    = 'Must 每日签到「本地兜底触发」：00:05（与 WorkBuddy 自动化同点，不依赖 WB 是否在运行）；关机日开机经 StartWhenAvailable 补跑；经 run-task 文件锁+去重，主源已成功时自动跳过。'
    },
    @{
        Name         = 'cdrive-monthly'
        At           = '09:00'
        DaysOfMonth  = @(1, 15)
        Desc         = 'C盘整盘巡检「本地主源」：每月 1/15 09:00。scan.ps1 需 spawn es.exe 做整盘分析、check.ps1 需弹窗告警，沙箱自动化会拦截，故必须本地计划任务触发（自动化 33c42a3b 仅作可见性入口，会降级）。走 run-task 记录日志与终态。'
    },
    @{
        Name    = 'chore-scan'
        At      = '00:10'
        Desc    = '差事自动扫描提交「本地主源」：需 spawn scan_changes.py 子链路，沙箱自动化会拦截/降级。走 run-task 记录日志与终态；git 只本地提交、绝不 push。'
    },
    @{
        Name    = 'token-sync-am'
        At      = '00:00'
        Desc    = 'TRAE token 用量同步到 TokenTracker（原云端自动化 10a77585 的 00:00 那一次，本地化）。sync 需写 C:\Users\GD\.tokentracker，沙箱内会被 EPERM 拦截，故必须由本地计划任务触发。'
    },
    @{
        Name    = 'token-sync-pm'
        At      = '12:00'
        Desc    = 'TRAE token 用量同步到 TokenTracker（原云端自动化 10a77585 的 12:00 那一次，本地化）。sync 需写 C:\Users\GD\.tokentracker，沙箱内会被 EPERM 拦截，故必须由本地计划任务触发。'
    }
)

$targets = if ($Only.Count -gt 0) { $PLAN | Where-Object { $Only -contains $_.Name } }
           else { $PLAN }

if ($targets.Count -eq 0) {
    Write-Error "没有匹配的任务名。可用：$($PLAN.Name -join ', ')"
    exit 1
}

foreach ($t in $targets) {
    $taskName = "AutoTasks.$($t.Name)"

    # 动作：经 wscript+vbs 以完全无窗口方式调用 run-task 闸门（executorType=shell 时 run-task 真正执行执行器）
    # [FIX-W2 2026-10-25] 直接注册 powershell.exe 必闪窗口抢焦点：powershell 是 console 子系统程序，
    #   Task Scheduler 启动它时 Windows 先创建并显示控制台窗口，-WindowStyle Hidden 要等 PowerShell
    #   启动后才执行隐藏（本机实测间隔约 240ms：HWND=1443058 可见 -> HWND=0 隐藏）。改走
    #   wscript.exe（GUI 子系统宿主，自身不创建控制台）+ hidden-run.vbs 内 WScript.Shell.Run(cmd,0,False)：
    #   SW_HIDE 经 STARTUPINFO 在进程创建时生效，控制台从创建起即不可见，无焦点抢占。
    $vbs = Join-Path $AutoTasks 'hidden-run.vbs'
    $action = New-ScheduledTaskAction `
        -Execute 'wscript.exe' `
        -Argument "`"$vbs`" $($t.Name)" `
        -WorkingDirectory $AutoTasks

    # 触发器：有 DaysOfMonth => 每月指定日；否则每日固定时刻
    $useSchtasks = $false
    if ($t.ContainsKey('DaysOfMonth') -and $t.DaysOfMonth.Count -gt 0) {
        $trigger = $null
        try {
            $tr = New-ScheduledTaskTrigger -Daily -At $t.At
            $tr.DaysOfMonth = [int[]]$t.DaysOfMonth
            $tr.DaysInterval = 0
            $trigger = $tr
        } catch {
            Write-Host "  提示：CIM 触发器不支持 DaysOfMonth，改用 schtasks.exe 注册每月触发（$($_.Exception.Message)）"
            $useSchtasks = $true
        }
    } else {
        $trigger = New-ScheduledTaskTrigger -Daily -At $t.At
    }

    if ($useSchtasks) {
        # schtasks 版本：/SC MONTHLY /D 1,15；动作仍是 run-task 闸门；/F 覆盖
        $trCmd = 'wscript.exe "' + (Join-Path $AutoTasks 'hidden-run.vbs') + '" ' + $t.Name
        & schtasks.exe /Create /F /TN $taskName /SC MONTHLY /D ($t.DaysOfMonth -join ',') /ST $t.At /TR $trCmd | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "schtasks 注册失败（$taskName, exit=$LASTEXITCODE）"
            exit 1
        }
        Write-Host "OK: 已创建/更新计划任务 [$taskName]  每月 $($t.DaysOfMonth -join '/') 日 $($t.At)  (via schtasks)"
        continue
    }

    # 设置：错过即补跑 + 电池下不中断 + 单次最多 30 分钟 + 同名实例忽略
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    # 主体：当前用户、交互登录时运行（StartWhenAvailable 在登录后补跑）
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Description $t.Desc -Force | Out-Null

    $sched = "每日 $($t.At)"
    if ($t.ContainsKey('DaysOfMonth') -and $t.DaysOfMonth.Count -gt 0) {
        $sched = "每月 $($t.DaysOfMonth -join '/') 日 $($t.At)"
    }
    Write-Host "OK: 已创建/更新计划任务 [$taskName]  $sched"
}

Write-Host ""
Write-Host "验证："
foreach ($t in $targets) {
    $taskName = "AutoTasks.$($t.Name)"
    $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    if ($info) {
        $tk = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        $dom = ''
        try { if ($tk.Triggers[0].DaysOfMonth) { $dom = ' days=' + ($tk.Triggers[0].DaysOfMonth -join ',') } } catch {}
        Write-Host ("  {0,-28} STATE={1}  NEXT={2}  LAST={3}  RESULT={4}{5}" -f `
            $taskName, $tk.State, $info.NextRunTime, $info.LastRunTime, $info.LastTaskResult, $dom)
    }
    # schtasks 注册的任务查不到 CIM 信息，用 schtasks 兜底显示
    else {
        $q = & schtasks.exe /Query /TN $taskName /FO LIST 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "  $taskName (via schtasks):"; $q | ForEach-Object { Write-Host "    $_" } }
        else { Write-Host "  $taskName 未注册" }
    }
}
