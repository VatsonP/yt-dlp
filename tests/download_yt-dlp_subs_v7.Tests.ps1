$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'download_yt-dlp_subs_v7.ps1'
$commandInfo = Get-Command -Name $scriptPath -CommandType ExternalScript
$commandMetadata = [System.Management.Automation.CommandMetadata]::new($commandInfo)
$addRusubParameter = $commandMetadata.Parameters['AddRusub']
$rusubVerboseDiagParameter = $commandMetadata.Parameters['RusubVerboseDiag']

if ($null -eq $addRusubParameter -or $addRusubParameter.ParameterType -ne [switch]) {
    throw 'AddRusub must be exposed as a switch parameter.'
}
if ($null -eq $rusubVerboseDiagParameter -or $rusubVerboseDiagParameter.ParameterType -ne [switch]) {
    throw 'RusubVerboseDiag must be exposed as a switch parameter.'
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

$downloadSubtitleAst = $ast.Find(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Download-SubtitleSrt' },
    $true
)

if ($null -eq $downloadSubtitleAst) {
    throw 'Download-SubtitleSrt was not found.'
}

Invoke-Expression $downloadSubtitleAst.Extent.Text

$russianClientAssignmentAst = $ast.Find(
    {
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$RussianSubtitlePlayerClient'
    },
    $true
)

if ($null -eq $russianClientAssignmentAst) {
    throw 'RussianSubtitlePlayerClient initialization was not found.'
}

Invoke-Expression $russianClientAssignmentAst.Extent.Text

function Invoke-FakeYtDlp {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)

    $script:CapturedYtDlpArguments = @($Arguments)
    $global:LASTEXITCODE = 0
}

function Invoke-SubtitleArgumentScenario {
    param(
        [bool]$EnableVerboseDiagnostics,
        [bool]$IgnoreMissingFormats = $false
    )

    $script:YtDlp = 'Invoke-FakeYtDlp'
    $script:CommonYtDlpArgs = @('--no-playlist')
    $script:WorkDir = Split-Path -Parent $scriptPath
    $script:SubtitleMaxAttempts = 1
    $script:SubtitleRequestSleepSeconds = 0
    $script:SubtitleRetryDelaySeconds = @(0)
    $script:CapturedYtDlpArguments = @()
    $tempRoot = Join-Path $env:TEMP ('yt-dlp-verbose-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    try {
        $parameters = @{
            VideoUrl = 'https://example.invalid/watch?v=test-id'
            Track = [pscustomobject]@{ Kind = 'auto'; Key = 'ru' }
            TargetPath = Join-Path $tempRoot 'target.ru.srt'
            TempRoot = $tempRoot
            PlayerClient = 'android_vr'
        }
        if ($EnableVerboseDiagnostics) {
            $parameters.VerboseDiagnostics = $true
        }
        if ($IgnoreMissingFormats) {
            $parameters.IgnoreNoFormatsError = $true
        }

        [void](Download-SubtitleSrt @parameters)
        return @($script:CapturedYtDlpArguments)
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$regularSubtitleArguments = Invoke-SubtitleArgumentScenario -EnableVerboseDiagnostics $false
if ($regularSubtitleArguments -contains '--verbose') {
    throw 'Regular subtitle downloads must not enable yt-dlp verbose diagnostics.'
}

$diagnosticSubtitleArguments = Invoke-SubtitleArgumentScenario -EnableVerboseDiagnostics $true
if ($diagnosticSubtitleArguments -notcontains '--verbose') {
    throw 'Diagnostic subtitle downloads must pass --verbose to yt-dlp.'
}

$ignoreMissingFormatsArguments = Invoke-SubtitleArgumentScenario -EnableVerboseDiagnostics $false -IgnoreMissingFormats $true
if ($ignoreMissingFormatsArguments -notcontains '--ignore-no-formats-error') {
    throw 'Subtitle requests configured to ignore missing formats must pass --ignore-no-formats-error to yt-dlp.'
}

Write-Host '[PASS] Verbose diagnostics are isolated to explicitly diagnostic subtitle downloads.'

function Invoke-ProcessVideoScenario {
    param(
        [bool]$EnableRussianSubtitles,
        [bool]$EnableRussianSubtitleDiagnostics = $false,
        [bool]$ProviderAvailable = $false,
        [bool]$RussianTrackAvailable = $false
    )

    $script:AddRusub = $EnableRussianSubtitles
    $script:RusubVerboseDiag = $EnableRussianSubtitleDiagnostics
    $script:StartCalls = 0
    $script:WaitCalls = 0
    $script:StopCalls = 0
    $script:ResolvedLanguages = @()
    $script:RussianSubtitleVerboseDiagnostics = $null
    $script:CapturedRussianSubtitlePlayerClient = $null
    $script:CapturedRussianSubtitleMaxAttempts = $null
    $script:CapturedRussianSubtitleIgnoreNoFormatsError = $null
    $script:BgutilStartResult = $true
    $script:ProviderAvailable = $ProviderAvailable
    $script:RussianTrackAvailable = $RussianTrackAvailable

    function Start-BgutilProviderIfNeeded {
        $script:StartCalls++
        return $script:BgutilStartResult
    }

    function Wait-BgutilProviderReady {
        $script:WaitCalls++
        return $script:ProviderAvailable
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
        if ($Language -eq 'ru' -and $script:RussianTrackAvailable) {
            return [pscustomobject]@{ Kind = 'auto'; Key = 'ru' }
        }
        return $null
    }
    function Download-SubtitleSrt {
        param(
            [string]$VideoUrl,
            $Track,
            [string]$TargetPath,
            [string]$TempRoot,
            [string]$PlayerClient = '',
            [int]$MaxAttempts = 0,
            [switch]$IgnoreNoFormatsError,
            [switch]$VerboseDiagnostics
        )
        if ($Track.Key -eq 'ru') {
            $script:RussianSubtitleVerboseDiagnostics = $VerboseDiagnostics.IsPresent
            $script:CapturedRussianSubtitlePlayerClient = $PlayerClient
            $script:CapturedRussianSubtitleMaxAttempts = $MaxAttempts
            $script:CapturedRussianSubtitleIgnoreNoFormatsError = $IgnoreNoFormatsError.IsPresent
        }
        return $false
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
            RussianSubtitleVerboseDiagnostics = $script:RussianSubtitleVerboseDiagnostics
            RussianSubtitlePlayerClient = $script:CapturedRussianSubtitlePlayerClient
            RussianSubtitleMaxAttempts = $script:CapturedRussianSubtitleMaxAttempts
            RussianSubtitleIgnoreNoFormatsError = $script:CapturedRussianSubtitleIgnoreNoFormatsError
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

$diagnosticsOnly = Invoke-ProcessVideoScenario -EnableRussianSubtitles $false -EnableRussianSubtitleDiagnostics $true
if ($diagnosticsOnly.StartCalls -ne 0 -or $diagnosticsOnly.WaitCalls -ne 0 -or $diagnosticsOnly.ResolvedLanguages -contains 'ru') {
    throw '-RusubVerboseDiag must not enable Russian subtitle processing without -AddRusub.'
}

$withSwitch = Invoke-ProcessVideoScenario -EnableRussianSubtitles $true
if ($withSwitch.StartCalls -ne 1) {
    throw "With -AddRusub, bgutil was started $($withSwitch.StartCalls) time(s); expected 1."
}
if ($withSwitch.WaitCalls -ne 1) {
    throw "With -AddRusub, the Russian subtitle branch ran $($withSwitch.WaitCalls) time(s); expected 1."
}

$withRussianTrack = Invoke-ProcessVideoScenario -EnableRussianSubtitles $true -ProviderAvailable $true -RussianTrackAvailable $true
if ($withRussianTrack.RussianSubtitleVerboseDiagnostics -ne $false) {
    throw 'The Russian subtitle branch enabled verbose diagnostics without -RusubVerboseDiag.'
}
if ($withRussianTrack.RussianSubtitlePlayerClient -ne 'web') {
    throw "The Russian subtitle branch used player_client=$($withRussianTrack.RussianSubtitlePlayerClient); expected web."
}
if ($withRussianTrack.RussianSubtitleMaxAttempts -ne 1) {
    throw "The Russian subtitle branch allowed $($withRussianTrack.RussianSubtitleMaxAttempts) attempts; expected 1."
}
if ($withRussianTrack.RussianSubtitleIgnoreNoFormatsError -ne $true) {
    throw 'The Russian subtitle branch must ignore missing media formats.'
}

$withRussianDiagnostics = Invoke-ProcessVideoScenario -EnableRussianSubtitles $true `
    -EnableRussianSubtitleDiagnostics $true -ProviderAvailable $true -RussianTrackAvailable $true
if ($withRussianDiagnostics.RussianSubtitleVerboseDiagnostics -ne $true) {
    throw 'The Russian subtitle branch did not enable verbose diagnostics with -RusubVerboseDiag.'
}

Write-Host '[PASS] -AddRusub gates bgutil and Russian subtitle processing.'
