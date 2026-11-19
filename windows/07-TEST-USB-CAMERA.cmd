@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp007-usb-camera-test.ps1" %*
set "rc=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %rc%
