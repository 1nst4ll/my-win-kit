@echo off
rem Launcher for the workstation installer - safe on fresh Windows.
rem Bypasses ExecutionPolicy for this run only (no system change).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dpn0.ps1"
