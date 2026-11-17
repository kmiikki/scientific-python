@echo off
setlocal DisableDelayedExpansion
if not defined SCIENCE_OCL_ACTIVE goto already
set "SCIENCE_OCL_RESULT="
for /f "usebackq delims=" %%D in (`powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CONDA_PREFIX%\Library\etc\OpenCL\vendors\science-opencl-worker.ps1" -Action Deactivate`) do set "SCIENCE_OCL_RESULT=%%D"
if not defined SCIENCE_OCL_RESULT goto failed
if not exist "%SCIENCE_OCL_RESULT%\apply.cmd" goto failed
endlocal & call "%SCIENCE_OCL_RESULT%\apply.cmd"
exit /b %errorlevel%
:already
endlocal & exit /b 0
:failed
endlocal & exit /b 1
