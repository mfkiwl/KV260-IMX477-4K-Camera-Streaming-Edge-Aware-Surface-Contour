@echo off
setlocal
cd /d "%~dp0"
echo Starting Questa/ModelSim in "%CD%"
echo For a quick 128 x 72 test, use: run.cmd smoke
if "%~1"=="" (
    vsim -c -do sim/run_questa.do
) else (
    vsim -c -do "do sim/run_questa.do {%~1}"
)
exit /b %errorlevel%
