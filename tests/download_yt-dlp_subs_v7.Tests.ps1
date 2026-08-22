$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'download_yt-dlp_subs_v7.ps1'
$commandInfo = Get-Command -Name $scriptPath -CommandType ExternalScript
$commandMetadata = [System.Management.Automation.CommandMetadata]::new($commandInfo)
$addRusubParameter = $commandMetadata.Parameters['AddRusub']

if ($null -eq $addRusubParameter -or $addRusubParameter.ParameterType -ne [switch]) {
    throw 'AddRusub must be exposed as a switch parameter.'
}

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$errors
)

if ($errors.Count -gt 0) {
    throw ('Script has parse errors: ' + ($errors.Message -join '; '))
}

$processVideoAst = $ast.Find(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Process-Video' },
    $true
)

if ($null -eq $processVideoAst) {
    throw 'Process-Video was not found.'
}

Invoke-Expression $processVideoAst.Extent.Text

function Invoke-ProcessVideoScenario {
    param([bool]$EnableRussianSubtitles)

    $script:AddRusub = $EnableRussianSubtitles
    $script:StartCalls = 0
    $script:WaitCalls = 0
    $script:StopCalls = 0
    $script:ResolvedLanguages = @()
    $script:BgutilStartResult = $true

    function Start-BgutilProviderIfNeeded {
        $script:StartCalls++
        return $script:BgutilStartResult
    }

    function Wait-BgutilProviderReady {
        $script:WaitCalls++
        return $false
    }

    function Stop-BgutilProviderIfOwned {
        $script:StopCalls++
    }

    function Get-OutputDirectory { return $TestDrive }
    function Get-VideoMetadata {
        return [pscustomobject]@{
            id = 'test-id'
            title = 'Test video'
            formats = @()
            subtitles = $null
            automatic_captions = $null
        }
    }
    function Get-SafeBaseName { return 'Test video [test-id]' }
    function Get-OriginalAudioLanguage { return 'en' }
    function Get-LanguageRoot { param([string]$Language) return $Language }
    function Get-BestRussianAudioFormatId { return '' }
    function Download-Video { }
    function Resolve-SubtitleTrack {
        param($Metadata, [string]$Language, [switch]$PreferOriginalTag)
        $script:ResolvedLanguages += $Language
        return $null
    }

    $script:SubtitleInterLanguageDelaySeconds = 0
    $script:TestDrive = Join-Path $env:TEMP ('yt-dlp-switch-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TestDrive | Out-Null

    try {
        Process-Video -VideoUrl 'https://example.invalid/watch?v=test-id'
        return [pscustomobject]@{
            StartCalls = $script:StartCalls
            WaitCalls = $script:WaitCalls
            StopCalls = $script:StopCalls
            ResolvedLanguages = @($script:ResolvedLanguages)
        }
    }
    finally {
        Remove-Item -LiteralPath $script:TestDrive -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$withoutSwitch = Invoke-ProcessVideoScenario -EnableRussianSubtitles $false
if ($withoutSwitch.StartCalls -ne 0) {
    throw "Without -AddRusub, bgutil was started $($withoutSwitch.StartCalls) time(s); expected 0."
}
if ($withoutSwitch.WaitCalls -ne 0) {
    throw "Without -AddRusub, the Russian subtitle branch ran $($withoutSwitch.WaitCalls) time(s); expected 0."
}
if ($withoutSwitch.ResolvedLanguages -contains 'ru') {
    throw 'Without -AddRusub, a Russian subtitle track was resolved.'
}

$withSwitch = Invoke-ProcessVideoScenario -EnableRussianSubtitles $true
if ($withSwitch.StartCalls -ne 1) {
    throw "With -AddRusub, bgutil was started $($withSwitch.StartCalls) time(s); expected 1."
}
if ($withSwitch.WaitCalls -ne 1) {
    throw "With -AddRusub, the Russian subtitle branch ran $($withSwitch.WaitCalls) time(s); expected 1."
}

Write-Host '[PASS] -AddRusub gates bgutil and Russian subtitle processing.'
