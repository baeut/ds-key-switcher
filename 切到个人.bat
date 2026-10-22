@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0switch-core.ps1" -Profile personal -RestartClients
if errorlevel 1 (
  echo.
  echo [FAILED] switch to personal key
) else (
  echo.
  echo [OK] switched to personal key, running clients restarted
)
echo.
pause