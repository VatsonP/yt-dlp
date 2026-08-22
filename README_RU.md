# YouTube yt-dlp (Multi-Audio & Subtitles) — Windows workflow scripts

Набор локальных скриптов для скачивания видео с YouTube через `yt-dlp` и `ffmpeg`:

- видео до `1080p` с предпочтением `AVC1/H.264 + M4A/AAC`;
- оригинальная аудиодорожка;
- дополнительная русская аудиодорожка, если она доступна и язык оригинала не русский;
- внешние `.srt`-субтитры в расширенном PowerShell-сценарии.

> Поведение YouTube extractor, форматы, `player_client`, PO Token и translated captions зависят от версий `yt-dlp`, его плагинов и YouTube.

---

## Скрипты

| Скрипт | Контейнер | Аудио | Субтитры | `bgutil` |
|---|---|---|---|---|
| `download_yt-dlp_v2.bat` | Определяется выбранными форматами и merge-поведением `yt-dlp` | Одна выбранная аудиодорожка | Нет | Не запускает и явно не использует |
| `download_yt-dlp_ru_v2_mp4.bat` | MP4 | Original + Russian, если доступна | Нет | Не запускает и явно не использует |
| `download_yt-dlp_ru_v2_mkv.bat` | MKV при добавлении Russian; MP4 в fallback-ветке без отдельной Russian | Original + Russian, если доступна | Нет | Не запускает и явно не использует |
| `download_yt-dlp_subs_v7.ps1` | MP4 | Original + Russian, если доступна | Внешний Original `.srt`; внешний Russian `.srt` только с `-AddRusub` | Автоматически запускается только с `-AddRusub` |

Все четыре скрипта работают самостоятельно: PowerShell-скрипт не вызывает BAT-файлы.

---

## Возможности

### Общая политика видео и аудио

- Максимальное разрешение — `1080p`.
- Предпочитается видео `AVC1/H.264` и аудио `M4A/AAC`.
- Оригинальная аудиодорожка сохраняется всегда.
- Если язык оригинала не русский и подходящая русская дорожка найдена, она скачивается отдельно и добавляется через `ffmpeg` без перекодирования (`-c copy`).
- Original помечается как аудиодорожка по умолчанию; Russian добавляется как переключаемая дорожка.
- Плейлисты отключены через `--no-playlist`.

Основной selector:

```text
bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best
```

### Первоначальная базовая версия

`download_yt-dlp_v2.bat` — простой интерактивный downloader для YouTube, Kinescope и других сайтов, поддерживаемых `yt-dlp`.

- запрашивает один URL в интерактивном цикле;
- скачивает видео до `1080p` с тем же selector `AVC1/H.264 + M4A/AAC`;
- использует одну аудиодорожку, выбранную `yt-dlp` как `bestaudio[ext=m4a]`;
- не читает метаданные для определения языков;
- не ищет и не добавляет отдельную русскую аудиодорожку;
- не скачивает субтитры;
- не запускает и явно не использует `bgutil`;
- не закрепляет итоговый контейнер через `--merge-output-format`, поэтому расширение результата зависит от выбранных форматов и merge-поведения `yt-dlp`.

Эта версия подходит, когда нужен обычный одиночный download без multi-audio и subtitle orchestration.

### PowerShell-сценарий с субтитрами

`download_yt-dlp_subs_v7.ps1` дополнительно:

- определяет язык оригинала по метаданным YouTube;
- сохраняет оригинальные субтитры отдельным `.srt` — сначала manual, затем automatic captions как fallback;
- при включённом `-AddRusub` пытается сохранить отдельный русский `.srt`;
- для русских субтитров использует `player_client=android_vr` и локальный HTTP PO Token Provider `bgutil`;
- запускает `bgutil` асинхронно, ожидает его готовности и останавливает только тот процесс, который запустил сам;
- не считает отсутствие или ошибку субтитров фатальной ошибкой загрузки видео.

Субтитры не встраиваются в итоговый MP4.

---

## Опция `-AddRusub`

В `download_yt-dlp_subs_v7.ps1` доступен switch-параметр `$AddRusub`, выключенный по умолчанию.

- Без `-AddRusub` русские субтитры отключены и `bgutil` не запускается.
- С `-AddRusub` включается блок формирования русского `.srt`.
- Оригинальные субтитры и русская аудиодорожка от этого параметра не зависят.
- Если оригинальный язык уже русский, отдельный дублирующий русский `.srt` не создаётся.

Русские translated captions отключены по умолчанию из-за нестабильности запросов: YouTube часто отвечает `HTTP 429 Too Many Requests`, после чего задержка перед повтором и перезапуск сценария могут не восстановить загрузку. Поэтому `-AddRusub` используется как осознанная дополнительная опция, а основной workflow сохраняет работоспособность без русских субтитров.

Запуск с русскими субтитрами:

```powershell
.\download_yt-dlp_subs_v7.ps1 -AddRusub -Url "https://youtube.com/..."
```

Запуск без русских субтитров:

```powershell
.\download_yt-dlp_subs_v7.ps1 -Url "https://youtube.com/..."
```

Интерактивный запуск без `-Url` также поддерживается:

```powershell
.\download_yt-dlp_subs_v7.ps1 -AddRusub
```

Если политика выполнения PowerShell блокирует локальные сценарии:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\download_yt-dlp_subs_v7.ps1" -AddRusub -Url "https://youtube.com/..."
```

---

## Быстрый запуск BAT-скриптов

BAT-файлы работают интерактивно и запрашивают URL после запуска:

```cmd
download_yt-dlp_v2.bat
```

или:

```cmd
download_yt-dlp_ru_v2_mp4.bat
```

или:

```cmd
download_yt-dlp_ru_v2_mkv.bat
```

`download_yt-dlp_ru_v2_mkv.bat` формирует MKV, когда добавляет отдельную русскую аудиодорожку. Если отдельная русская дорожка не нужна или не найдена, текущая fallback-ветка скачивает MP4.

---

## Требования

Для всех сценариев:

- Windows;
- `yt-dlp.exe` в `D:\Trainings\yt-dlp`;
- `ffmpeg.exe` в `D:\Trainings\yt-dlp`;
- Node.js в `PATH`, поскольку скрипты передают `--js-runtimes node`.

Дополнительно для русских субтитров через `-AddRusub`:

- собранный сервер `bgutil-ytdlp-pot-provider`: `D:\Trainings\yt-dlp\bgutil-ytdlp-pot-provider\server\build\main.js`;
- совместимый плагин `bgutil` для `yt-dlp`.

Вручную запускать provider перед PowerShell-скриптом не требуется. Если совместимый provider уже доступен на loopback-адресе и порту `4416`, скрипт использует его и не останавливает после завершения.

Проверка уже запущенного provider:

```powershell
Invoke-RestMethod http://127.0.0.1:4416/ping
```

---

## Выходные файлы

Скрипты выбирают одну выходную папку:

1. `D:\TempD`, если папка существует;
2. иначе `D:\Trainings\yt-dlp`.

Автоматическая резервная копия во вторую папку не создаётся.

Примеры имён:

```text
Title [video-id].mp4
Title [video-id] [Original+RUS].mp4
Title [video-id] [Original+RUS].mkv
Title [video-id].en.srt
Title [video-id].ru.srt
```

Если в видео добавлена русская аудиодорожка, базовое имя внешних субтитров также содержит `[Original+RUS]`.

---

## Структура проекта

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
`-- README.md
```

---

## Ограничения и диагностика

- Если подходящая русская аудиодорожка отсутствует, сохраняется только Original.
- Русские translated captions могут временно завершаться ошибкой YouTube, включая `HTTP 429 Too Many Requests`.
- PowerShell-сценарий делает контролируемые повторные попытки скачивания субтитров; ошибка субтитров не удаляет успешно скачанное видео.
- При проблемах с `bgutil` проверьте Node.js, файл `server\build\main.js`, установленный плагин и журналы `bgutil-provider.stdout.log` и `bgutil-provider.stderr.log`.
- После обновления `yt-dlp` или `bgutil` проверяйте доступные форматы и поведение субтитров заново.

Подробный runbook с настройкой и диагностикой находится в папке `info/`.
