@echo off
rem Compatibility entry point; scratch is exclusively reserved by the worker.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0science-opencl-worker.ps1" -Action Activate
exit /b %errorlevel%
