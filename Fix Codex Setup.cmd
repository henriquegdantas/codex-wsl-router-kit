@echo off
rem Fix Codex Setup
setlocal
set "_D="
if defined CODEX_WSL_DISTRO set "_D=-d %CODEX_WSL_DISTRO%"
wsl.exe %_D% --cd "%~dp0." -- bash scripts/check.sh --fix
echo.
pause
