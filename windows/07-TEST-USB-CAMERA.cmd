@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& (Join-Path (Get-Location) '07-usb-camera-test.ps1')"
set "rc=%ERRORLEVEL%"
echo.
if "%rc%"=="0" (echo USB camera and media checks passed.) else (echo Camera check failed. Use menu D for diagnostics.)
pause
exit /b %rc%
