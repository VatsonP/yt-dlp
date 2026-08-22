@echo off
setlocal

:: Working directory
set "WORK_DIR=d:\Trainings\yt-dlp"
cd /d "%WORK_DIR%"

:: Preferred output directory with fallback to the working directory
set "PREFERRED_OUTPUT=D:\TempD"
set "OUTPUT_DIR=%WORK_DIR%"
if exist "%PREFERRED_OUTPUT%\" set "OUTPUT_DIR=%PREFERRED_OUTPUT%"

:loop
cls
echo =====================================================
echo    YT-DLP Downloader (Kinescope and others)
echo =====================================================
echo.
echo [INFO] Working folder  : %WORK_DIR%
echo [INFO] Preferred folder: %PREFERRED_OUTPUT%
echo [INFO] Output folder   : %OUTPUT_DIR%
echo.

:: Ask for the video URL
set "vid_url="
set /p vid_url="Paste the video URL and press Enter: "

:: If no URL was entered, return to the beginning
if not defined vid_url goto loop

echo.
echo [INFO] Starting download...
echo.

:: Keep the original download parameters and save the final file to OUTPUT_DIR
yt-dlp.exe --js-runtimes node -f "bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best" -o "%OUTPUT_DIR%\%%(title)s [%%(id)s].%%(ext)s" "%vid_url%"

if errorlevel 1 (
    echo.
    echo [ERROR] Download failed.
    echo.
) else (
    echo.
    echo [DONE] Download completed successfully.
    echo [INFO] Saved to: %OUTPUT_DIR%
    echo.
)

:: Pause before returning to the main prompt
pause
goto loop
