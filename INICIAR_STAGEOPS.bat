@echo off
title StageOPS - Rental Operations Platform
cd /d "%~dp0"
if not exist package.json (echo ERROR: package.json not found.&pause&exit /b 1)
start "StageOPS Server - KEEP OPEN" cmd /k "cd /d ""%~dp0"" && npm.cmd run dev"
timeout /t 6 /nobreak >nul
start "" "http://localhost:8080/"
exit
