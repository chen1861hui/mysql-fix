@echo off
rem Double-click to back up mysql\data and replace it from mysql\backup.
rem Extra args are passed through, e.g.:  fix-mysql.bat -SkipDb klc
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-mysql.ps1" %*
pause
