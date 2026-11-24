@echo off
setlocal
cd /d "%~dp0"
if "%~1"=="" (
    vsim -c -do sim/questa.do
) else (
    vsim -c -do "do sim/questa.do {%~1}"
)
exit /b %errorlevel%
