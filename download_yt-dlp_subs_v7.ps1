param(
    [Parameter(Position = 0)]
    [string]$Url,
    [switch]$AddRusub = $false
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# YT-DLP Downloader - Original + Russian audio + external SRT subtitles
# Version: 2026-08-22-v7
#
# Video policy:
#   - Up to 1080p
#   - Prefer AVC1/H.264 video + M4A/AAC audio
#   - Original audio is always kept
#   - If the original audio is not Russian and a Russian audio track exists,
#     add Russian as the second selectable audio track
#   - Final multi-audio container: MP4, stream copy (no transcoding)
#
# Subtitle policy:
#   - External .srt files only (not embedded)
#   - Original-language subtitle: manual first, automatic captions as fallback
#   - Russian subtitle (only with -AddRusub and when original language is not Russian):
#       manual first, automatic/translated caption as fallback
#       requested immediately with YouTube player_client=android_vr
#   - Russian subtitles use the local bgutil HTTP PO Token Provider
#   - If the provider is unavailable, Russian subtitles are skipped gracefully
#   - Missing subtitles do not fail the video download
#
# Output policy:
#   - Preferred: D:\TempD
#   - Fallback : d:\Trainings\yt-dlp
# ============================================================================

$WorkDir = 'd:\Trainings\yt-dlp'
$PreferredOutput = 'D:\TempD'
$YtDlp = Join-Path $WorkDir 'yt-dlp.exe'
$Ffmpeg = Join-Path $WorkDir 'ffmpeg.exe'

# bgutil HTTP PO Token Provider is kept inside the same yt-dlp working tree.
$BgutilRoot = Join-Path $WorkDir 'bgutil-ytdlp-pot-provider'
$BgutilServerDir = Join-Path $BgutilRoot 'server'
$BgutilMainJs = Join-Path $BgutilServerDir 'build\main.js'
$BgutilPingUrls = @(
    'http://127.0.0.1:4416/ping',
    'http://localhost:4416/ping',
    'http://[::1]:4416/ping'
)
$BgutilPingUrl = $BgutilPingUrls[0]
$BgutilStartupTimeoutSeconds = 90
$BgutilPollIntervalMilliseconds = 1000
$BgutilStdoutLog = Join-Path $WorkDir 'bgutil-provider.stdout.log'
$BgutilStderrLog = Join-Path $WorkDir 'bgutil-provider.stderr.log'
$BgutilProcess = $null
$BgutilStartedByScript = $false

# Disable the slower script provider explicitly. v6 uses HTTP provider only.
$DisabledBgutilScriptHome = Join-Path $WorkDir '__disabled_bgutil_script__'
$VideoFormat = 'bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best'
$CommonYtDlpArgs = @(
    '--js-runtimes', 'node',
    '--no-playlist',
    '--extractor-args', ('youtubepot-bgutilscript:server_home={0}' -f $DisabledBgutilScriptHome)
)

# Subtitle throttling / retry policy. Parallel subtitle downloads are avoided on
# purpose because they can increase the probability of YouTube HTTP 429 errors.
#
# Original subtitles use the default YouTube client.
# bgutil is started asynchronously near the beginning of Process-Video.
# Before Russian subtitles, the script waits only if the provider is not ready yet.
# Russian subtitles use android_vr + local bgutil HTTP PO Token Provider.
# Only one controlled retry is allowed: attempt 1 -> wait 90 sec -> attempt 2.
$SubtitleInterLanguageDelaySeconds = 30
$SubtitleRequestSleepSeconds = 2
$SubtitleMaxAttempts = 2
$SubtitleRetryDelaySeconds = @(90)
$RussianSubtitlePlayerClient = 'android_vr'


function Test-BgutilProvider {
    foreach ($pingUrl in $BgutilPingUrls) {
        try {
            $response = Invoke-RestMethod -Uri $pingUrl -Method Get -TimeoutSec 2 -ErrorAction Stop
            if ($null -ne $response -and $null -ne $response.version) {
                $script:BgutilPingUrl = $pingUrl
                return $true
            }
        }
        catch {
            # Try the next loopback form.
        }
    }

    return $false
}

function Show-BgutilStartupLogs {
    param(
        [int]$TailLines = 25
    )

    if (Test-Path -LiteralPath $BgutilStdoutLog -PathType Leaf) {
        Write-Host '[INFO] bgutil stdout (tail):'
        Get-Content -LiteralPath $BgutilStdoutLog -Tail $TailLines -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host ("    {0}" -f $_) }
    }

    if (Test-Path -LiteralPath $BgutilStderrLog -PathType Leaf) {
        $stderrLines = @(Get-Content -LiteralPath $BgutilStderrLog -Tail $TailLines -ErrorAction SilentlyContinue)
        if ($stderrLines.Count -gt 0) {
            Write-Host '[INFO] bgutil stderr (tail):'
            $stderrLines | ForEach-Object { Write-Host ("    {0}" -f $_) }
        }
    }
}

function Start-BgutilProviderIfNeeded {
    if (Test-BgutilProvider) {
        Write-Host ("[INFO] PO Token Provider is already available: {0}" -f $BgutilPingUrl)
        return $true
    }

    if (-not (Test-Path -LiteralPath $BgutilMainJs -PathType Leaf)) {
        Write-Host '[WARN] PO Token Provider is not available.'
        Write-Host ("[WARN] bgutil server was not found: {0}" -f $BgutilMainJs)
        return $false
    }

    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $nodeCommand) {
        Write-Host '[WARN] PO Token Provider is not available.'
        Write-Host '[WARN] Node.js was not found in PATH.'
        return $false
    }

    Write-Host '[INFO] Starting bgutil HTTP PO Token Provider asynchronously...'
    Write-Host ("[INFO] Node executable     : {0}" -f $nodeCommand.Source)
    Write-Host ("[INFO] Provider entrypoint: {0}" -f $BgutilMainJs)

    Remove-Item -LiteralPath $BgutilStdoutLog -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $BgutilStderrLog -Force -ErrorAction SilentlyContinue

    try {
        $quotedMainJs = '"' + $BgutilMainJs + '"'

        $script:BgutilProcess = Start-Process `
            -FilePath $nodeCommand.Source `
            -ArgumentList @($quotedMainJs) `
            -WorkingDirectory $BgutilServerDir `
            -RedirectStandardOutput $BgutilStdoutLog `
            -RedirectStandardError $BgutilStderrLog `
            -WindowStyle Hidden `
            -PassThru `
            -ErrorAction Stop

        $script:BgutilStartedByScript = $true
        Write-Host ("[INFO] Provider process ID : {0}" -f $script:BgutilProcess.Id)
        Write-Host '[INFO] Provider is warming up in parallel with video/subtitle processing.'
        return $true
    }
    catch {
        Write-Host ("[WARN] Failed to start PO Token Provider: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Wait-BgutilProviderReady {
    if (Test-BgutilProvider) {
        Write-Host ("[INFO] PO Token Provider is ready: {0}" -f $BgutilPingUrl)
        return $true
    }

    if (-not $script:BgutilStartedByScript) {
        Write-Host '[WARN] PO Token Provider is not running.'
        return $false
    }

    Write-Host ("[INFO] Waiting up to {0} seconds for PO Token Provider readiness..." -f $BgutilStartupTimeoutSeconds)

    $deadline = (Get-Date).AddSeconds($BgutilStartupTimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        if (Test-BgutilProvider) {
            Write-Host ("[INFO] PO Token Provider is ready: {0}" -f $BgutilPingUrl)
            return $true
        }

        if ($null -ne $script:BgutilProcess -and $script:BgutilProcess.HasExited) {
            Write-Host ("[WARN] PO Token Provider exited during startup. Exit code: {0}" -f $script:BgutilProcess.ExitCode)
            Show-BgutilStartupLogs
            $script:BgutilProcess = $null
            $script:BgutilStartedByScript = $false
            return $false
        }

        Start-Sleep -Milliseconds $BgutilPollIntervalMilliseconds
    }

    Write-Host ("[WARN] PO Token Provider did not become ready within {0} seconds." -f $BgutilStartupTimeoutSeconds)
    Show-BgutilStartupLogs
    return $false
}

function Stop-BgutilProviderIfOwned {
    if (-not $script:BgutilStartedByScript -or $null -eq $script:BgutilProcess) {
        return
    }

    try {
        if (-not $script:BgutilProcess.HasExited) {
            Write-Host '[INFO] Stopping bgutil HTTP PO Token Provider...'
            Stop-Process -Id $script:BgutilProcess.Id -Force -ErrorAction Stop
            $script:BgutilProcess.WaitForExit(5000) | Out-Null
            Write-Host '[INFO] PO Token Provider stopped.'
        }
    }
    catch {
        Write-Host ("[WARN] Could not stop PO Token Provider cleanly: {0}" -f $_.Exception.Message)
    }
    finally {
        $script:BgutilProcess = $null
        $script:BgutilStartedByScript = $false
    }
}

function Get-OutputDirectory {
    if (Test-Path -LiteralPath $PreferredOutput -PathType Container) {
        return $PreferredOutput
    }
    return $WorkDir
}

function Test-RequiredTools {
    if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
        throw "Working folder does not exist: $WorkDir"
    }
    if (-not (Test-Path -LiteralPath $YtDlp -PathType Leaf)) {
        throw "yt-dlp.exe was not found: $YtDlp"
    }
    if (-not (Test-Path -LiteralPath $Ffmpeg -PathType Leaf)) {
        throw "ffmpeg.exe was not found: $Ffmpeg"
    }
}

function Invoke-YtDlp {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    & $YtDlp @Arguments
    $exitCode = $LASTEXITCODE
    if (($exitCode -ne 0) -and (-not $AllowFailure)) {
        throw "yt-dlp failed with exit code $exitCode."
    }
    return $exitCode
}

function Get-VideoMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoUrl,
        [Parameter(Mandatory = $true)]
        [string]$MetadataPath
    )

    # Write JSON directly from yt-dlp to avoid Windows PowerShell native-output
    # encoding/redirection differences. The temp file is new for every run.
    $args = @($CommonYtDlpArgs) + @(
        '--skip-download',
        '--print-to-file', '%()j', $MetadataPath,
        $VideoUrl
    )
    & $YtDlp @args
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) {
        throw "Failed to retrieve video metadata."
    }

    return (Get-Content -LiteralPath $MetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-SafeBaseName {
    param(
        [Parameter(Mandatory = $true)]$Metadata
    )

    $title = [string]$Metadata.title
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) {
        $title = $title.Replace([string]$c, '_')
    }
    $title = $title.Trim().TrimEnd('.')
    if ($title.Length -gt 160) {
        $title = $title.Substring(0, 160).Trim()
    }
    return ('{0} [{1}]' -f $title, [string]$Metadata.id)
}

function Get-OriginalAudioLanguage {
    param(
        [Parameter(Mandatory = $true)]$Metadata
    )

    # Prefer the extractor-level language when present.
    if ($Metadata.PSObject.Properties.Name -contains 'language') {
        $metaLanguage = [string]$Metadata.language
        if (-not [string]::IsNullOrWhiteSpace($metaLanguage)) {
            return $metaLanguage
        }
    }

    $audioFormats = @(
        $Metadata.formats | Where-Object {
            $_.acodec -and $_.acodec -ne 'none' -and $_.language
        }
    )

    if ($audioFormats.Count -eq 0) {
        return ''
    }

    $original = @(
        $audioFormats | Where-Object {
            (([string]$_.format) -match '(?i)original') -or
            (([string]$_.format_note) -match '(?i)original')
        } | Sort-Object `
            @{ Expression = { [double]$_.language_preference }; Descending = $true }, `
            @{ Expression = { [double]$_.abr }; Descending = $true } |
            Select-Object -First 1
    )

    if ($original.Count -eq 0) {
        $original = @(
            $audioFormats | Sort-Object `
                @{ Expression = { [double]$_.language_preference }; Descending = $true }, `
                @{ Expression = { [double]$_.abr }; Descending = $true } |
                Select-Object -First 1
        )
    }

    if ($original.Count -gt 0) {
        return [string]$original[0].language
    }
    return ''
}

function Get-LanguageRoot {
    param([string]$Language)

    if ($Language -match '^(?<root>[A-Za-z]{2,3})(?:-|$)') {
        return $Matches.root.ToLowerInvariant()
    }
    return $Language.ToLowerInvariant()
}

function Get-BestRussianAudioFormatId {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [string]$OriginalLanguage
    )

    if ($OriginalLanguage -match '(?i)^ru(?:-|$)') {
        return ''
    }

    $ru = @(
        $Metadata.formats | Where-Object {
            $_.acodec -and $_.acodec -ne 'none' -and
            (([string]$_.language) -match '(?i)^ru(?:-|$)')
        }
    )

    if ($ru.Count -eq 0) {
        return ''
    }

    $audioOnly = @($ru | Where-Object { $_.vcodec -eq 'none' })
    if ($audioOnly.Count -gt 0) {
        $best = $audioOnly | Sort-Object `
            @{ Expression = { if ($_.ext -eq 'm4a') { 1 } else { 0 } }; Descending = $true }, `
            @{ Expression = { [double]$_.abr }; Descending = $true }, `
            @{ Expression = { [double]$_.tbr }; Descending = $true } |
            Select-Object -First 1
        return [string]$best.format_id
    }

    $best = $ru | Sort-Object `
        @{ Expression = {
            if (([string]$_.acodec) -match 'mp4a\.40\.2') { 2 }
            elseif (([string]$_.acodec) -match 'mp4a\.40\.5') { 0 }
            else { 1 }
        }; Descending = $true }, `
        @{ Expression = { if ($_.height) { [double]$_.height } else { 99999 } }; Descending = $false }, `
        @{ Expression = { [double]$_.tbr }; Descending = $true } |
        Select-Object -First 1

    if ($null -ne $best) {
        return [string]$best.format_id
    }
    return ''
}

function Get-SubtitleKeys {
    param($SubtitleObject)

    if ($null -eq $SubtitleObject) {
        return @()
    }
    return @($SubtitleObject.PSObject.Properties.Name)
}

function Find-SubtitleKey {
    param(
        $SubtitleObject,
        [string]$Language,
        [switch]$PreferOriginalTag
    )

    $keys = Get-SubtitleKeys $SubtitleObject
    if ($keys.Count -eq 0 -or [string]::IsNullOrWhiteSpace($Language)) {
        return $null
    }

    $root = Get-LanguageRoot $Language

    # Exact extractor language tag first.
    $match = $keys | Where-Object { $_ -ieq $Language } | Select-Object -First 1
    if ($match) { return [string]$match }

    # YouTube often marks the source automatic caption with an "-orig" suffix.
    if ($PreferOriginalTag) {
        $match = $keys | Where-Object { $_ -imatch ('^{0}(?:-[^ ]*)?-orig$' -f [regex]::Escape($root)) } | Select-Object -First 1
        if ($match) { return [string]$match }

        $match = $keys | Where-Object { $_ -ieq ($root + '-orig') } | Select-Object -First 1
        if ($match) { return [string]$match }
    }

    # Base language, e.g. en for en-US.
    $match = $keys | Where-Object { $_ -ieq $root } | Select-Object -First 1
    if ($match) { return [string]$match }

    # Regional/variant tags as a last language-compatible fallback.
    $match = $keys | Where-Object { $_ -imatch ('^{0}(?:-|$)' -f [regex]::Escape($root)) } | Select-Object -First 1
    if ($match) { return [string]$match }

    return $null
}

function Resolve-SubtitleTrack {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Language,
        [switch]$PreferOriginalTag
    )

    # Manual subtitles always have priority.
    $manualKey = Find-SubtitleKey -SubtitleObject $Metadata.subtitles -Language $Language -PreferOriginalTag:$PreferOriginalTag
    if ($manualKey) {
        return [pscustomobject]@{
            Kind = 'manual'
            Key  = $manualKey
        }
    }

    $autoKey = Find-SubtitleKey -SubtitleObject $Metadata.automatic_captions -Language $Language -PreferOriginalTag:$PreferOriginalTag
    if ($autoKey) {
        return [pscustomobject]@{
            Kind = 'auto'
            Key  = $autoKey
        }
    }

    return $null
}

function Download-SubtitleSrt {
    param(
        [Parameter(Mandatory = $true)][string]$VideoUrl,
        [Parameter(Mandatory = $true)]$Track,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$TempRoot,
        [string]$PlayerClient = ''
    )

    for ($attempt = 1; $attempt -le $SubtitleMaxAttempts; $attempt++) {
        $subTemp = Join-Path $TempRoot ('sub-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $subTemp | Out-Null

        try {
            if ($attempt -gt 1) {
                $delayIndex = [Math]::Min($attempt - 2, $SubtitleRetryDelaySeconds.Count - 1)
                $delay = [int]$SubtitleRetryDelaySeconds[$delayIndex]
                Write-Host ("[WARN] Subtitle download attempt {0}/{1} failed. Waiting {2} seconds before retry..." -f ($attempt - 1), $SubtitleMaxAttempts, $delay)
                Start-Sleep -Seconds $delay
            }

            if ([string]::IsNullOrWhiteSpace($PlayerClient)) {
                Write-Host ("[INFO] Subtitle download attempt {0}/{1} (default YouTube client)..." -f $attempt, $SubtitleMaxAttempts)
            }
            else {
                Write-Host ("[INFO] Subtitle download attempt {0}/{1} (player_client={2})..." -f $attempt, $SubtitleMaxAttempts, $PlayerClient)
            }

            $args = @($CommonYtDlpArgs) + @(
                '--skip-download',
                '--sub-langs', [string]$Track.Key,
                '--sub-format', 'best',
                '--convert-subs', 'srt',
                '--ffmpeg-location', $WorkDir,
                '--sleep-subtitles', [string]$SubtitleRequestSleepSeconds,
                '--retries', '0',
                '--fragment-retries', '0',
                '-o', (Join-Path $subTemp '%(title)s [%(id)s].%(ext)s')
            )

            if (-not [string]::IsNullOrWhiteSpace($PlayerClient)) {
                $args += @('--extractor-args', ('youtube:player_client={0}' -f $PlayerClient))
            }

            if ($Track.Kind -eq 'manual') {
                $args += '--write-subs'
            }
            else {
                $args += '--write-auto-subs'
            }
            $args += $VideoUrl

            # Preserve yt-dlp console output without leaking stdout objects into this
            # function's success pipeline. Otherwise PowerShell can treat textual
            # yt-dlp output as a truthy return value even when the final Boolean is false.
            & $YtDlp @args | ForEach-Object { Write-Host $_ }
            $exitCode = $LASTEXITCODE

            # Use a fresh per-attempt directory and verify the resulting file.
            # yt-dlp may occasionally report a subtitle HTTP error without a
            # reliable non-zero process exit code, so file validation is the
            # final success criterion here.
            $srt = Get-ChildItem -LiteralPath $subTemp -Filter '*.srt' -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 0 } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            if (($exitCode -eq 0) -and ($null -ne $srt)) {
                Move-Item -LiteralPath $srt.FullName -Destination $TargetPath -Force

                if ((Test-Path -LiteralPath $TargetPath -PathType Leaf) -and ((Get-Item -LiteralPath $TargetPath).Length -gt 0)) {
                    return $true
                }
            }

            Write-Host ("[WARN] Subtitle attempt {0}/{1} did not produce a valid SRT file." -f $attempt, $SubtitleMaxAttempts)
        }
        finally {
            Remove-Item -LiteralPath $subTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return $false
}

function Download-Video {
    param(
        [Parameter(Mandatory = $true)][string]$VideoUrl,
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$OriginalLanguage,
        [Parameter(Mandatory = $true)][string]$RussianFormatId,
        [Parameter(Mandatory = $true)][string]$FinalBase,
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][string]$TempRoot
    )

    if ([string]::IsNullOrWhiteSpace($RussianFormatId)) {
        Write-Host '[INFO] Downloading video with the original audio track...'
        $args = @($CommonYtDlpArgs) + @(
            '-f', $VideoFormat,
            '--merge-output-format', 'mp4',
            '--ffmpeg-location', $WorkDir,
            '-o', (Join-Path $OutputDir '%(title)s [%(id)s].%(ext)s'),
            $VideoUrl
        )
        & $YtDlp @args
        if ($LASTEXITCODE -ne 0) {
            throw 'Video download failed.'
        }
        return
    }

    Write-Host '[INFO] Downloading video + original audio...'
    $sourceTemplate = Join-Path $TempRoot 'source.%(ext)s'
    $args = @($CommonYtDlpArgs) + @(
        '-f', $VideoFormat,
        '--merge-output-format', 'mp4',
        '--ffmpeg-location', $WorkDir,
        '-o', $sourceTemplate,
        $VideoUrl
    )
    & $YtDlp @args
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to download video + original audio.'
    }

    $sourceFile = Get-ChildItem -LiteralPath $TempRoot -Filter 'source.*' -File |
        Where-Object { $_.Extension -notin @('.part', '.ytdl') } |
        Select-Object -First 1
    if ($null -eq $sourceFile) {
        throw 'The downloaded source video file was not found.'
    }

    Write-Host ("[INFO] Downloading Russian audio source (format {0})..." -f $RussianFormatId)
    $ruTemplate = Join-Path $TempRoot 'russian.%(ext)s'
    $args = @($CommonYtDlpArgs) + @(
        '-f', $RussianFormatId,
        '--ffmpeg-location', $WorkDir,
        '-o', $ruTemplate,
        $VideoUrl
    )
    & $YtDlp @args
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to download the Russian audio source.'
    }

    $ruFile = Get-ChildItem -LiteralPath $TempRoot -Filter 'russian.*' -File |
        Where-Object { $_.Extension -notin @('.part', '.ytdl') } |
        Select-Object -First 1
    if ($null -eq $ruFile) {
        throw 'The downloaded Russian audio file was not found.'
    }

    $finalVideo = Join-Path $OutputDir ($FinalBase + ' [Original+RUS].mp4')
    Write-Host '[INFO] Building MP4 with Original + Russian audio...'

    $ffmpegArgs = @(
        '-hide_banner', '-y',
        '-i', $sourceFile.FullName,
        '-i', $ruFile.FullName,
        '-map', '0:v:0',
        '-map', '0:a:0',
        '-map', '1:a:0',
        '-map', '0:s?',
        '-c', 'copy',
        '-metadata:s:a:0', 'title=Original',
        '-metadata:s:a:1', 'title=Russian',
        '-metadata:s:a:1', 'language=rus',
        '-disposition:a:0', 'default',
        '-disposition:a:1', '0',
        '-movflags', '+faststart',
        $finalVideo
    )

    & $Ffmpeg @ffmpegArgs
    if ($LASTEXITCODE -ne 0) {
        throw 'FFmpeg failed to build the final MP4 file.'
    }
}

function Process-Video {
    param(
        [Parameter(Mandatory = $true)][string]$VideoUrl
    )

    if ($AddRusub) {
        # Start bgutil early and let it warm up while the main media workflow runs.
        # This call is intentionally non-blocking.
        $bgutilStartRequested = Start-BgutilProviderIfNeeded
        if (-not $bgutilStartRequested) {
            Write-Host '[WARN] bgutil could not be started early. Video and original subtitles will continue.'
        }
        Write-Host ''
    }

    $OutputDir = Get-OutputDirectory
    $TempRoot = Join-Path $env:TEMP ('yt-dlp-subs-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $TempRoot | Out-Null
    $metadataPath = Join-Path $TempRoot 'metadata.json'

    try {
        Write-Host ''
        Write-Host ("[INFO] Final output folder: {0}" -f $OutputDir)
        Write-Host '[INFO] Reading YouTube metadata...'

        $metadata = Get-VideoMetadata -VideoUrl $VideoUrl -MetadataPath $metadataPath
        $finalBase = Get-SafeBaseName -Metadata $metadata
        $origLang = Get-OriginalAudioLanguage -Metadata $metadata
        $origRoot = Get-LanguageRoot $origLang
        $isOriginalRussian = $origLang -match '(?i)^ru(?:-|$)'
        $ruAudioId = Get-BestRussianAudioFormatId -Metadata $metadata -OriginalLanguage $origLang
        $mediaBase = if ($ruAudioId) { $finalBase + ' [Original+RUS]' } else { $finalBase }

        if ([string]::IsNullOrWhiteSpace($origLang)) {
            Write-Host '[WARN] Original language could not be determined reliably.'
        }
        else {
            Write-Host ("[INFO] Original language: {0}" -f $origLang)
        }

        if ($ruAudioId) {
            Write-Host ("[INFO] Russian audio found. Format ID: {0}" -f $ruAudioId)
        }
        elseif ($isOriginalRussian) {
            Write-Host '[INFO] Original audio is Russian; no second Russian audio track is needed.'
        }
        else {
            Write-Host '[INFO] A separate Russian audio track was not found.'
        }

        # Video is the primary artifact. Subtitle failures are intentionally non-fatal.
        Download-Video -VideoUrl $VideoUrl -Metadata $metadata -OriginalLanguage $origLang `
            -RussianFormatId $ruAudioId -FinalBase $finalBase -OutputDir $OutputDir -TempRoot $TempRoot

        Write-Host ''
        Write-Host '[INFO] Resolving subtitles...'

        # Original-language subtitle.
        if (-not [string]::IsNullOrWhiteSpace($origLang)) {
            $origTrack = Resolve-SubtitleTrack -Metadata $metadata -Language $origLang -PreferOriginalTag
            if ($null -ne $origTrack) {
                $origSuffix = if ($origRoot) { $origRoot } else { 'original' }
                $origTarget = Join-Path $OutputDir ($mediaBase + '.' + $origSuffix + '.srt')
                Write-Host ("[INFO] Original subtitle: {0} ({1})" -f $origTrack.Key, $origTrack.Kind)
                if (Download-SubtitleSrt -VideoUrl $VideoUrl -Track $origTrack -TargetPath $origTarget -TempRoot $TempRoot) {
                    Write-Host ("[DONE] Saved subtitle: {0}" -f $origTarget)
                }
                else {
                    Write-Host '[WARN] Failed to download/convert the original-language subtitle.'
                }
            }
            else {
                Write-Host '[WARN] No subtitle/caption was found for the original language.'
            }
        }
        else {
            Write-Host '[WARN] Original-language subtitle was skipped because the original language is unknown.'
        }

        if ($AddRusub) {
            # Russian subtitle only when the source language is not Russian.
            # v6 requires the local bgutil HTTP PO Token Provider for this branch.
            if (-not $isOriginalRussian) {
            $poTokenProviderAvailable = Wait-BgutilProviderReady

            if (-not $poTokenProviderAvailable) {
                Write-Host '[WARN] PO Token Provider is not available.'
                Write-Host '[WARN] Russian subtitles will be skipped.'
            }
            else {
                if ($SubtitleInterLanguageDelaySeconds -gt 0) {
                    Write-Host ("[INFO] Waiting {0} seconds before requesting Russian subtitles..." -f $SubtitleInterLanguageDelaySeconds)
                    Start-Sleep -Seconds $SubtitleInterLanguageDelaySeconds
                }

                $ruTrack = Resolve-SubtitleTrack -Metadata $metadata -Language 'ru'
                if ($null -ne $ruTrack) {
                    $ruTarget = Join-Path $OutputDir ($mediaBase + '.ru.srt')
                    Write-Host ("[INFO] Russian subtitle: {0} ({1})" -f $ruTrack.Key, $ruTrack.Kind)
                    Write-Host ("[INFO] Russian subtitle client: {0}" -f $RussianSubtitlePlayerClient)
                    Write-Host '[INFO] PO Token Provider: bgutil HTTP (127.0.0.1:4416)'

                    if (Download-SubtitleSrt -VideoUrl $VideoUrl -Track $ruTrack -TargetPath $ruTarget -TempRoot $TempRoot -PlayerClient $RussianSubtitlePlayerClient) {
                        Write-Host ("[DONE] Saved subtitle: {0}" -f $ruTarget)
                    }
                    else {
                        Write-Host '[WARN] Failed to download/convert the Russian subtitle.'
                    }
                }
                else {
                    Write-Host '[WARN] No Russian subtitle/caption was found.'
                }
            }
            }
            else {
                Write-Host '[INFO] Russian subtitle is already the original-language subtitle; no duplicate file is created.'
            }
        }
        else {
            Write-Host '[INFO] Russian subtitles are disabled. Use -AddRusub to enable them.'
        }

        Write-Host ''
        Write-Host '[DONE] Processing completed.'
        Write-Host ("[INFO] Output folder: {0}" -f $OutputDir)
    }
    finally {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        Stop-BgutilProviderIfOwned
    }
}

try {
    Test-RequiredTools
    Set-Location -LiteralPath $WorkDir
}
catch {
    Write-Host ("[ERROR] {0}" -f $_.Exception.Message)
    Read-Host 'Press Enter to exit'
    exit 1
}

$singleRun = -not [string]::IsNullOrWhiteSpace($Url)

do {
    Clear-Host
    Write-Host '================================================================'
    Write-Host '  YT-DLP Downloader - Video + Original/Russian audio + SRT subs'
    Write-Host '  Version: 2026-08-22-v7'
    Write-Host '================================================================'
    Write-Host ''
    Write-Host ("[INFO] Script file     : {0}" -f $PSCommandPath)
    Write-Host ("[INFO] Working folder  : {0}" -f $WorkDir)
    Write-Host ("[INFO] Preferred folder: {0}" -f $PreferredOutput)
    Write-Host ("[INFO] Output folder   : {0}" -f (Get-OutputDirectory))
    Write-Host ("[INFO] Russian subtitles: {0}" -f $(if ($AddRusub) { 'enabled' } else { 'disabled' }))
    Write-Host ("[INFO] RU subtitle client: {0}" -f $RussianSubtitlePlayerClient)
    Write-Host ("[INFO] EN->RU safety delay: {0} sec" -f $SubtitleInterLanguageDelaySeconds)
    Write-Host ("[INFO] RU retry delays   : {0} sec" -f ($SubtitleRetryDelaySeconds -join ' / '))
    Write-Host ("[INFO] bgutil repository : {0}" -f $BgutilRoot)
    Write-Host ("[INFO] bgutil endpoint   : {0}" -f $BgutilPingUrl)
    Write-Host ("[INFO] bgutil readiness max : {0} sec" -f $BgutilStartupTimeoutSeconds)
    Write-Host ("[INFO] bgutil poll interval  : {0} ms" -f $BgutilPollIntervalMilliseconds)
    Write-Host ''

    if (-not $singleRun) {
        $Url = Read-Host 'Paste the video URL and press Enter'
    }

    if ([string]::IsNullOrWhiteSpace($Url)) {
        if ($singleRun) { exit 1 }
        continue
    }

    try {
        Process-Video -VideoUrl $Url.Trim()
    }
    catch {
        Write-Host ''
        Write-Host ("[ERROR] {0}" -f $_.Exception.Message)
    }

    if ($singleRun) {
        break
    }

    Write-Host ''
    Read-Host 'Press Enter to continue'
    $Url = ''
}
while ($true)
