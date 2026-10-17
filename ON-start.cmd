@echo off
rem  Turn the Windows mobile hotspot ON (no console window)
setlocal
set "PS1=%~dp0HotspotSwitch.ps1"
if not exist "%PS1%" goto missing
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%" -On
exit /b 0

:missing
echo.
echo  [ERROR] HotspotSwitch.ps1 not found next to this file.
echo.
pause
exit /b 1
