@echo off
rem ---------------------------------------------------------------------------
rem  open-aws-console - Windows double-click launcher
rem
rem  Runs the PowerShell script with -ExecutionPolicy Bypass so it works on a
rem  stock Windows installation where running .ps1 files is blocked by default.
rem
rem  Install: right-click this file -> Send to -> Desktop (create shortcut),
rem           then double-click the shortcut whenever you need the console.
rem ---------------------------------------------------------------------------

setlocal

set "SCRIPT_DIR=%~dp0"

rem Prefer PowerShell 7+ when present, fall back to Windows PowerShell 5.1.
set "PS_EXE=powershell.exe"
where /q pwsh.exe && set "PS_EXE=pwsh.exe"

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass ^
    -File "%SCRIPT_DIR%open-aws-console.ps1" %*

set "EXIT_CODE=%ERRORLEVEL%"

rem Keep the window open on failure so the error is readable after a double-click.
if not "%EXIT_CODE%"=="0" (
    echo.
    echo open-aws-console failed with exit code %EXIT_CODE%.
    pause
)

endlocal & exit /b %EXIT_CODE%
