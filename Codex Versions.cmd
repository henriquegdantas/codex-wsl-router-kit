@echo off
rem Codex Versions
setlocal
set "_D="
if defined CODEX_WSL_DISTRO set "_D=-d %CODEX_WSL_DISTRO%"
wsl.exe %_D% --cd "%~dp0." -- bash scripts/codex-override.sh status
echo.
pause
