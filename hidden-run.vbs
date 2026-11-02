' hidden-run.vbs — 让计划任务以完全无窗口的方式执行 run-task.ps1
' 背景（2026-10-25 实测）：powershell.exe 是 console 子系统程序，Task Scheduler
' 启动它时 Windows 必然先创建并显示一个控制台窗口，之后 PowerShell 才能执行
' -WindowStyle Hidden 把它藏掉——中间约 0.2~0.5 秒的可见窗口会抢占用户焦点。
' 本机实测样本：23:26:31.064 HWND=1443058(可见) -> 23:26:31.305 HWND=0(隐藏)。
' wscript.exe 是 GUI 子系统宿主，自身不创建控制台；再用 WScript.Shell.Run
' 的第二个参数 0(SW_HIDE) 启动 powershell，全程无窗口、无焦点抢占。
'
' 用法（计划任务 Action）：
'   Program/script : wscript.exe
'   Add arguments  : "D:\AIAppData\AutoTasks\hidden-run.vbs" <task-name>
' 例：wscript.exe "D:\AIAppData\AutoTasks\hidden-run.vbs" chat-sync
'
' 排障日志：每步写 hidden-run.log（2026-10-25 加，用于定位"任务显示已执行但
' run-task 无日志"的问题；定位完成后可保留，每次运行仅几行）。
'
' 2026-10-26 语义对齐修复（与旧注册方式 powershell.exe 直启逐项比对后）：
'   1) bWaitOnReturn 由 False 改 True：wscript 阻塞到 powershell 退出为止，
'      使计划任务的 ExecutionTimeLimit(PT30M) 重新生效、完成时间反映真实耗时。
'   2) 末尾 WScript.Quit rc：把 run-task.ps1 的退出码(0 成功 / 1,3 失败 /
'      2 用法或任务不存在)透传为 wscript 退出码，使 LastTaskResult 恢复语义。
'      改前 wscript 恒退 0，引擎看到的一律是"成功"，失败任务会被静默吞掉。
'   3) powershell.exe 改用系统固定绝对路径（v1.0 是 Windows 内置 PowerShell 的
'      固定位置，所有 Windows 版本一致）：避免调用方 PATH 残缺时解析失败
'      （2026-10-26 实测：手工会话 PATH 异常时相对名启动失败码与真实失败码
'      都是 1，会造成"假一致"，绝对路径消除这类歧义）。

Option Explicit

Dim logPath
logPath = "D:\AIAppData\AutoTasks\hidden-run.log"

' 2026-11-02 修复：两个任务同一分钟触发时（daily-checkin 与 chat-sync 都是 00:05:05），
' 两个 wscript 实例会同时 OpenTextFile(ForAppending) 同一文件，失败方被 On Error Resume Next
' 静默吞掉 → 日志丢行（当日实证：00:05 只有 chat-sync 的 BEGIN，daily-checkin 整段缺失，
' 极易误判成「任务没跑」）。改为带短重试，写不进去才放弃。
Sub LogLine(msg)
    Dim fso, f, i
    Set fso = CreateObject("Scripting.FileSystemObject")
    For i = 1 To 6
        On Error Resume Next
        Set f = fso.OpenTextFile(logPath, 8, True)
        If Err.Number = 0 Then
            f.WriteLine Now & "  " & msg
            f.Close
            Set f = Nothing
            On Error GoTo 0
            Exit Sub
        End If
        Err.Clear
        Set f = Nothing
        WScript.Sleep 25
    Next
    On Error GoTo 0
End Sub

LogLine "BEGIN"

Dim args, taskName, shell, cmd, rc
Set args = WScript.Arguments
LogLine "argc=" & args.Count

If args.Count < 1 Then
    LogLine "QUIT: no-args"
    WScript.Quit 2
End If

taskName = args(0)
LogLine "taskName=" & taskName

Dim re
Set re = New RegExp
re.Pattern = "^[A-Za-z0-9_-]+$"
re.Global = False
If Not re.Test(taskName) Then
    LogLine "QUIT: bad-taskname"
    WScript.Quit 3
End If
LogLine "regexp-ok"

Set shell = CreateObject("WScript.Shell")
cmd = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""D:\AIAppData\AutoTasks\run-task.ps1"" --run " & taskName
LogLine "BEFORE-RUN"

On Error Resume Next
rc = shell.Run(cmd, 0, True)
If Err.Number <> 0 Then
    LogLine "RUN-ERROR err=" & Err.Number & " desc=" & Err.Description
    Err.Clear
    WScript.Quit 1
End If
LogLine "AFTER-RUN rc=" & rc
On Error GoTo 0

' 退出码透传：与旧注册方式(powershell.exe 直启)的 LastTaskResult 语义对齐
If IsNumeric(rc) Then
    WScript.Quit CInt(rc)
Else
    WScript.Quit 1
End If
