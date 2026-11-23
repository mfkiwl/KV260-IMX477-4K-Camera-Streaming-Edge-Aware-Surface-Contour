@echo off
setlocal
cd /d "%~dp0"
if "%~1"=="" (
    vsim -c -do sim/run_questa.do
) else (
    vsim -c -do "do sim/run_questa.do {%~1}"
)
exit /b %errorlevel%
