@echo off
setlocal

REM ============================================
REM TRAE SOLO CN daily auto check-in launcher
REM Usage:
REM   run_checkin.cmd          run manually, show result and stay open
REM   run_checkin.cmd -q       silent (used by Task Scheduler), exits immediately
REM Result is printed and also logged by checkin.js into ..\logs\workbuddy_trae_checkin.log
REM ============================================

set "NODE_EXE=C:\Users\GD\AppData\Roaming\TRAE SOLO CN\ModularData\ai-agent\vm\tools\node\node.exe"
if not exist "%NODE_EXE%" set "NODE_EXE=D:\Programs\TRAE SOLO CN\TRAE SOLO CN.exe"

if not exist "%NODE_EXE%" (
  echo ERROR: Node runtime not found. Edit NODE_EXE in run_checkin.cmd.
  pause
  exit /b 1
)

if /i "%~1"=="-q" (
  "%NODE_EXE%" "%~dp0checkin.js"
  exit /b %errorlevel%
)

"%NODE_EXE%" "%~dp0checkin.js"
echo.
echo Press any key to close...
pause>nul
endlocal