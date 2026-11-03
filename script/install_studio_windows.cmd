@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_studio_windows.ps1" %*
if errorlevel 1 (
    echo Ada Studio installation failed.
    pause
    exit /b 1
)
