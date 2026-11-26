@echo off
rem Dump all databases, rebuild a fresh mysql\data folder, import back. MySQL must be running.
rem Extra args are passed through, e.g.:  rebuild-mysql.bat -SkipDb klc_test
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rebuild-mysql.ps1" %*
pause
