@echo off
setlocal DisableDelayedExpansion
rem Double-click this file, or pass --port / --no-browser from a terminal.
rem PANGO_PYTHON may name a specific python.exe (without extra arguments).
if defined PANGO_PYTHON goto custom
rem Purpose: prefer the project-local optional OpenCV runtime when installed.
if exist "%~dp0..\build\calibration-venv\Scripts\python.exe" (
  set "PANGO_PYTHON=%~dp0..\build\calibration-venv\Scripts\python.exe"
  goto custom
)
py -3.12 -I -B -c "import sys; sys.exit(sys.version_info[:2] < (3, 12))" >nul 2>nul
if not errorlevel 1 goto py312
py -3 -I -B -c "import sys; sys.exit(sys.version_info[:2] < (3, 12))" >nul 2>nul
if not errorlevel 1 goto py3
python -I -B -c "import sys; sys.exit(sys.version_info[:2] < (3, 12))" >nul 2>nul
if not errorlevel 1 goto python
:missing
echo [Pango] Python 3.12 or newer was not found.
echo Install Python with the Python launcher or PATH option, then retry.
echo You can also set PANGO_PYTHON to the full path of python.exe.
set "PANGO_EXIT=2"
goto finish
:custom
"%PANGO_PYTHON%" -I -B -c "import sys; sys.exit(sys.version_info[:2] < (3, 12))" >nul 2>nul
if errorlevel 1 goto missing
"%PANGO_PYTHON%" -X utf8 -B "%~dp0web.py" %*
set "PANGO_EXIT=%ERRORLEVEL%"
goto finish
:py312
py -3.12 -X utf8 -B "%~dp0web.py" %*
set "PANGO_EXIT=%ERRORLEVEL%"
goto finish
:py3
py -3 -X utf8 -B "%~dp0web.py" %*
set "PANGO_EXIT=%ERRORLEVEL%"
goto finish
:python
python -X utf8 -B "%~dp0web.py" %*
set "PANGO_EXIT=%ERRORLEVEL%"
:finish
if not "%PANGO_EXIT%"=="0" if not "%PANGO_NO_PAUSE%"=="1" pause
exit /b %PANGO_EXIT%
