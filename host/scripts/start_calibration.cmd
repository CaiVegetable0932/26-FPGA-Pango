@echo off
setlocal DisableDelayedExpansion
rem Share the existing Python selection and service; open calibration directly.
call "%~dp0start_web.cmd" --page calibration %*
exit /b %ERRORLEVEL%
