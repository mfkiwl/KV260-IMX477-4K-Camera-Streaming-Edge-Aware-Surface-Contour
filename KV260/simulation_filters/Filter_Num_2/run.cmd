@echo off
setlocal
pushd "%~dp0"
set "PIC2_INPUT=%~1"
set "PIC2_PROFILE=%~2"
vsim -c -do sim/run_questa.do
set "sim_status=%ERRORLEVEL%"
popd
exit /b %sim_status%
