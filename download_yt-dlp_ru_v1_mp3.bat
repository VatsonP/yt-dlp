@echo off
setlocal EnableExtensions DisableDelayedExpansion

:: ================================================================
:: YT-DLP Audio Downloader - Original + Russian MP3 files
:: Version: 2026-08-27-v1-mp3
:: ================================================================

:: Working directory containing yt-dlp.exe and ffmpeg.exe.
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
echo    YT-DLP Audio Downloader - Original + Russian MP3
echo    Version: 2026-08-27-v1-mp3
echo =====================================================
echo.
echo [INFO] Script file     : %~f0
echo [INFO] Working folder  : %WORK_DIR%
echo [INFO] Preferred folder: %PREFERRED_OUTPUT%
echo [INFO] Output folder   : %OUTPUT_DIR%
echo [INFO] MP3 bitrate     : 320 kb/s CBR
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

:: Re-check the preferred folder before every download.
set "OUTPUT_DIR=%WORK_DIR%"
if exist "%PREFERRED_OUTPUT%\" set "OUTPUT_DIR=%PREFERRED_OUTPUT%"
echo.
echo [INFO] Final output folder: %OUTPUT_DIR%

set "WORK=%TEMP%\yt-dlp-mp3-%RANDOM%-%RANDOM%"
mkdir "%WORK%" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Cannot create temporary folder: %WORK%
    pause
    goto loop
)

set "META=%WORK%\metadata.json"
set "ORIG_FILE=%WORK%\orig_lang.txt"
set "ORIG_ID_FILE=%WORK%\orig_id.txt"
set "RU_ID_FILE=%WORK%\ru_id.txt"
set "NAME_FILE=%WORK%\final_name.txt"

:: -----------------------------------------------------------------
:: 1. Read metadata once and determine:
::    - original audio language and format ID
::    - best Russian format ID when the original is not Russian
:: -----------------------------------------------------------------
echo.
echo [INFO] Checking available audio tracks...
yt-dlp.exe --no-plugin-dirs --js-runtimes node --no-playlist --skip-download --dump-single-json "%vid_url%" > "%META%"
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
  "$orig=@($a | Where-Object { (($_.format -as [string]) -match '(?i)original') -or (($_.format_note -as [string]) -match '(?i)original') } | Sort-Object @{Expression={if($_.vcodec -eq 'none'){1}else{0}};Descending=$true}, @{Expression={if($_.ext -eq 'm4a'){1}else{0}};Descending=$true}, @{Expression={[double]($_.abr)};Descending=$true}, @{Expression={[double]($_.tbr)};Descending=$true} | Select-Object -First 1);" ^
  "if(-not $orig){$orig=@($a | Sort-Object @{Expression={[double]($_.language_preference)};Descending=$true}, @{Expression={if($_.vcodec -eq 'none'){1}else{0}};Descending=$true}, @{Expression={[double]($_.abr)};Descending=$true}, @{Expression={[double]($_.tbr)};Descending=$true} | Select-Object -First 1)};" ^
  "$origLang=if($orig){[string]$orig[0].language}else{''};" ^
  "$origId=if($orig){[string]$orig[0].format_id}else{'bestaudio/best'};" ^
  "$ru=@($a | Where-Object { ([string]$_.language) -match '(?i)^ru(?:-|$)' });" ^
  "$ruAudioOnly=@($ru | Where-Object { $_.vcodec -eq 'none' });" ^
  "if($ruAudioOnly.Count -gt 0){$bestRu=$ruAudioOnly | Sort-Object @{Expression={if($_.ext -eq 'm4a'){1}else{0}};Descending=$true}, @{Expression={[double]($_.abr)};Descending=$true}, @{Expression={[double]($_.tbr)};Descending=$true} | Select-Object -First 1}" ^
  "elseif($ru.Count -gt 0){$bestRu=$ru | Sort-Object @{Expression={if(([string]$_.acodec) -match 'mp4a\.40\.2'){2}elseif(([string]$_.acodec) -match 'mp4a\.40\.5'){0}else{1}};Descending=$true}, @{Expression={if($_.height){[double]$_.height}else{99999}};Descending=$false}, @{Expression={[double]($_.tbr)};Descending=$true} | Select-Object -First 1}else{$bestRu=$null};" ^
  "$isOrigRu=($origLang -match '(?i)^ru(?:-|$)');" ^
  "$ruId=if((-not $isOrigRu) -and $bestRu){[string]$bestRu.format_id}else{''};" ^
  "$safe=[string]$j.title; [IO.Path]::GetInvalidFileNameChars() | ForEach-Object {$safe=$safe.Replace([string]$_,'_')}; $safe=$safe.Trim().TrimEnd('.'); if($safe.Length -gt 160){$safe=$safe.Substring(0,160).Trim()};" ^
  "$id=[string]$j.id;" ^
  "$origLang | Set-Content -LiteralPath '%ORIG_FILE%' -Encoding ASCII;" ^
  "$origId | Set-Content -LiteralPath '%ORIG_ID_FILE%' -Encoding ASCII;" ^
  "$ruId | Set-Content -LiteralPath '%RU_ID_FILE%' -Encoding ASCII;" ^
  "($safe+' ['+$id+']') | Set-Content -LiteralPath '%NAME_FILE%' -Encoding Default;"

if errorlevel 1 (
    echo [ERROR] Failed to analyze the available audio tracks.
    rmdir /s /q "%WORK%" >nul 2>&1
    pause
    goto loop
)

set "ORIG_LANG="
set "ORIG_ID="
set "RU_ID="
set "FINAL_BASE="
set /p ORIG_LANG=<"%ORIG_FILE%"
set /p ORIG_ID=<"%ORIG_ID_FILE%"
set /p RU_ID=<"%RU_ID_FILE%"
set /p FINAL_BASE=<"%NAME_FILE%"

if not defined ORIG_ID set "ORIG_ID=bestaudio/best"

echo [INFO] Original language: %ORIG_LANG%
echo [INFO] Original format ID: %ORIG_ID%
if defined RU_ID (
    echo [INFO] Russian audio found. Format ID: %RU_ID%
) else (
    echo [INFO] A separate Russian track is not required or was not found.
)

:: -----------------------------------------------------------------
:: 2. Download and convert the mandatory Original audio.
:: -----------------------------------------------------------------
echo.
echo [INFO] Downloading Original audio source...
yt-dlp.exe --no-plugin-dirs --js-runtimes node --no-playlist ^
    -f "%ORIG_ID%" ^
    -o "%WORK%\original.%%(ext)s" ^
    "%vid_url%"
if errorlevel 1 goto original_error

set "ORIG_SOURCE="
for %%F in ("%WORK%\original.*") do if exist "%%~fF" set "ORIG_SOURCE=%%~fF"
if not defined ORIG_SOURCE goto original_error

set "ORIG_TARGET=%OUTPUT_DIR%\%FINAL_BASE% [Original].mp3"
echo [INFO] Encoding Original MP3 at 320 kb/s CBR...
ffmpeg.exe -hide_banner -y ^
    -i "%ORIG_SOURCE%" ^
    -map 0:a:0 ^
    -vn ^
    -c:a libmp3lame ^
    -b:a 320k ^
    -metadata title="Original" ^
    "%ORIG_TARGET%"
if errorlevel 1 goto original_convert_error

echo [DONE] Saved Original MP3:
echo        %ORIG_TARGET%

:: -----------------------------------------------------------------
:: 3. If available, download and convert Russian as a separate MP3.
:: -----------------------------------------------------------------
if not defined RU_ID goto success

echo.
echo [INFO] Downloading Russian audio source...
yt-dlp.exe --no-plugin-dirs --js-runtimes node --no-playlist ^
    -f "%RU_ID%" ^
    -o "%WORK%\russian.%%(ext)s" ^
    "%vid_url%"
if errorlevel 1 goto russian_error

set "RU_SOURCE="
for %%F in ("%WORK%\russian.*") do if exist "%%~fF" set "RU_SOURCE=%%~fF"
if not defined RU_SOURCE goto russian_error

set "RU_TARGET=%OUTPUT_DIR%\%FINAL_BASE% [Russian].mp3"
echo [INFO] Encoding Russian MP3 at 320 kb/s CBR...
ffmpeg.exe -hide_banner -y ^
    -i "%RU_SOURCE%" ^
    -map 0:a:0 ^
    -vn ^
    -c:a libmp3lame ^
    -b:a 320k ^
    -metadata title="Russian" ^
    -metadata language="rus" ^
    "%RU_TARGET%"
if errorlevel 1 goto russian_convert_error

echo [DONE] Saved Russian MP3:
echo        %RU_TARGET%

:success
rmdir /s /q "%WORK%" >nul 2>&1

echo.
echo [DONE] Processing completed successfully.
echo [INFO] Output folder: %OUTPUT_DIR%
echo.
pause
goto loop

:original_error
echo.
echo [ERROR] Failed to download the Original audio source.
echo [INFO] Temporary files were kept in: %WORK%
pause
goto loop

:original_convert_error
echo.
echo [ERROR] FFmpeg failed to create the Original MP3.
echo [INFO] Temporary files were kept in: %WORK%
pause
goto loop

:russian_error
echo.
echo [ERROR] Failed to download the Russian audio source.
echo [INFO] Original MP3 was preserved: %ORIG_TARGET%
echo [INFO] Temporary files were kept in: %WORK%
pause
goto loop

:russian_convert_error
echo.
echo [ERROR] FFmpeg failed to create the Russian MP3.
echo [INFO] Original MP3 was preserved: %ORIG_TARGET%
echo [INFO] Temporary files were kept in: %WORK%
pause
goto loop
