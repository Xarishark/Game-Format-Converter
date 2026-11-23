@echo off
rem Command-line launcher: waits for Game Format Converter Enhanced and passes its exit code on. Usage: chdm game.chd --to pbp -o D:\out   (chdm --help lists everything)
set "GFC=%~dp0Game Format Converter Enhanced.exe"
if not exist "%GFC%" set "GFC=%~dp0Game Format Converter.exe"
start "" /wait /b "%GFC%" cli %*
exit /b %errorlevel%
