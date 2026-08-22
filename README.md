# YouTube yt-dlp (Multi-Audio & Subtitles) - Workflow scripts for Windows

> A complete, production-ready workflow for downloading YouTube videos with:
> - **1080p** video in `AVC1/H.264 + M4A/AAC`;
> - **Multiple audio tracks** (Original & Russian);
> - **Subtitles** (original + translated Russian captions as external `.srt`);
> - **PO Token Provider** via `bgutil-ytdlp-pot-provider`;
> - **Organized output** to `D:\TempD` (with backups in `D:\Trainings\yt-dlp`).

---

## Quick Overview

The repository contains two core scripts:

| Script | Purpose |
|--------|---------|
| `download_yt-dlp_ru_v2_mkv.bat` | Simple batch downloader for **MKV + Original audio + Russian audio**, using the PO Token infrastructure. |
| `download_yt-dlp_ru_v2_mp4.bat` | Simple batch downloader for **MP4 + Original audio + Russian audio**, using the PO Token infrastructure. |
| `download_yt-dlp_subs_v7.ps1` | Advanced PowerShell orchestration layer: **MP4** video + multi-audio + external SRT subtitles + HTTP PO Token Provider via `bgutil`. |
---

## File Structure

```
.
+-- download_yt-dlp_ru_v2_mkv.bat                 # Batch entrypoint (for .mkv output)
+-- download_yt-dlp_ru_v2_mp4.bat                 # Batch entrypoint (for .mp4 output)
+-- download_yt-dlp_subs_v7.ps1                   # PowerShell orchestration
+-- info/                                         # Obsidian notes with internal docs
¦   YouTube yt-dlp (multi-audio & subtitles)*.md  # Full configuration & troubleshooting notes
L-- README.md                                     # This file
```

---

## Features

- Downloads **1080p** video with **AVC1/H.264** codec and **M4A/AAC** audio.
- Merges **Original** and **Russian** audio tracks into a single MP4.
- Extracts **Original** subtitles as `.srt` (embedded in the container).
- Attempts to download **translated Russian captions** as external `.srt`.
- Uses the **`bgutil` HTTP PO Token Provider** to avoid `HTTP 429 Too Many Requests`.
- All output is saved to `D:\TempD`; a copy is also stored in `D:\Trainings\yt-dlp`.
- Verified to work with modern YouTube extractors and `yt-dlp` plugins.

---

## Requirements

- **Windows OS** (tested on Windows 10/11)
- **`yt-dlp.exe`** – standalone Windows executable
- **`ffmpeg.exe`** – for merging/remuxing video, audio, and subtitles
- **`bgutil-ytdlp-pot-provider`** – HTTP PO Token Provider running on `127.0.0.1:4416`

> **Important**: The provider must be running inside script `download_yt-dlp_subs_v7.ps1`.  
> You can verify it with:  
> ```powershell
> curl http://127.0.0.1:4416/ping
> ```

---

## Quick Start

1. **Place the scripts** in your working directory.
2. **Ensure `yt-dlp.exe` and `ffmpeg.exe`** are in your `PATH` or in the same folder.
3. **Start the `bgutil` HTTP PO Token Provider** (on `127.0.0.1:4416`).
4. **Run one of the scripts:**

   ```cmd
   download_yt-dlp_ru_v2_mkv.bat
   ```
   or
   ```cmd
   download_yt-dlp_ru_v2_mp4.bat
   ```   
   or
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File "<path_to_directory>\download_yt-dlp_subs_v7.ps1"
   ```
5. Past <YouTube-URL>
6. **Check the output** in `D:\TempD` (and `D:\Trainings\yt-dlp` for backups).

---

## Technical Details

| Component | Detail |
|-----------|--------|
| **Video Format** | `bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best` |
| **Audio Tracks** | Original + Russian (merged via `ffmpeg`) |
| **Subtitles** | Original embedded `.srt` + translated Russian external `.srt` |
| **PO Token Provider** | HTTP endpoint `http://127.0.0.1:4416`, accessed via `--extractor-args "youtube:player-client=android,web;po_token_provider=bgutil:http"` |
| **Output Directory** | `D:\TempD` (primary), `D:\Trainings\yt-dlp` (backup) |
| **Orchestration** | `PowerShell > cmd.exe > yt-dlp > PowerShell` (for retry logic and subtitle handling) |

---

## Known Limitations

- **Translated Russian captions** may fail due to `HTTP 429 Too Many Requests` if the PO Token Provider is not fully warmed up.
- The workflow is **version-sensitive**: YouTube extractor, `player_client`, PO Token enforcement, format IDs, and caption endpoints change frequently.
- Always keep `yt-dlp` and `bgutil` updated to the latest versions.

---

## Documentation

For detailed configuration, troubleshooting, and version-specific notes, see the files in the `info/` folder.  
They contain:

- Full `ffmpeg` parameters
- PO Token provider setup
- Multi-audio embedding logic
- Obsidian-style markdown notes

---

## Verified On

- `yt-dlp` latest stable Windows build
- `ffmpeg` latest release
- `bgutil-ytdlp-pot-provider` running locally
- YouTube extractor with `android` / `web` player clients

---

## Contributing

Found a bug or have an improvement? Feel free to open an issue or submit a pull request.  
Please keep the **version-sensitive** nature in mind when updating dependencies or extraction logic.

---

