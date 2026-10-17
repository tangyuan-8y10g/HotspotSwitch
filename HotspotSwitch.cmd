@echo off
rem ===================================================================
rem  HotspotSwitch launcher (opens the GUI panel)
rem  Keep this file ASCII-only. Do not save as UTF-8 with non-ASCII text.
rem ===================================================================
setlocal
set "PS1=%~dp0HotspotSwitch.ps1"
if not exist "%PS1%" goto missing
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%"
exit /b 0

:missing
echo.
echo  [ERROR] HotspotSwitch.ps1 not found next to this file.
echo  Make sure you extracted the whole folder.
echo.
pause
exit /b 1
