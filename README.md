# YouTube yt-dlp (Multi-Audio & Subtitles) — Windows Workflow Scripts

A set of local scripts for downloading videos from YouTube with `yt-dlp` and `ffmpeg`:

- video up to `1080p`, preferring `AVC1/H.264 + M4A/AAC`;
- the original audio track;
- an additional Russian audio track when available and the original language is not Russian;
- external `.srt` subtitles in the advanced PowerShell workflow.

> YouTube extractor behavior, formats, `player_client`, PO Token enforcement, and translated captions depend on the versions of `yt-dlp`, its plugins, and YouTube itself.

---

## Scripts

| Script | Container | Audio | Subtitles | `bgutil` |
|---|---|---|---|---|
| `download_yt-dlp_v2.bat` | Determined by the selected formats and `yt-dlp` merge behavior | One selected audio track | None | Neither starts nor explicitly uses it |
| `download_yt-dlp_ru_v2_mp4.bat` | MP4 | Original + Russian, when available | None | Neither starts nor explicitly uses it |
| `download_yt-dlp_ru_v2_mkv.bat` | MKV when Russian is added; MP4 in the fallback branch without a separate Russian track | Original + Russian, when available | None | Neither starts nor explicitly uses it |
| `download_yt-dlp_subs_v7.ps1` | MP4 | Original + Russian, when available | External Original `.srt`; external Russian `.srt` only with `-AddRusub` | Started automatically only with `-AddRusub` |

All four scripts operate independently: the PowerShell script does not invoke the BAT files.

---

## Features

### General Video and Audio Policy

- The maximum resolution is `1080p`.
- `AVC1/H.264` video and `M4A/AAC` audio are preferred.
- The original audio track is always preserved.
- If the original language is not Russian and a suitable Russian track is found, it is downloaded separately and added with `ffmpeg` without transcoding (`-c copy`).
- Original is marked as the default audio track; Russian is added as a selectable track.
- Playlists are disabled with `--no-playlist`.

Primary format selector:

```text
bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best
```

### Original Base Version

`download_yt-dlp_v2.bat` is a simple interactive downloader for YouTube, Kinescope, and other sites supported by `yt-dlp`.

- It requests one URL in an interactive loop.
- It downloads video up to `1080p` with the same `AVC1/H.264 + M4A/AAC` selector.
- It uses one audio track selected by `yt-dlp` as `bestaudio[ext=m4a]`.
- It does not read metadata to determine languages.
- It does not find or add a separate Russian audio track.
- It does not download subtitles.
- It neither starts nor explicitly uses `bgutil`.
- It does not enforce the final container with `--merge-output-format`, so the output extension depends on the selected formats and `yt-dlp` merge behavior.

This version is suitable for a regular single download without multi-audio or subtitle orchestration.

### PowerShell Workflow with Subtitles

`download_yt-dlp_subs_v7.ps1` additionally:

- determines the original language from YouTube metadata;
- saves original-language subtitles as a separate `.srt`, preferring manual subtitles and using automatic captions as a fallback;
- attempts to save a separate Russian `.srt` when `-AddRusub` is enabled;
- uses `player_client=web`, `--ignore-no-formats-error`, and the local `bgutil` HTTP PO Token Provider for one Russian subtitle attempt; verbose diagnostics are optional;
- starts `bgutil` asynchronously, waits for it to become ready, and stops only a process that it started itself;
- treats missing or failed subtitles as non-fatal to the video download.

Subtitles are not embedded in the final MP4.

---

## The `-AddRusub` Option

`download_yt-dlp_subs_v7.ps1` provides the `$AddRusub` switch parameter, which is disabled by default.

- Without `-AddRusub`, Russian subtitles are disabled and `bgutil` is not started.
- With `-AddRusub`, the Russian `.srt` generation branch is enabled.
- Original-language subtitles and the Russian audio track are independent of this parameter.
- If the original language is already Russian, no duplicate Russian `.srt` is created.

The `$RusubVerboseDiag` switch parameter is also disabled by default. It adds `yt-dlp --verbose` only to the Russian subtitle request and does not enable Russian subtitles by itself.

| Parameters | Behavior |
|---|---|
| none | Russian subtitles are disabled |
| `-AddRusub` | One Russian request through `player_client=web`, with normal output |
| `-AddRusub -RusubVerboseDiag` | One Russian request through `player_client=web`, with verbose diagnostics |
| `-RusubVerboseDiag` only | Diagnostics have no effect because the Russian branch is disabled |

Russian translated captions are disabled by default because the requests are unstable: YouTube frequently responds with `HTTP 429 Too Many Requests`, after which a delayed retry or script restart may not restore downloading. Therefore, `-AddRusub` is an explicit opt-in option, while the main workflow remains operational without Russian subtitles.

Run with Russian subtitles:

```powershell
.\download_yt-dlp_subs_v7.ps1 -AddRusub -Url "https://youtube.com/..."
```

Diagnostic run with Russian subtitles:

```powershell
.\download_yt-dlp_subs_v7.ps1 -AddRusub -RusubVerboseDiag -Url "https://youtube.com/..."
```

Run without Russian subtitles:

```powershell
.\download_yt-dlp_subs_v7.ps1 -Url "https://youtube.com/..."
```

Interactive mode without `-Url` is also supported:

```powershell
.\download_yt-dlp_subs_v7.ps1 -AddRusub
```

If the PowerShell execution policy blocks local scripts:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\download_yt-dlp_subs_v7.ps1" -AddRusub -Url "https://youtube.com/..."
```

---

## Quick Start for BAT Scripts

The BAT files run interactively and request a URL after launch:

```cmd
download_yt-dlp_v2.bat
```

or:

```cmd
download_yt-dlp_ru_v2_mp4.bat
```

or:

```cmd
download_yt-dlp_ru_v2_mkv.bat
```

`download_yt-dlp_ru_v2_mkv.bat` creates an MKV when it adds a separate Russian audio track. If a separate Russian track is not required or cannot be found, the current fallback branch downloads an MP4.

---

## Requirements

For all workflows:

- Windows;
- `yt-dlp.exe` in `D:\Trainings\yt-dlp`;
- `ffmpeg.exe` in `D:\Trainings\yt-dlp`;
- Node.js in `PATH`, because the scripts pass `--js-runtimes node`.

Additionally, for Russian subtitles through `-AddRusub`:

- a built `bgutil-ytdlp-pot-provider` server at `D:\Trainings\yt-dlp\bgutil-ytdlp-pot-provider\server\build\main.js`;
- a compatible `bgutil` plugin for `yt-dlp`.

The provider does not need to be started manually before running the PowerShell script. If a compatible provider is already available on a loopback address and port `4416`, the script uses it and does not stop it when processing finishes.

Check an already running provider:

```powershell
Invoke-RestMethod http://127.0.0.1:4416/ping
```

---

## Output Files

The scripts select one output directory:

1. `D:\TempD`, if the directory exists;
2. otherwise, `D:\Trainings\yt-dlp`.

No automatic backup copy is created in the other directory.

Example file names:

```text
Title [video-id].mp4
Title [video-id] [Original+RUS].mp4
Title [video-id] [Original+RUS].mkv
Title [video-id].en.srt
Title [video-id].ru.srt
```

When a Russian audio track is added to the video, the base name of the external subtitles also includes `[Original+RUS]`.

---

## Project Structure

```text
.
|-- download_yt-dlp_v2.bat
|-- download_yt-dlp_ru_v2_mkv.bat
|-- download_yt-dlp_ru_v2_mp4.bat
|-- download_yt-dlp_subs_v7.ps1
|-- yt-dlp.exe
|-- ffmpeg.exe
|-- bgutil-ytdlp-pot-provider/
|-- yt-dlp-plugins/
|-- info/
|   `-- YouTube yt-dlp (multi-audio & subtitles) - конспект и практический runbook.md
|-- README_RU.md
`-- README.md
```

---

## Limitations and Troubleshooting

- If no suitable Russian audio track is available, only Original is retained.
- Russian translated captions may temporarily fail with YouTube errors, including `HTTP 429 Too Many Requests`.
- The PowerShell workflow retains controlled retries for original-language subtitles, but makes only one diagnostic Russian subtitle attempt; a subtitle failure does not remove a successfully downloaded video.
- For `bgutil` problems, check Node.js, `server\build\main.js`, the installed plugin, and the `bgutil-provider.stdout.log` and `bgutil-provider.stderr.log` files.
- After updating `yt-dlp` or `bgutil`, verify the available formats and subtitle behavior again.

The `info/` directory contains a detailed runbook for setup and troubleshooting.
