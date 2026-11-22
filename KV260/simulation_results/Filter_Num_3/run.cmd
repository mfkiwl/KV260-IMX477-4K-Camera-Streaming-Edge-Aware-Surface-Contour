@echo off
setlocal
cd /d "%~dp0"
set "DESIGNER_PROFILE=%~1"
if "%DESIGNER_PROFILE%"=="" set "DESIGNER_PROFILE=3"
set "DESIGNER_INPUT=%~2"
if "%DESIGNER_INPUT%"=="" set "DESIGNER_INPUT=PIC1"
vsim -c -do sim/run_questa.do
exit /b %errorlevel%
