@echo off
rem Uninstall Codex Router
setlocal
set "_D="
if defined CODEX_WSL_DISTRO set "_D=-d %CODEX_WSL_DISTRO%"
wsl.exe %_D% --cd "%~dp0." -- bash scripts/uninstall.sh 
echo.
pause
