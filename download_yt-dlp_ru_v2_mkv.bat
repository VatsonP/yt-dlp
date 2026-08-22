@echo off
setlocal EnableExtensions DisableDelayedExpansion

:: ================================================================
:: YT-DLP Downloader - Original + Russian audio
:: Version: 2026-08-21-v2
:: ================================================================

:: Working directory containing yt-dlp.exe and ffmpeg.exe
set "WORK_DIR=d:\Trainings\yt-dlp"
cd /d "%WORK_DIR%"
if errorlevel 1 (
    echo [ERROR] Cannot open working folder: %WORK_DIR%
    pause
    exit /b 1
)

:: Preferred output folder. If it does not exist, use the working folder.
set "PREFERRED_OUTPUT=D:\TempD"
set "OUTPUT_DIR=%WORK_DIR%"
if exist "%PREFERRED_OUTPUT%\" set "OUTPUT_DIR=%PREFERRED_OUTPUT%"

:loop
cls
echo =====================================================
echo    YT-DLP Downloader - Original + Russian audio
echo    Version: 2026-08-21-v2
echo =====================================================
echo.
echo [INFO] Script file     : %~f0
echo [INFO] Working folder  : %WORK_DIR%
echo [INFO] Preferred folder: %PREFERRED_OUTPUT%
echo [INFO] Output folder   : %OUTPUT_DIR%
echo.

set "vid_url="
set /p vid_url="Paste the video URL and press Enter: "
if not defined vid_url goto loop

if not exist "yt-dlp.exe" (
    echo [ERROR] yt-dlp.exe was not found in: %CD%
    pause
    goto loop
)

if not exist "ffmpeg.exe" (
    echo [ERROR] ffmpeg.exe was not found in: %CD%
    pause
    goto loop
)

:: Re-check the preferred folder before every download in case it was
:: created or removed while this script was running.
set "OUTPUT_DIR=%WORK_DIR%"
if exist "%PREFERRED_OUTPUT%\" set "OUTPUT_DIR=%PREFERRED_OUTPUT%"
echo.
echo [INFO] Final output folder: %OUTPUT_DIR%

set "WORK=%TEMP%\yt-dlp-ru-%RANDOM%-%RANDOM%"
mkdir "%WORK%" >nul 2>&1
set "META=%WORK%\metadata.json"
set "ORIG_FILE=%WORK%\orig_lang.txt"
set "RU_ID_FILE=%WORK%\ru_id.txt"
set "NAME_FILE=%WORK%\final_name.txt"

:: -----------------------------------------------------------------
:: 1. Read YouTube metadata once and determine:
::    - original audio language
::    - best available Russian audio format
::    Russian may be audio-only or embedded in an HLS video+audio stream.
:: -----------------------------------------------------------------
echo.
echo [INFO] Checking available audio tracks...
yt-dlp.exe --js-runtimes node --no-playlist --skip-download --dump-single-json "%vid_url%" > "%META%"
if errorlevel 1 (
    echo [ERROR] Failed to retrieve video metadata.
    rmdir /s /q "%WORK%" >nul 2>&1
    pause
    goto loop
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$j=Get-Content -LiteralPath '%META%' -Raw -Encoding UTF8 | ConvertFrom-Json;" ^
  "$a=@($j.formats | Where-Object { $_.acodec -and $_.acodec -ne 'none' -and $_.language });" ^
  "$orig=@($a | Where-Object { (($_.format -as [string]) -match '(?i)original') -or (($_.format_note -as [string]) -match '(?i)original') } | Sort-Object @{Expression={[double]($_.language_preference)};Descending=$true}, @{Expression={[double]($_.abr)};Descending=$true} | Select-Object -First 1);" ^
  "if(-not $orig){$orig=@($a | Sort-Object @{Expression={[double]($_.language_preference)};Descending=$true}, @{Expression={[double]($_.abr)};Descending=$true} | Select-Object -First 1)};" ^
  "$origLang=if($orig){[string]$orig[0].language}else{''};" ^
  "$ru=@($a | Where-Object { ([string]$_.language) -match '(?i)^ru(?:-|$)' });" ^
  "$ruAudioOnly=@($ru | Where-Object { $_.vcodec -eq 'none' });" ^
  "if($ruAudioOnly.Count -gt 0){$bestRu=$ruAudioOnly | Sort-Object @{Expression={if($_.ext -eq 'm4a'){1}else{0}};Descending=$true}, @{Expression={[double]($_.abr)};Descending=$true}, @{Expression={[double]($_.tbr)};Descending=$true} | Select-Object -First 1}" ^
  "elseif($ru.Count -gt 0){$bestRu=$ru | Sort-Object @{Expression={if(([string]$_.acodec) -match 'mp4a\.40\.2'){2}elseif(([string]$_.acodec) -match 'mp4a\.40\.5'){0}else{1}};Descending=$true}, @{Expression={if($_.height){[double]$_.height}else{99999}};Descending=$false}, @{Expression={[double]($_.tbr)};Descending=$true} | Select-Object -First 1}else{$bestRu=$null};" ^
  "$isOrigRu=($origLang -match '(?i)^ru(?:-|$)');" ^
  "$ruId=if((-not $isOrigRu) -and $bestRu){[string]$bestRu.format_id}else{''};" ^
  "$safe=[string]$j.title; [IO.Path]::GetInvalidFileNameChars() | ForEach-Object {$safe=$safe.Replace([string]$_,'_')}; $safe=$safe.Trim().TrimEnd('.'); if($safe.Length -gt 160){$safe=$safe.Substring(0,160).Trim()};" ^
  "$id=[string]$j.id;" ^
  "$origLang | Set-Content -LiteralPath '%ORIG_FILE%' -Encoding ASCII;" ^
  "$ruId | Set-Content -LiteralPath '%RU_ID_FILE%' -Encoding ASCII;" ^
  "($safe+' ['+$id+']') | Set-Content -LiteralPath '%NAME_FILE%' -Encoding Default;"

if errorlevel 1 (
    echo [ERROR] Failed to analyze the available audio tracks.
    rmdir /s /q "%WORK%" >nul 2>&1
    pause
    goto loop
)

set "ORIG_LANG="
set "RU_ID="
set "FINAL_BASE="
set /p ORIG_LANG=<"%ORIG_FILE%"
set /p RU_ID=<"%RU_ID_FILE%"
set /p FINAL_BASE=<"%NAME_FILE%"

echo [INFO] Original language: %ORIG_LANG%
if defined RU_ID (
    echo [INFO] Russian audio found. Format ID: %RU_ID%
) else (
    echo [INFO] A separate Russian track is not required or was not found.
)

:: -----------------------------------------------------------------
:: 2A. No extra Russian track required/available:
::     use the same download policy as the original BAT.
:: -----------------------------------------------------------------
if not defined RU_ID (
    echo.
    echo [INFO] Downloading video with the original audio track...
    yt-dlp.exe --js-runtimes node --no-playlist ^
        -f "bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best" ^
        --merge-output-format mp4 ^
        -o "%OUTPUT_DIR%\%%(title)s [%%(id)s].%%(ext)s" ^
        "%vid_url%"
    if errorlevel 1 (
        echo.
        echo [ERROR] Download failed.
    ) else (
        echo.
        echo [DONE] Download completed.
        echo [INFO] Saved to: %OUTPUT_DIR%
    )
    rmdir /s /q "%WORK%" >nul 2>&1
    echo.
    pause
    goto loop
)

:: -----------------------------------------------------------------
:: 2B. Russian exists and original is not Russian.
::     Download original video and Russian source separately.
:: -----------------------------------------------------------------
echo.
echo [INFO] Downloading video + original audio...
yt-dlp.exe --js-runtimes node --no-playlist ^
    -f "bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best" ^
    --merge-output-format mp4 ^
    -o "%WORK%\source.%%(ext)s" ^
    "%vid_url%"
if errorlevel 1 goto download_error

set "SOURCE_FILE="
for %%F in ("%WORK%\source.*") do if exist "%%~fF" set "SOURCE_FILE=%%~fF"
if not defined SOURCE_FILE goto download_error

echo.
echo [INFO] Downloading Russian audio source...
yt-dlp.exe --js-runtimes node --no-playlist ^
    -f "%RU_ID%" ^
    -o "%WORK%\russian.%%(ext)s" ^
    "%vid_url%"
if errorlevel 1 goto download_error

set "RU_FILE="
for %%F in ("%WORK%\russian.*") do if exist "%%~fF" set "RU_FILE=%%~fF"
if not defined RU_FILE goto download_error

:: -----------------------------------------------------------------
:: 3. Mux without transcoding:
::    Video + original audio from source, Russian audio from second file.
::    MKV is used because it is the safest container for multi-audio.
:: -----------------------------------------------------------------
echo.
echo [INFO] Building MKV with Original + Russian audio...
ffmpeg.exe -hide_banner -y ^
    -i "%SOURCE_FILE%" ^
    -i "%RU_FILE%" ^
    -map 0:v:0 ^
    -map 0:a:0 ^
    -map 1:a:0 ^
    -map 0:s? ^
    -c copy ^
    -metadata:s:a:0 title="Original" ^
    -metadata:s:a:1 title="Russian" ^
    -metadata:s:a:1 language=rus ^
    -disposition:a:0 default ^
    -disposition:a:1 0 ^
    "%OUTPUT_DIR%\%FINAL_BASE% [Original+RUS].mkv"

if errorlevel 1 (
    echo.
    echo [ERROR] FFmpeg failed to build the final MKV file.
    echo [INFO] Temporary files were kept in: %WORK%
    pause
    goto loop
)

rmdir /s /q "%WORK%" >nul 2>&1

echo.
echo [DONE] Completed successfully.
echo [INFO] Saved file:
echo        %OUTPUT_DIR%\%FINAL_BASE% [Original+RUS].mkv
echo.
pause
goto loop

:download_error
echo.
echo [ERROR] Failed to download one of the required streams.
echo [INFO] Temporary files were kept in: %WORK%
pause
goto loop
