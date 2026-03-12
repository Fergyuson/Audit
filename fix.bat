@echo off
chcp 65001 >nul 2>&1
echo.
echo   Lighthouse Fix Tool
echo   ====================
echo.
echo   Projects dir: %~dp0projects
echo   Presets: desktop + mobile
echo   Fixes: fonts, meta, a11y, images, assets
echo   Audit: before + after with diff
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix.ps1" -ProjectsDir "%~dp0projects" %*

echo.
pause
