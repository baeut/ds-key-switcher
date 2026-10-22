@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0switch-core.ps1" -Profile company -RestartClients
if errorlevel 1 (
  echo.
  echo [FAILED] switch to company key
) else (
  echo.
  echo [OK] switched to company key, running clients restarted
)
echo.
pause