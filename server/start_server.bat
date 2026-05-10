@echo off
REM Start the Claude Code Godot bridge server.
REM Usage: start_server.bat [port]   (default port: 9876)

where python >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo Error: python is required but not found.
    pause
    exit /b 1
)

where claude >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo Warning: 'claude' CLI not found in PATH.
    echo Install Claude Code from https://claude.ai/code
)

python "%~dp0claude_server.py" %*
pause
