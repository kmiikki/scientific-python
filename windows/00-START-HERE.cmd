@echo off
setlocal
cd /d "%~dp0"

rem Keep the PowerShell command ASCII-only. PowerShell resolves the current
rem directory internally, so a Unicode package path is not passed with -File.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& (Join-Path (Get-Location) '00-menu.ps1')"
set "rc=%ERRORLEVEL%"

if not "%rc%"=="0" (
    echo.
    echo The Scientific Python launcher ended with error code %rc%.
    pause
)

exit /b %rc%
