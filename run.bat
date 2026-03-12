@echo off
chcp 65001 >nul 2>&1
echo.
echo   Lighthouse Audit Tool
echo   =====================
echo.
echo   Projects dir: %~dp0projects
echo   Presets: desktop + mobile
echo   Browsers: chrome + edge
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0audit.ps1" -ProjectsDir "%~dp0projects" %*

echo.
pause
