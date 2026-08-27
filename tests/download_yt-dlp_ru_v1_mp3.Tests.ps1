$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'download_yt-dlp_ru_v1_mp3.bat'

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw 'download_yt-dlp_ru_v1_mp3.bat does not exist.'
}

$content = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

$requiredContracts = @(
    '--dump-single-json',
    '$origLang',
    '$origId',
    '$ruId=if((-not $isOrigRu)',
    'ORIG_ID_FILE',
    'RU_ID_FILE',
    '[Original].mp3',
    '[Russian].mp3',
    '-c:a libmp3lame',
    '-b:a 320k',
    '-map 0:a:0',
    '-vn',
    'if not defined RU_ID goto success',
    ':success'
)

foreach ($contract in $requiredContracts) {
    if (-not $content.Contains($contract)) {
        throw "MP3 workflow contract is missing: $contract"
    }
}

$ytDlpCalls = [regex]::Matches($content, '(?im)^yt-dlp\.exe\s')
$pluginDisabledCalls = [regex]::Matches($content, '(?im)^yt-dlp\.exe\s+--no-plugin-dirs\s')
if ($ytDlpCalls.Count -eq 0 -or $pluginDisabledCalls.Count -ne $ytDlpCalls.Count) {
    throw 'Every MP3 yt-dlp call must disable plugin discovery to avoid unnecessary bgutil /ping requests.'
}

if ($content.Contains('[Original+RUS].mp3')) {
    throw 'Original and Russian audio must be separate MP3 files.'
}

$russianWorkflow = $content.Substring($content.IndexOf(':: 3. If available'))
if ($russianWorkflow -match 'if defined RU_ID \(') {
    throw 'The Russian workflow must not use a parenthesized block with percent-expanded runtime variables.'
}

Write-Host '[PASS] MP3 workflow preserves Original and conditionally creates a separate Russian 320 kb/s file.'
