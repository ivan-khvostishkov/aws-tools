@echo off
rem ---------------------------------------------------------------------------
rem  update-route53 - Windows startup launcher
rem
rem  Runs the PowerShell script with -ExecutionPolicy Bypass so it works on a
rem  stock Windows installation where running .ps1 files is blocked by default.
rem  Output is appended to %LOCALAPPDATA%\aws-tools\update-route53.log because
rem  nobody is watching the console at startup.
rem
rem  Install: put a shortcut to this file in
rem           shell:startup  (%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup)
rem ---------------------------------------------------------------------------

setlocal

set "SCRIPT_DIR=%~dp0"
set "LOG_DIR=%LOCALAPPDATA%\aws-tools"
set "LOG_FILE=%LOG_DIR%\update-route53.log"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" 2>nul

rem Prefer PowerShell 7+ when present, fall back to Windows PowerShell 5.1.
set "PS_EXE=powershell.exe"
where /q pwsh.exe && set "PS_EXE=pwsh.exe"

rem The echoes are parenthesised because a bare `... %VAR%>>file` makes cmd.exe
rem read a trailing digit as a stream number (`1>>`) and swallow it.
(echo [%DATE% %TIME%] update-route53 starting)>>"%LOG_FILE%"

"%PS_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
    -File "%SCRIPT_DIR%update-route53.ps1" %* >>"%LOG_FILE%" 2>&1

set "EXIT_CODE=%ERRORLEVEL%"
(echo [%DATE% %TIME%] update-route53 finished with exit code %EXIT_CODE%)>>"%LOG_FILE%"

endlocal & exit /b %EXIT_CODE%
