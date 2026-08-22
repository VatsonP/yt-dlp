---
title: YouTube yt-dlp (multi-audio & subtitles) - конспект и практический runbook
tags:
  - yt-dlp
  - youtube
  - ffmpeg
  - powershell
  - bat
  - subtitles
  - multi-audio
  - po-token
  - bgutil
  - nodejs
  - obsidian
  - runbook
status: verified
platform: Windows 10
working_dir: D:\Trainings\yt-dlp
preferred_output: D:\TempD
---

# YouTube yt-dlp (multi-audio & subtitles) - конспект и практический runbook (ChatGPT)

> [!question] Центральный вопрос
> Как построить на Windows воспроизводимый локальный workflow для YouTube, который:
> 1. скачивает видео до `1080p` с предпочтением `AVC1/H.264 + M4A/AAC`;
> 2. сохраняет оригинальную аудиодорожку;
> 3. при наличии добавляет русскую аудиодорожку как вторую переключаемую дорожку;
> 4. в расширенном сценарии дополнительно сохраняет внешние `.srt` субтитры на языке оригинала и на русском;
> 5. корректно работает с современными ограничениями YouTube через `bgutil-ytdlp-pot-provider`;
> 6. сохраняет итог в `D:\TempD`, а при отсутствии этой папки — в `D:\Trainings\yt-dlp`.

> [!note] Назначение заметки
> Это не архив диалога, а опорная Obsidian-note для повторяемой установки, эксплуатации и диагностики. Она должна позволить спустя время восстановить не только команды, но и исходную логику решений: почему используются два разных скрипта, зачем нужен `ffmpeg`, почему multi-audio собирается в MP4, зачем для русских translated captions понадобился PO Token Provider и почему `bgutil` запускается асинхронно.

> [!important] Ключевой вывод
> Практически здесь используются два уровня сложности:
>
> - `download_yt-dlp_ru_v2_mp4.bat` — простой и стабильный downloader для `MP4 + Original audio + Russian audio`, без внешних субтитров и без PO Token infrastructure.
> - `download_yt-dlp_subs_v7.ps1` — расширенный orchestration layer: видео + multi-audio + external SRT + управление локальным `bgutil` HTTP PO Token Provider.
>
> Второй скрипт не вызывает первый. Это сознательное решение: PowerShell самостоятельно выполняет весь workflow и не создает лишнюю связность `PowerShell -> cmd.exe -> yt-dlp -> PowerShell`.

> [!success] Verified на рабочей конфигурации
> В ходе настройки фактически подтверждено:
>
> - `yt-dlp.exe` работает как standalone Windows executable;
> - локальный `ffmpeg.exe` используется для merge/remux и преобразования subtitle formats;
> - итоговый MP4 может содержать две переключаемые AAC-дорожки `Original` и `Russian`;
> - внешний `Original .srt` успешно скачивается и конвертируется;
> - прямые translated Russian captions без provider могли возвращать `HTTP 429 Too Many Requests`;
> - `bgutil` HTTP provider был успешно поднят на `127.0.0.1:4416`;
> - `/ping` возвращал рабочую версию provider;
> - `yt-dlp` обнаруживал `bgutil:http` provider через plugin;
> - после подключения HTTP provider русские субтитры успешно скачивались и конвертировались в `.srt`;
> - финальная `v7` с ранним асинхронным запуском provider заработала как единый процесс.

> [!warning] Version-sensitive
> Поведение YouTube extractor, `player_client`, PO Token enforcement, translated captions и format IDs меняется со временем. Поэтому команды и архитектура ниже являются проверенной конфигурацией на момент настройки, но `yt-dlp` и `bgutil` следует считать version-sensitive компонентами.

---

# Часть I. `download_yt-dlp_ru_v2_mp4.bat`

## 1. Scope

Этот скрипт решает одну конкретную задачу:

```text
YouTube URL
    |
    v
video <= 1080p
+
Original audio
+
Russian audio (если есть и original != ru)
    |
    v
MP4
```

Он не занимается внешними субтитрами и не требует `bgutil`.

Это хороший default downloader для тех случаев, когда нужен обычный локальный видеоролик с двумя переключаемыми звуковыми дорожками.

---

## 2. Что именно делает скрипт

### 2.1 Базовая policy

Видео:

```text
max resolution: 1080p
preferred video codec: AVC1 / H.264
preferred audio container: M4A
final container: MP4
```

Ключевой format selector:

```text
bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best
```

Смысл:

1. сначала попытаться взять лучший `video-only` до 1080p с `avc1`;
2. добавить лучшую `m4a` audio;
3. если такой split-вариант недоступен — fallback на лучший готовый MP4;
4. если и это невозможно — fallback на `best`.

> [!important] Почему AVC1 + M4A
> Это сознательный выбор в пользу бытовой совместимости:
>
> - `AVC1/H.264` хорошо поддерживается Windows, Android, iPhone, Smart TV и большинством hardware decoders;
> - `M4A/AAC` естественно подходит для MP4;
> - финальный multi-audio файл можно собрать через `ffmpeg -c copy`, без повторного кодирования.

---

## 3. Логика определения original и Russian audio

Скрипт сначала выполняет:

```text
yt-dlp --dump-single-json
```

и сохраняет metadata во временный JSON.

Затем встроенный PowerShell-фрагмент:

1. получает все форматы, где есть audio codec и language;
2. пытается найти дорожку, помеченную как `original`;
3. если явного признака `original` нет — использует `language_preference` и bitrate как fallback;
4. определяет `origLang`;
5. собирает все форматы с языком, начинающимся на `ru`;
6. предпочитает `audio-only`;
7. если Russian доступен только внутри HLS/video+audio stream — выбирает подходящий Russian format и позже берет из него только audio stream.

Концептуально:

```text
formats[]
   |
   +--> find original audio
   |
   +--> find ru*
          |
          +--> audio-only? -> prefer
          |
          +--> otherwise use media stream as Russian audio source
```

---

## 4. Почему Russian audio скачивается отдельно

Если original не русский и Russian audio найден, процесс разделяется на два независимых download:

```text
Download A:
video + original audio
        |
        v
source.mp4

Download B:
Russian format
        |
        v
russian.<ext>
```

После этого `ffmpeg` выполняет remux:

```text
source video
source original audio
Russian audio
        |
        v
final [Original+RUS].mp4
```

Ключевое свойство:

```text
-c copy
```

Это означает:

- video не перекодируется;
- original audio не перекодируется;
- Russian audio не перекодируется;
- качество не меняется;
- операция в основном ограничена mux/container I/O.

---

## 5. Почему MP4, а не MKV

Первоначально multi-audio workflow удобно было собирать в MKV, потому что Matroska очень гибок к нескольким stream.

Но в текущей policy специально выбираются:

```text
Video: AVC1 / H.264
Audio: AAC / M4A
```

Это полностью совместимо с MP4.

Поэтому итог:

```text
MP4
├── Video: H.264 / AVC1
├── Audio #1: AAC - Original (default)
└── Audio #2: AAC - Russian
```

Преимущества:

- высокая совместимость с Windows;
- Android/iOS;
- Smart TV;
- браузерные/медиа экосистемы;
- медиасерверы;
- нет transcoding.

---

## 6. Metadata и disposition аудиодорожек

`ffmpeg` получает:

```text
Audio #1
title = Original
default = yes

Audio #2
title = Russian
language = rus
default = no
```

Это позволяет плееру показать две отдельные переключаемые дорожки.

> [!note] Ограничение
> Скрипт явно задает `language=rus` только для Russian track. Original track получает title `Original`, но ее ISO language tag может оставаться унаследованным/неопределенным в зависимости от исходного media metadata.

---

## 7. Output policy

Рабочая папка:

```text
D:\Trainings\yt-dlp
```

Preferred output:

```text
D:\TempD
```

Логика:

```text
if D:\TempD exists
    OUTPUT_DIR = D:\TempD
else
    OUTPUT_DIR = D:\Trainings\yt-dlp
```

Папка `D:\TempD` автоматически не создается.

Это позволяет отделить:

```text
Tools / scripts / dependencies
    D:\Trainings\yt-dlp

Downloaded media
    D:\TempD
```

---

## 8. Temporary workspace

Для каждой операции создается уникальная папка:

```text
%TEMP%\yt-dlp-ru-<random>-<random>
```

Там временно находятся:

```text
metadata.json
orig_lang.txt
ru_id.txt
final_name.txt
source.mp4
russian.<ext>
```

После завершения temporary directory удаляется.

Преимущество:

- рабочая папка не загрязняется промежуточными файлами;
- имена параллельных/повторных запусков меньше конфликтуют;
- при успешной операции остается только final media.

---

## 9. Main flow

```text
START
  |
  v
Open D:\Trainings\yt-dlp
  |
  v
Resolve D:\TempD fallback
  |
  v
Prompt URL
  |
  v
Check yt-dlp.exe + ffmpeg.exe
  |
  v
Dump metadata JSON
  |
  v
Detect original language
  |
  v
Detect Russian audio
  |
  +------------------------------+
  |                              |
  | RU not needed / unavailable  | RU available and original != RU
  |                              |
  v                              v
normal MP4 download         download source MP4
  |                              |
  |                         download RU source
  |                              |
  |                         ffmpeg stream copy
  |                              |
  v                              v
<title> [id].mp4          <title> [id] [Original+RUS].mp4
```

---

## 10. Практический запуск

Из Explorer:

```text
double click download_yt-dlp_ru_v2_mp4.bat
```

или PowerShell/cmd:

```powershell
D:\Trainings\yt-dlp\download_yt-dlp_ru_v2_mp4.bat
```

Затем:

```text
Paste the video URL and press Enter:
```

---

## 11. Диагностика Part I

### `yt-dlp.exe was not found`

Проверить:

```powershell
Test-Path "D:\Trainings\yt-dlp\yt-dlp.exe"
```

### `ffmpeg.exe was not found`

```powershell
Test-Path "D:\Trainings\yt-dlp\ffmpeg.exe"
```

### Russian audio не найден

Сначала посмотреть доступные форматы:

```powershell
Set-Location "D:\Trainings\yt-dlp"

.\yt-dlp.exe -F "YOUTUBE_URL"
```

Или metadata:

```powershell
.\yt-dlp.exe `
  --js-runtimes node `
  --skip-download `
  --dump-single-json `
  "YOUTUBE_URL"
```

### `Requested format is not available`

YouTube постоянно меняет способ выдачи DASH/HLS/SABR formats.

Первое действие:

```powershell
.\yt-dlp.exe -U
```

или заменить standalone executable на свежий официальный release.

### MP4 собрался, но Russian track не виден

Проверить streams:

```powershell
.\ffmpeg.exe -hide_banner -i "FILE.mp4"
```

Ожидается:

```text
Stream #0:0 Video
Stream #0:1 Audio Original
Stream #0:2 Audio Russian
```

---

## 12. Criteria of success

> [!success] Part I считается рабочей, если:
>
> - URL обрабатывается;
> - итоговый файл сохраняется в `D:\TempD` при наличии папки;
> - original audio присутствует;
> - при доступном Russian дубляже появляется вторая переключаемая audio track;
> - итог — MP4;
> - `ffmpeg` выполняет stream copy без transcoding.

---

# Часть II. `download_yt-dlp_subs_v7.ps1`

## 13. Зачем понадобился отдельный PowerShell orchestration layer

Задача субтитров значительно сложнее, чем просто второй audio stream.

Нужно было одновременно управлять:

- metadata;
- original language;
- manual subtitles;
- automatic captions;
- translated Russian captions;
- HTTP 429;
- YouTube `player_client`;
- PO Token Provider;
- Node.js background process;
- retry policy;
- output naming;
- cleanup;
- lifecycle provider.

Для такого workflow BAT быстро становится плохо поддерживаемым.

Поэтому `PowerShell` здесь выступает как orchestration layer:

```text
PowerShell
   |
   +--> yt-dlp.exe
   |      +--> metadata
   |      +--> video
   |      +--> audio
   |      +--> subtitles
   |
   +--> ffmpeg.exe
   |
   +--> Node.js
          |
          +--> bgutil HTTP PO Token Provider
```

---

## 14. Главная политика `v7`

Видео/audio policy остается той же:

```text
<= 1080p
AVC1/H.264
M4A/AAC
MP4
Original always
Russian audio if original != ru and RU available
```

Дополнительно:

```text
External SRT subtitles
├── original language
└── Russian (only if original != Russian)
```

Russian subtitles не embed-ятся внутрь MP4.

---

## 15. Почему external `.srt`

Плюсы sidecar-файлов:

- легко открыть/редактировать;
- можно использовать независимо от video;
- удобно для LLM/RAG/transcription workflows;
- просто индексировать;
- можно заменить без remux media;
- большинство media players автоматически подхватывает их, если совпадает stem filename.

Пример:

```text
Video title [ID] [Original+RUS].mp4
Video title [ID] [Original+RUS].en.srt
Video title [ID] [Original+RUS].ru.srt
```

---

## 16. Subtitle selection policy

Для каждого языка приоритет:

```text
manual subtitle
    |
    +--> if unavailable
            |
            v
automatic caption
```

Для original language:

```text
original subtitles -> default YouTube client
```

Для Russian:

```text
original != ru
    |
    v
Russian subtitle/caption
    |
    v
player_client=android_vr
    |
    v
bgutil HTTP PO Token Provider
```

---

## 17. Что показала диагностика `HTTP 429`

Изначально Russian translated captions могли возвращать:

```text
HTTP Error 429: Too Many Requests
```

Были проверены:

- задержки;
- retries;
- другое видео;
- другой YouTube `player_client`.

Ключевой диагностический результат:

```text
другое видео
+
первая RU-попытка
+
android_vr
=
тот же HTTP 429
```

Это показало, что проблема не сводилась к одному video ID или слишком быстрым retries конкретного ролика.

Следующим уровнем стал PO Token Provider.

---

## 18. Что такое PO Token в этом контексте

YouTube использует Proof of Origin Token как часть attestation/anti-abuse механизма.

В современной модели `yt-dlp` различает token contexts:

```text
PO Token
├── GVS
├── Player
└── Subs
```

Для автоматизации рекомендуется provider plugin, а не ручное извлечение token.

В этой конфигурации используется:

```text
bgutil-ytdlp-pot-provider
```

и именно HTTP provider mode.

---

## 19. Почему HTTP provider, а не script-provider

`bgutil` поддерживает:

```text
1. HTTP server provider
2. generation script provider
```

Script-provider в тесте на Windows дал проблему:

```text
generate_once.js --version
timed out after 15 seconds
```

HTTP provider оказался лучше для этой конфигурации:

- запускается один Node.js process;
- работает через localhost;
- plugin обращается к нему по HTTP;
- меньше process-spawn overhead;
- provider можно прогреть заранее;
- легче диагностировать через `/ping`.

---

## 20. Local provider endpoint

Default endpoint:

```text
http://127.0.0.1:4416
```

Readiness check:

```text
GET /ping
```

Ожидаемый response:

```text
server_uptime : ...
version       : ...
```

В рабочем тесте provider успешно отвечал и определялся `yt-dlp` как:

```text
bgutil:http-... (external)
```

---

## 21. Почему provider запускается асинхронно

На Windows cold start Node/bgutil может быть заметно медленнее ожидаемого.

Если запускать provider непосредственно перед RU subtitles:

```text
EN done
   |
start bgutil
   |
block 30-90 sec
   |
RU
```

общее время увеличивается.

`v7` делает лучше:

```text
Start Process-Video
    |
    v
if provider absent -> start Node asynchronously
    |
    +--------------------------------------+
    |                                      |
    v                                      v
metadata/video/audio/original SRT     bgutil warming up
    |                                      |
    +------------------+-------------------+
                       |
                       v
               before RU subtitles
                       |
                  /ping check
                       |
          +------------+-------------+
          |                          |
        ready                    not ready
          |                          |
          v                    wait up to 90 sec
       RU request                   |
                                     v
                                  retry /ping
```

В большинстве случаев startup latency перекрывается временем скачивания видео и original subtitle.

---

## 22. Ownership model provider process

Очень важная деталь `v7`.

### Сценарий A. Provider уже запущен вручную

```text
v7 -> /ping -> provider exists
```

Тогда:

- v7 использует его;
- v7 НЕ останавливает его в конце.

### Сценарий B. Provider запустил сам v7

```text
v7 -> no /ping
   -> Start-Process node build/main.js
```

Тогда:

- v7 считает процесс своим;
- использует его;
- при завершении останавливает только этот process ID.

Это предотвращает разрушение чужого manually managed process.

---

## 23. Readiness policy

Настройки:

```powershell
$BgutilStartupTimeoutSeconds = 90
$BgutilPollIntervalMilliseconds = 1000
```

Это не означает фиксированную задержку 90 секунд.

Модель:

```text
for up to 90 seconds:
    check /ping every 1 second
    if ready -> continue immediately
```

Если provider готов через 7 секунд — скрипт продолжит примерно через 7 секунд.

---

## 24. Loopback compatibility

`v7` проверяет:

```text
http://127.0.0.1:4416/ping
http://localhost:4416/ping
http://[::1]:4416/ping
```

Это было добавлено потому, что Node server мог логировать:

```text
address [::]:4416
```

а поведение IPv4/IPv6 loopback на Windows может отличаться.

---

## 25. Russian subtitle request policy

После того как provider ready:

```text
safety delay: 2 sec
```

Затем:

```text
attempt 1
player_client=android_vr
+
bgutil HTTP provider
```

Если неудача:

```text
wait 15 sec
attempt 2
```

После второй ошибки:

```text
[WARN]
continue overall workflow
```

То есть RU subtitles являются optional enhancement, а не критическим условием сохранения video.

---

## 26. Почему нет длинных `60/90/120` retries

До PO Token Provider такие retries использовались как временная диагностика.

После успешного provider:

```text
long waits != primary solution
```

Они:

- замедляют процесс;
- не устраняют underlying anti-abuse/token issue;
- могут поддерживать soft block дополнительными запросами.

Поэтому `v7` оставляет только один контролируемый retry.

---

## 27. Почему при provider failure RU subtitles пропускаются

Fail-safe policy:

```text
provider unavailable
    |
    v
[WARN]
    |
    v
skip RU SRT
    |
    v
keep video + audio + original SRT
```

Это лучше, чем:

- падение всего process;
- потеря уже скачанного video;
- много минут retries;
- зависимость основного downloader от optional feature.

---

# 28. Полная установка конфигурации с нуля

## 28.1 Итоговая структура каталогов

Целевая структура:

```text
D:\Trainings\yt-dlp\
│
├── yt-dlp.exe
├── ffmpeg.exe
├── ffprobe.exe                  # рекомендуется, хотя два финальных скрипта напрямую его не требуют
│
├── download_yt-dlp_ru_v2_mp4.bat
├── download_yt-dlp_subs_v7.ps1
│
├── yt-dlp-plugins\
│   └── bgutil-ytdlp-pot-provider.zip
│
├── bgutil-ytdlp-pot-provider\
│   ├── package.json
│   ├── ...
│   └── server\
│       ├── package.json
│       ├── node_modules\
│       └── build\
│           ├── main.js
│           └── ...
│
├── bgutil-provider.stdout.log   # создается v7 при auto-start
└── bgutil-provider.stderr.log   # создается v7 при auto-start
```

Preferred download destination:

```text
D:\TempD\
```

Fallback:

```text
D:\Trainings\yt-dlp\
```

---

## 28.2 Создать рабочую папку

PowerShell:

```powershell
New-Item `
  -ItemType Directory `
  -Path "D:\Trainings\yt-dlp" `
  -Force

Set-Location "D:\Trainings\yt-dlp"
```

---

## 28.3 Установить `yt-dlp.exe`

Для standalone Windows installation удобно использовать официальный release executable.

Пример:

```powershell
Invoke-WebRequest `
  -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" `
  -OutFile "D:\Trainings\yt-dlp\yt-dlp.exe"
```

Проверка:

```powershell
D:\Trainings\yt-dlp\yt-dlp.exe --version
```

В проверенной конфигурации использовалась версия:

```text
2026.08.19
```

> [!warning] Update policy
> YouTube extractor меняется часто. При неожиданных `format unavailable`, SABR/HLS/PO Token проблемах первым делом проверять свежесть `yt-dlp`.

---

## 28.4 Установить FFmpeg

Нужен `ffmpeg.exe` в:

```text
D:\Trainings\yt-dlp\ffmpeg.exe
```

Рекомендуется также положить:

```text
D:\Trainings\yt-dlp\ffprobe.exe
```

Проверка:

```powershell
D:\Trainings\yt-dlp\ffmpeg.exe -version
```

Роль FFmpeg:

- merge video + audio;
- multi-audio MP4 mux;
- `-c copy`;
- VTT -> SRT conversion.

---

## 28.5 Установить Node.js

`bgutil` native HTTP provider требует Node.js.

Проверка:

```powershell
node --version
npm --version
```

В проверенной конфигурации:

```text
Node.js v24.16.0
npm 11.17.0
```

Минимальное требование `bgutil` в современной документации:

```text
Node.js >= 20
```

На Windows можно установить через официальный Node.js installer или package manager.

Пример через winget:

```powershell
winget install OpenJS.NodeJS
```

После установки открыть новый PowerShell и повторить:

```powershell
node --version
npm --version
```

---

## 28.6 Установить Git

Проверка:

```powershell
git --version
```

Проверенная конфигурация:

```text
git version 2.53.0.windows.2
```

Установка через winget:

```powershell
winget install Git.Git
```

---

## 28.7 Клонировать `bgutil-ytdlp-pot-provider`

Все компоненты храним рядом с `yt-dlp`:

```powershell
Set-Location "D:\Trainings\yt-dlp"

git clone `
  https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git
```

Получаем:

```text
D:\Trainings\yt-dlp\bgutil-ytdlp-pot-provider\
```

> [!note] Воспроизведение конкретной рабочей версии
> На фактически проверенной системе `/ping` возвращал `version = 1.3.2`.
> Если требуется строго воспроизвести тот же tag и он доступен в repository/release history, checkout следует делать явно:
>
> ```powershell
> git checkout 1.3.2
> ```
>
> Для будущей установки рациональнее использовать актуальный compatible release и держать repository/plugin одной версии.

---

## 28.8 Собрать Node provider

```powershell
Set-Location "D:\Trainings\yt-dlp\bgutil-ytdlp-pot-provider\server"

npm ci
npx tsc
```

Проверка:

```powershell
Test-Path ".\build\main.js"
```

Ожидается:

```text
True
```

Дополнительно:

```powershell
Test-Path ".\build\generate_once.js"
```

может быть полезен для диагностики script-provider, хотя `v7` использует HTTP mode.

---

## 28.9 Установить `bgutil` plugin для standalone yt-dlp

Создать plugin directory:

```powershell
$PluginDir = "D:\Trainings\yt-dlp\yt-dlp-plugins"

New-Item `
  -ItemType Directory `
  -Path $PluginDir `
  -Force
```

Скачать matching plugin ZIP из release `bgutil-ytdlp-pot-provider`.

Концептуально:

```text
D:\Trainings\yt-dlp\
└── yt-dlp-plugins\
    └── bgutil-ytdlp-pot-provider.zip
```

Для воспроизведения проверенной конфигурации использовался plugin, который `yt-dlp` определял как:

```text
bgutil:http-1.3.2
```

> [!important] Version matching
> Repository/provider и plugin ZIP лучше держать одной версии.

---

## 28.10 Проверить plugin discovery

```powershell
Set-Location "D:\Trainings\yt-dlp"

.\yt-dlp.exe `
  -v `
  --simulate `
  --js-runtimes node `
  "https://www.youtube.com/watch?v=VIDEO_ID"
```

Искать:

```text
Plugin directories:
D:\Trainings\yt-dlp\yt-dlp-plugins\...

PO Token Providers:
bgutil:http-...
```

---

## 28.11 Ручной тест HTTP provider

Запуск:

```powershell
Set-Location "D:\Trainings\yt-dlp\bgutil-ytdlp-pot-provider\server"

node .\build\main.js
```

Ожидаемо:

```text
Started POT server (...) on address [::]:4416
```

В другом PowerShell:

```powershell
Invoke-RestMethod `
  "http://127.0.0.1:4416/ping" |
  Format-List
```

Ожидаемо:

```text
server_uptime : ...
version       : ...
```

После теста:

```text
Ctrl+C
```

> [!success] Только после успешного `/ping`
> Имеет смысл переходить к автоматическому lifecycle через `download_yt-dlp_subs_v7.ps1`.

---

# 29. Установка двух финальных scripts

## 29.1 `download_yt-dlp_ru_v2_mp4.bat`

Разместить:

```text
D:\Trainings\yt-dlp\download_yt-dlp_ru_v2_mp4.bat
```

Файл должен быть Windows BAT с `CRLF`.

---

## 29.2 `download_yt-dlp_subs_v7.ps1`

Разместить:

```text
D:\Trainings\yt-dlp\download_yt-dlp_subs_v7.ps1
```

Рекомендуемая encoding:

```text
UTF-8 BOM
CRLF
```

---

# 30. PowerShell execution policy

Если Windows блокирует запуск local `.ps1`, проверить:

```powershell
Get-ExecutionPolicy -List
```

Для текущего пользователя можно применить:

```powershell
Set-ExecutionPolicy `
  -Scope CurrentUser `
  -ExecutionPolicy RemoteSigned
```

> [!warning] Scope
> Не менять machine-wide policy без необходимости. Для локального personal tooling обычно достаточно `CurrentUser`.

Разовый запуск без изменения policy:

```powershell
powershell.exe `
  -NoProfile `
  -ExecutionPolicy Bypass `
  -File "D:\Trainings\yt-dlp\download_yt-dlp_subs_v7.ps1"
```

---

# 31. Практический runbook Part II

## 31.1 Интерактивный запуск

```powershell
Set-Location "D:\Trainings\yt-dlp"

.\download_yt-dlp_subs_v7.ps1
```

Ввести URL.

---

## 31.2 CLI-запуск с URL

```powershell
.\download_yt-dlp_subs_v7.ps1 `
  "https://www.youtube.com/watch?v=VIDEO_ID"
```

Это предпочтительно для:

- automation;
- n8n;
- scheduled tasks;
- wrapper scripts.

---

## 31.3 Что должно происходить

Концептуальный console flow:

```text
[INFO] Starting bgutil HTTP PO Token Provider asynchronously...
[INFO] Provider process ID : ...
[INFO] Provider is warming up in parallel...

... metadata/video/audio ...

[INFO] Original subtitle: en-orig (auto)
[DONE] Saved subtitle: ...en.srt

[INFO] PO Token Provider is ready: http://127.0.0.1:4416/ping
[INFO] Waiting 2 seconds before requesting Russian subtitles...
[INFO] Russian subtitle client: android_vr
[INFO] PO Token Provider: bgutil HTTP (127.0.0.1:4416)
[DONE] Saved subtitle: ...ru.srt

[DONE] Processing completed.
[INFO] Stopping bgutil HTTP PO Token Provider...
[INFO] PO Token Provider stopped.
```

---

# 32. Naming model

Если есть Russian audio:

```text
<title> [video-id] [Original+RUS].mp4
<title> [video-id] [Original+RUS].en.srt
<title> [video-id] [Original+RUS].ru.srt
```

Если Russian audio отсутствует:

```text
<title> [video-id].mp4
<title> [video-id].en.srt
<title> [video-id].ru.srt
```

Если original language Russian:

```text
<title> [video-id].mp4
<title> [video-id].ru.srt
```

Вторая duplicate-Russian subtitle не создается.

---

# 33. Diagnostics и failure modes

## 33.1 `HTTP Error 429: Too Many Requests`

### Старое поведение

Без provider Russian translated captions могли стабильно получать `429`.

### Текущий first-line diagnostic

Проверить provider:

```powershell
Invoke-RestMethod `
  "http://127.0.0.1:4416/ping" |
  Format-List
```

Проверить plugin:

```powershell
.\yt-dlp.exe `
  -v `
  --simulate `
  --js-runtimes node `
  "YOUTUBE_URL"
```

### Не начинать с 60/90/120 retries

После внедрения provider длинные retry delays не являются основным способом исправления.

---

## 33.2 `PO Token Provider is not available`

Проверить:

```powershell
Test-Path `
  "D:\Trainings\yt-dlp\bgutil-ytdlp-pot-provider\server\build\main.js"
```

Проверить Node:

```powershell
node --version
```

Ручной старт:

```powershell
Set-Location `
  "D:\Trainings\yt-dlp\bgutil-ytdlp-pot-provider\server"

node .\build\main.js
```

---

## 33.3 Provider долго стартует

Это было реально обнаружено на Windows.

`v7` решает проблему не простым sleep, а двумя механизмами:

1. ранний asynchronous start;
2. readiness polling до 90 sec.

Логи:

```text
D:\Trainings\yt-dlp\bgutil-provider.stdout.log
D:\Trainings\yt-dlp\bgutil-provider.stderr.log
```

---

## 33.4 `/ping` сначала не работает, затем появляется

Это соответствует slow cold start.

Не нужно считать 90 sec фиксированным delay.

Правильная интерпретация:

```text
process exists
but service not ready yet
```

`v7` различает:

```text
Process started
!=
HTTP service ready
```

Это важное архитектурное различие.

---

## 33.5 `generate_once.js --version timed out`

Это script-provider path.

В текущей архитектуре:

```text
script-provider intentionally disabled
HTTP provider used
```

Не нужно лечить этот timeout в основном workflow, если HTTP provider работает.

---

## 33.6 `android_vr client ... requires a GVS PO Token`

Важно различать:

```text
GVS token context
Subs token context
```

Warning о media formats не обязательно означает failure subtitle download.

Критерий успеха RU SRT — реальный валидный `.srt`, а не отсутствие всех warning lines.

---

## 33.7 PowerShell ISE показывает `NativeCommandError`

Windows PowerShell ISE может визуально трактовать stderr native executable как `NativeCommandError`.

Это не всегда означает failure.

Смотреть:

- exit code;
- фактический `[ERROR]`;
- наличие final file.

Особенно `yt-dlp` warnings часто пишутся в stderr.

---

## 33.8 Subtitle download сообщил success, но файла нет

Эта ошибка была устранена в процессе развития scripts.

Корректный success criterion:

```text
yt-dlp call completed
AND
new .srt exists
AND
file size > 0
```

Нельзя полагаться только на текст stdout.

---

## 33.9 `D:\TempD` существует, но output идет в working directory

Правильные финальные scripts используют explicit `OUTPUT_DIR`.

Проверить консоль:

```text
Preferred folder: D:\TempD
Output folder   : D:\TempD
```

И саму папку:

```powershell
Test-Path "D:\TempD"
```

---

# 34. Update / maintenance runbook

## 34.1 Обновление yt-dlp

Для standalone executable:

```powershell
Set-Location "D:\Trainings\yt-dlp"

.\yt-dlp.exe -U
```

После update:

```powershell
.\yt-dlp.exe --version
```

---

## 34.2 Обновление bgutil provider

Перед обновлением сохранить working version/tag.

```powershell
Set-Location `
  "D:\Trainings\yt-dlp\bgutil-ytdlp-pot-provider"

git status
git fetch --tags
```

Далее переход на выбранный release/tag.

После update:

```powershell
Set-Location .\server

npm ci
npx tsc
```

Обязательно обновить matching plugin ZIP.

---

## 34.3 Regression smoke test после обновления

Проверить последовательно:

```text
1. yt-dlp --version
2. node --version
3. ffmpeg -version
4. Test-Path build\main.js
5. manual node build\main.js
6. /ping
7. yt-dlp -v -> bgutil:http visible
8. one normal video
9. one video with Original+RUS audio
10. one video with EN + RU SRT
```

> [!important] Не обновлять несколько moving parts без smoke test
> `yt-dlp`, YouTube extractor behavior и PO Token provider меняются независимо. При проблеме легче диагностировать один изменившийся слой.

---

# 35. System model: слои ответственности

Полезно мыслить конфигурацию не как "одну программу", а как несколько слоев.

```text
User / URL
    |
    v
Script orchestration
    |
    +--> yt-dlp extractor
    |      |
    |      +--> YouTube metadata/formats/subtitles
    |
    +--> ffmpeg
    |      |
    |      +--> mux/remux/convert
    |
    +--> bgutil plugin
           |
           +--> HTTP provider
                  |
                  +--> Node.js / BotGuard attestation
```

### Layer 1. Script

Отвечает за:

- policy;
- branching;
- filenames;
- retries;
- fallback;
- lifecycle.

### Layer 2. yt-dlp

Отвечает за:

- extraction;
- formats;
- metadata;
- subtitle endpoints;
- YouTube clients.

### Layer 3. ffmpeg

Отвечает за:

- container;
- stream mapping;
- stream copy;
- subtitle conversion.

### Layer 4. bgutil

Отвечает за:

- PO Token generation/provider integration.

---

# 36. Почему два финальных scripts сохраняются отдельно

## BAT

Использовать, когда нужно:

```text
video
+
Original audio
+
Russian audio
```

Плюсы:

- проще;
- меньше dependencies;
- быстрее старт;
- нет Node/bgutil lifecycle.

## PowerShell v7

Использовать, когда нужно:

```text
video
+
multi-audio
+
Original SRT
+
Russian SRT
```

Плюсы:

- richer workflow;
- explicit diagnostics;
- PO Token support;
- robust subtitle handling.

> [!important] Single responsibility
> Не нужно заставлять простой BAT зависеть от subtitle infrastructure. Это сохранило простой downloader стабильным и отделило сложный workflow в PowerShell.

---

# 37. Что не стоит делать

### Не запускать RU subtitle downloads параллельно

Два потока не являются лечением `429`.

```text
more concurrent requests
-> potentially stronger rate limiting
```

### Не использовать длинные retries как основной механизм

После внедрения PO Token Provider:

```text
token-aware request
>
blind repeated requests
```

### Не вызывать BAT из v7

Это создало бы:

```text
PowerShell
 -> cmd.exe
 -> yt-dlp
 -> embedded PowerShell
 -> ffmpeg
 -> back to PowerShell
```

Сложнее:

- errors;
- quoting;
- state;
- filenames;
- lifecycle.

---

# 38. Observed versions baseline

Проверенная конфигурация во время настройки:

```text
Windows       : Windows 10
yt-dlp        : 2026.08.19
Node.js       : v24.16.0
npm           : 11.17.0
Git           : 2.53.0.windows.2
bgutil server : 1.3.2 (observed via /ping)
ffmpeg        : local standalone build
```

Это не hard requirement для вечного использования.

Минимальные requirements должны сверяться с актуальной документацией.

---

# 39. Security / operational notes

> [!warning] Cookies
> Текущая проверенная конфигурация не требует постоянного использования browser cookies.
> Если в будущем понадобится `--cookies-from-browser`, относиться к cookies как к sensitive authentication material.

> [!warning] Local service
> `bgutil` слушает localhost TCP port `4416`. Не публиковать этот port наружу без отдельной необходимости.

> [!warning] Rights / terms
> Использовать downloader только для контента и сценариев, где у пользователя есть соответствующие права и где это допустимо применимыми правилами/условиями сервиса.

---

# 40. Финальный checklist

```text
BASE
[ ] D:\Trainings\yt-dlp существует
[ ] D:\TempD существует или fallback принят
[ ] yt-dlp.exe находится в working directory
[ ] ffmpeg.exe находится в working directory
[ ] yt-dlp --version работает
[ ] ffmpeg -version работает

PART I
[ ] download_yt-dlp_ru_v2_mp4.bat расположен в working directory
[ ] обычный MP4 скачивается
[ ] Original audio присутствует
[ ] Russian audio добавляется при наличии
[ ] итоговый MP4 имеет переключаемые audio tracks

PART II
[ ] Node.js >= required version
[ ] npm работает
[ ] git работает
[ ] bgutil repository находится внутри D:\Trainings\yt-dlp
[ ] npm ci выполнен
[ ] npx tsc выполнен
[ ] server\build\main.js существует
[ ] yt-dlp-plugins\bgutil-ytdlp-pot-provider.zip существует
[ ] plugin обнаруживается yt-dlp
[ ] node build\main.js стартует
[ ] /ping отвечает
[ ] download_yt-dlp_subs_v7.ps1 запускается
[ ] v7 способен сам стартовать provider
[ ] provider прогревается асинхронно
[ ] original SRT скачивается
[ ] Russian SRT скачивается через android_vr + bgutil
[ ] v7 останавливает только provider, который запустил сам
[ ] при provider failure video/original subtitle не теряются
```

---

# 41. Reference sources

Актуальное поведение рекомендуется периодически сверять с официальными источниками:

- yt-dlp repository: `https://github.com/yt-dlp/yt-dlp`
- yt-dlp PO Token Guide: `https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide`
- bgutil-ytdlp-pot-provider: `https://github.com/Brainicism/bgutil-ytdlp-pot-provider`
- FFmpeg: `https://ffmpeg.org/`
- Node.js: `https://nodejs.org/`

---

## Appendix A. Полный `download_yt-dlp_ru_v2_mp4.bat`

> [!note]
> Ниже приведен полный финальный BAT, на котором основана Part I.

```bat
@echo off
setlocal EnableExtensions DisableDelayedExpansion

:: ================================================================
:: YT-DLP Downloader - Original + Russian audio
:: Version: 2026-08-21-v2-mp4
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
echo    Version: 2026-08-21-v2-mp4
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
::    MP4 is used because the selected streams are AVC/H.264 + AAC/M4A.
:: -----------------------------------------------------------------
echo.
echo [INFO] Building MP4 with Original + Russian audio...
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
    -movflags +faststart ^
    "%OUTPUT_DIR%\%FINAL_BASE% [Original+RUS].mp4"

if errorlevel 1 (
    echo.
    echo [ERROR] FFmpeg failed to build the final MP4 file.
    echo [INFO] Temporary files were kept in: %WORK%
    pause
    goto loop
)

rmdir /s /q "%WORK%" >nul 2>&1

echo.
echo [DONE] Completed successfully.
echo [INFO] Saved file:
echo        %OUTPUT_DIR%\%FINAL_BASE% [Original+RUS].mp4
echo.
pause
goto loop

:download_error
echo.
echo [ERROR] Failed to download one of the required streams.
echo [INFO] Temporary files were kept in: %WORK%
pause
goto loop
```

---

## Appendix B. Полный `download_yt-dlp_subs_v7.ps1`

> [!note]
> Ниже приведен полный финальный PowerShell script, на котором основана Part II.
>
> В исходном коде присутствует косметический legacy-комментарий `v6 uses HTTP provider only`; фактическая версия файла — `v7`, а runtime behavior соответствует HTTP-provider architecture, описанной выше.

```powershell
param(
    [Parameter(Position = 0)]
    [string]$Url
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
#   - Russian subtitle (only when original language is not Russian):
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
# Only one controlled retry is allowed: attempt 1 -> wait 15 sec -> attempt 2.
$SubtitleInterLanguageDelaySeconds = 2
$SubtitleRequestSleepSeconds = 2
$SubtitleMaxAttempts = 2
$SubtitleRetryDelaySeconds = @(15)
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

    # Start bgutil early and let it warm up while the main media workflow runs.
    # This call is intentionally non-blocking.
    $bgutilStartRequested = Start-BgutilProviderIfNeeded
    if (-not $bgutilStartRequested) {
        Write-Host '[WARN] bgutil could not be started early. Video and original subtitles will continue.'
    }
    Write-Host ''

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
```

---

## Appendix C. Минимальные copy-ready diagnostic commands

### Versions

```powershell
Set-Location "D:\Trainings\yt-dlp"

.\yt-dlp.exe --version
.\ffmpeg.exe -version
node --version
npm --version
git --version
```

### bgutil build

```powershell
Test-Path `
  "D:\Trainings\yt-dlp\bgutil-ytdlp-pot-provider\server\build\main.js"
```

### provider manual start

```powershell
Set-Location `
  "D:\Trainings\yt-dlp\bgutil-ytdlp-pot-provider\server"

node .\build\main.js
```

### provider health

```powershell
Invoke-RestMethod `
  "http://127.0.0.1:4416/ping" |
  Format-List
```

### plugin discovery

```powershell
Set-Location "D:\Trainings\yt-dlp"

.\yt-dlp.exe `
  -v `
  --simulate `
  --js-runtimes node `
  "https://www.youtube.com/watch?v=VIDEO_ID"
```

### list formats

```powershell
.\yt-dlp.exe -F `
  "https://www.youtube.com/watch?v=VIDEO_ID"
```

### list subtitles

```powershell
.\yt-dlp.exe `
  --list-subs `
  "https://www.youtube.com/watch?v=VIDEO_ID"
```

---

## Appendix D. Mental model в одном блоке

```text
Simple path
===========

download_yt-dlp_ru_v2_mp4.bat
        |
        v
yt-dlp
  |      \
  |       \ Russian audio
  |        \
Original   |
video/audio|
    \      |
     \     |
      ffmpeg -c copy
           |
           v
      multi-audio MP4


Extended path
=============

download_yt-dlp_subs_v7.ps1
        |
        +------------------------------+
        |                              |
        v                              v
      yt-dlp                        Node.js
        |                              |
        |                       bgutil HTTP provider
        |                              |
        |                       127.0.0.1:4416
        |                              |
        +--------- PO Token plugin <---+
        |
        +--> video/audio
        |
        +--> original SRT
        |
        +--> Russian SRT via android_vr
        |
        v
      ffmpeg
        |
        v
MP4 + external SRT sidecars
```

## Appendix E. Последняя версия `ffmpeg.exe` и ссылка для скачивания

> [!important] Рекомендуемая сборка для текущей конфигурации
> Для portable-конфигурации `D:\Trainings\yt-dlp\` рекомендуется **Gyan FFmpeg Release Full — static build**, а не `full-shared`.
>
> Актуальная на **22.08.2026** версия:
>
> ```text
> FFmpeg 9.0.1 "Lei"
> Release date: 2026-08-12
> Build provider: gyan.dev
> Architecture: Windows x64
> Build type: release full / static
> License: GPLv3
> ```
>
> Последнее обновление страницы Gyan Builds на момент проверки: **20.08.2026**.

### Прямая ссылка на актуальный `release full` static build

```text
https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-full.7z
```

Страница актуальных Windows-сборок Gyan:

```text
https://www.gyan.dev/ffmpeg/builds/
```

Официальная страница FFmpeg Download:

```text
https://ffmpeg.org/download.html
```

> [!note] Почему используется ссылка без номера версии
> `ffmpeg-release-full.7z` — это постоянная rolling-ссылка Gyan на текущую release full сборку. При выходе новой release-версии содержимое архива обновляется, поэтому в runbook не требуется вручную менять URL при каждом обновлении FFmpeg.
>
> После скачивания версию всегда следует проверить локально:
>
> ```powershell
> D:\Trainings\yt-dlp\ffmpeg.exe -version
> ```

### Почему именно `release full`, а не `release full shared`

Gyan публикует оба варианта:

```text
ffmpeg-release-full.7z
ffmpeg-release-full-shared.7z
```

Для текущей portable-конфигурации нужен первый:

```text
ffmpeg-release-full.7z
```

Gyan указывает, что его обычные Windows builds являются **64-bit static builds**. Это означает, что сторонние codec/runtime libraries включены в сборку и не требуют отдельного набора DLL рядом с `ffmpeg.exe`.

`full-shared` предназначен для сценариев, где нужны shared libraries и development files, и для текущего `yt-dlp` workflow не требуется.

Практическое преимущество static build:

```text
D:\Trainings\yt-dlp\
├── ffmpeg.exe
├── ffprobe.exe
└── ...
```

вместо конфигурации вида:

```text
ffmpeg.exe
libgcc_s_seh-1.dll
libstdc++-6.dll
libwinpthread-1.dll
libbz2-1.dll
...
```

То есть portable deployment становится проще и менее зависимым от корректного набора внешних DLL.

### Что взять из архива

После распаковки архива Gyan в каталоге `bin` находятся основные executable:

```text
bin\
├── ffmpeg.exe
├── ffprobe.exe
└── ffplay.exe
```

Для текущей конфигурации рекомендуется скопировать:

```text
D:\Trainings\yt-dlp\
├── ffmpeg.exe
└── ffprobe.exe
```

`ffplay.exe` для скриптов:

```text
download_yt-dlp_ru_v2_mp4.bat
download_yt-dlp_subs_v7.ps1
```

не требуется.

### Роль `ffmpeg.exe`

В текущем workflow `ffmpeg.exe` используется для:

```text
1. merge/remux video + audio;
2. сборки MP4 с Original + Russian audio;
3. stream copy через -c copy без повторного кодирования;
4. преобразования subtitle format VTT -> SRT.
```

Критический принцип:

```text
-c copy
```

означает, что при финальной сборке совместимых H.264/AAC streams повторное кодирование не выполняется и качество исходных потоков не изменяется.

### Роль `ffprobe.exe`

`ffprobe.exe` не выполняет конвертацию. Это диагностический инструмент для чтения структуры media-файла.

Он может использоваться для проверки:

```text
container;
duration;
video codec;
audio codec;
количества audio streams;
language tags;
default dispositions;
resolution;
fps;
bitrate.
```

Пример проверки итогового multi-audio MP4:

```powershell
Set-Location "D:\Trainings\yt-dlp"

.\ffprobe.exe `
  -hide_banner `
  -show_streams `
  -show_format `
  "D:\TempD\video [Original+RUS].mp4"
```

JSON-вариант, пригодный для автоматической проверки из PowerShell/Python:

```powershell
.\ffprobe.exe `
  -v quiet `
  -print_format json `
  -show_format `
  -show_streams `
  "D:\TempD\video [Original+RUS].mp4"
```

Потенциально `ffprobe` позволяет в будущем добавить post-download validation:

```text
download
   ↓
ffmpeg mux
   ↓
ffprobe
   ↓
verify:
  video stream = present
  original audio = present
  Russian audio = present when expected
  duration > 0
   ↓
DONE
```

### Проверка после обновления

После замены файлов:

```powershell
Set-Location "D:\Trainings\yt-dlp"

.\ffmpeg.exe -version
.\ffprobe.exe -version
```

Для текущей рекомендуемой release-сборки ожидается начало вывода вида:

```text
ffmpeg version 9.0.1
```

Официальный FFmpeg указывает для 9.0.1:

```text
libavutil      61.  1.100
libavcodec     63.  1.100
libavformat    63.  1.100
libavdevice    63.  1.100
libavfilter    12.  1.100
libswscale     10.  1.100
libswresample   7.  1.100
```

> [!tip] Update policy
> Для стабильной конфигурации `yt-dlp` разумно использовать `release full` static build и обновлять его контролируемо.
>
> Gyan также рекомендует свежие `git master` builds для диагностики багов FFmpeg, однако для текущего повседневного `yt-dlp` workflow release full является более понятным baseline.

### Итоговая рекомендация

```text
Recommended:
Gyan FFmpeg 9.0.1 Release Full Static

Download:
https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-full.7z

Install:
D:\Trainings\yt-dlp\ffmpeg.exe
D:\Trainings\yt-dlp\ffprobe.exe

Do not use for this portable setup:
ffmpeg-release-full-shared.7z
```

### Источники

```text
Gyan Windows builds:
https://www.gyan.dev/ffmpeg/builds/

FFmpeg official download / releases:
https://ffmpeg.org/download.html
```

---
---