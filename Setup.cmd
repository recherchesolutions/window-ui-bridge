@echo off
rem Double-click launcher for Setup.ps1. Extra arguments pass through, e.g. Setup.cmd -RegisterClaude
rem The execution-policy bypass covers this setup process only; Group Policy settings still apply.
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1" %*
set rc=%errorlevel%
if %rc% neq 0 (echo.&echo Setup failed. See the message above.) else (echo.&echo Setup complete. Optional check: .venv\Scripts\python.exe smoke_test.py)
if "%~1"=="" pause
exit /b %rc%
