# TTS pipeline

## automated PDF/EPUB to audiobook conversion

**document version:** 1.0
**infrastructure version:** bender v109
**last updated:** february 2026

---

## table of contents

1. [overview](#overview)
2. [architecture](#architecture)
3. [containers](#containers)
4. [conversion pipeline](#conversion-pipeline)
5. [web interface](#web-interface)
6. [voice directories](#voice-directories)
7. [file naming convention](#file-naming-convention)
8. [the pipeline script](#the-pipeline-script)
9. [the web application](#the-web-application)
10. [the Dockerfiles](#the-dockerfiles)
11. [audiobookshelf integration](#audiobookshelf-integration)
12. [resource limits](#resource-limits)
13. [status tracking](#status-tracking)
14. [error handling](#error-handling)
15. [usage examples](#usage-examples)
16. [maintenance](#maintenance)
17. [troubleshooting](#troubleshooting)
18. [design decisions](#design-decisions)

---

## overview

the TTS pipeline converts PDF, EPUB, and TXT files into M4B audiobooks using Microsoft Edge's free cloud-based neural text-to-speech voices. it supports 4 voices across 2 languages (Romanian and English), accepts input via a web interface or filesystem drop, and outputs directly into audiobookshelf's library for automatic pickup.

the system was added in v108 (core pipeline) and v109 (multi-voice directories + web interface).

---

## architecture

```
user input
   |
   +-- web UI (Flask :5051) -- upload file or paste URL
   |       |
   |       v
   +-- filesystem drop -- place file in voice directory
           |
           v
    /input/{voice-dir}/
    (ro-emil, ro-alina, en-ryan, en-sonia)
           |
           v
    pipeline.sh (inotifywait filesystem watcher)
           |
           +-- .url file? → curl download → validate PDF
           +-- .pdf file? → ebook-convert (calibre) → EPUB
           +-- .epub file? → direct processing
           |
           v
    epub2tts-edge (chapter splitting + TTS)
           |
           v
    edge-tts API (:5050, OpenAI-compatible)
    Microsoft Edge neural voices (cloud)
           |
           v
    M4B audiobook file
           |
           v
    /audiobooks/cărți/{Author}/{Title}/
    (+ cover.png, + source EPUB, + skipped_sentences.txt)
           |
           v
    audiobookshelf auto-detection
```

### containers involved

```
tts-pipeline (:5051)
   ├── pipeline.sh (filesystem watcher, conversion orchestrator)
   └── webapp.py (Flask web interface)
           |
           v (HTTP API calls)
edge-tts (:5050)
   └── OpenAI-compatible TTS endpoint
           |
           v (serves M4B files)
audiobookshelf (:8081)
   └── /audiobooks/cărți/ (auto-scans for new books)
```

---

## containers

### edge-tts

the TTS API server. provides an OpenAI-compatible speech synthesis endpoint using Microsoft Edge's neural voices.

| setting | value |
|---------|-------|
| image | `travisvn/openai-edge-tts:latest` |
| port | 5050:5050 |
| default voice | ro-RO-AlinaNeural |
| API format | OpenAI-compatible (`/v1/audio/speech`) |
| resource limits | 512 MB memory, 0.6 CPU |

edge-tts is a stateless API — it receives text, calls Microsoft's cloud TTS service, and returns audio. it does not store any data.

### tts-pipeline

the main processing container. runs two processes simultaneously via start.sh:

| setting | value |
|---------|-------|
| build context | `/mnt/BIG/filme/configs/tts-pipeline/` |
| port | 5051:5051 |
| tsdproxy.name | `tts` (LOCKED) |
| resource limits | 4 GB memory, 0.6 CPU |
| entrypoint | `/app/start.sh` (launches pipeline.sh + webapp.py) |

key files in the build context:

| file | purpose |
|------|---------|
| Dockerfile | builds the image (python 3.11 + calibre + ffmpeg + epub2tts-edge + flask) |
| pipeline.sh | filesystem watcher and conversion orchestrator |
| webapp.py | Flask web interface for file upload and URL submission |
| start.sh | entrypoint — starts pipeline.sh in background, then webapp.py in foreground |
| preprocess.py | text preprocessor for EPUB fallback cases |
| patch_epub2tts.py | patches epub2tts-edge to skip non-alphanumeric sentences |

### epub2tts-edge (on-demand tool)

a standalone manual converter available via `docker compose run`. uses `profiles: tools` so it doesn't start with the regular stack.

| setting | value |
|---------|-------|
| build context | `/mnt/BIG/filme/configs/epub2tts-edge/` |
| resource limits | 4 GB memory, 0.6 CPU |
| profiles | tools (on-demand only) |
| entrypoint | `epub2tts-edge` |

---

## conversion pipeline

### step-by-step process

the pipeline handles 3 input types, all converging on the epub2tts-edge conversion:

### PDF processing (2 steps)

```
1. validate PDF (check %PDF- magic bytes)
   |
   v
2. ebook-convert (calibre) → EPUB
   flags: --title, --authors, --no-images
   |
   v
3. epub2tts-edge → M4B (same as EPUB processing below)
```

### EPUB processing (1 step)

```
1. copy EPUB to work directory
   |
   v
2. epub2tts-edge splits into chapters
   |
   v
3. for each chapter:
   +-- send text to edge-tts API (:5050)
   +-- receive audio (MP3)
   +-- progress logged per chapter
   |
   v
4. epub2tts-edge merges chapters into M4B
   |
   v
5. if epub2tts-edge fails and produces .txt fallback:
   +-- preprocess.py cleans the text
   +-- re-run epub2tts-edge on the .txt file
   |
   v
6. move M4B to /audiobooks/cărți/{Author}/{Title}/
   +-- copy source EPUB alongside M4B
   +-- copy cover.png if extracted
   +-- save skipped_sentences.txt if any sentences were skipped
```

### URL processing (3 steps)

```
1. read URL from .url file (first line)
   |
   v
2. curl download (600s timeout)
   |
   v
3. validate downloaded file is PDF (%PDF- magic bytes)
   |
   v
4. process as PDF (steps above)
```

### failure handling

if any step fails, the input file is renamed with a `FAILED_` prefix in its original directory (e.g., `FAILED_Author - Title.pdf`). this prevents the watcher from reprocessing it and makes failures visible in the web UI.

---

## web interface

the Flask web application runs on port 5051 and provides:

### voice selection cards

4 cards, one per voice. each card has two input methods: file upload (PDF/EPUB) and URL submission (direct PDF link + filename).

### conversion queue table

shows the currently active conversion (with live status polling via `/api/status` every 5 seconds), queued files waiting for processing, and failed files.

### completed audiobooks table

lists the 20 most recent audiobooks generated, showing author, title, file size, completion date, number of skipped sentences, and whether the source EPUB was preserved.

### status API

`GET /api/status` returns JSON with the current pipeline state:

```json
{
  "state": "converting",
  "book": "Author - Title",
  "voice": "ro-RO-AlinaNeural",
  "detail": "Chapter: Capitolul 3",
  "timestamp": "2026-02-20 14:32:15"
}
```

states: `idle`, `downloading`, `processing`, `converting`, `failed`.

### routes

| method | path | purpose |
|--------|------|---------|
| GET | `/` | main page with voice cards, queue, and completed books |
| GET | `/api/status` | JSON status endpoint for live polling |
| POST | `/upload/<voice_key>` | file upload (PDF or EPUB) |
| POST | `/url/<voice_key>` | URL submission (downloads PDF, creates .url file) |

### access

| method | URL |
|--------|-----|
| LAN | http://tts.home.arpa:5051 |
| tailscale | https://tts.bunny-enigmatic.ts.net |

---

## voice directories

each voice has a dedicated input directory. the pipeline watcher monitors all 4 directories simultaneously using `inotifywait`:

| directory | voice ID | language | gender |
|-----------|----------|----------|--------|
| `/input/ro-emil/` | ro-RO-EmilNeural | Romanian | male |
| `/input/ro-alina/` | ro-RO-AlinaNeural | Romanian | female |
| `/input/en-ryan/` | en-GB-RyanNeural | British English | male |
| `/input/en-sonia/` | en-GB-SoniaNeural | British English | female |

the voice is determined entirely by which directory the file is placed in. the pipeline reads the `VOICE_MAP` associative array to resolve directory → voice ID.

host paths (on bender):

| container path | host path |
|---------------|-----------|
| /input/ro-emil | /mnt/BIG/filme/tts/input/ro-emil |
| /input/ro-alina | /mnt/BIG/filme/tts/input/ro-alina |
| /input/en-ryan | /mnt/BIG/filme/tts/input/en-ryan |
| /input/en-sonia | /mnt/BIG/filme/tts/input/en-sonia |
| /audiobooks | /mnt/BIG/filme/audiobookshelf/audiobooks |

---

## file naming convention

input files should follow the format: `Author - Title.ext`

the dash with spaces (` - `) is the separator. the pipeline parses this to create the output directory structure:

| input filename | parsed author | parsed title |
|----------------|---------------|--------------|
| `Mihai Eminescu - Luceafărul.pdf` | Mihai Eminescu | Luceafărul |
| `George Orwell - 1984.epub` | George Orwell | 1984 |
| `MyBook.pdf` | Unknown | MyBook |

for URL submissions via the web UI, the user provides the `Author - Title` string in the filename field.

---

## the pipeline script

`pipeline.sh` is the core orchestration script. it runs in two phases:

### phase 1: process existing files

on startup, the script scans all 4 voice directories for any files that were placed while the container was stopped:

```bash
for dir in "${!VOICE_MAP[@]}"; do
    process_directory "$dir" "${VOICE_MAP[$dir]}"
done
```

### phase 2: watch for new files

after processing existing files, the script uses `inotifywait` to monitor all 4 directories for new files:

```bash
inotifywait -m -r -e close_write -e moved_to \
    /input/ro-emil /input/ro-alina /input/en-ryan /input/en-sonia \
    --format '%w %f'
```

events monitored: `close_write` (file finished writing) and `moved_to` (file moved into directory). the script waits 3 seconds after detecting a file before processing (to ensure the file is fully written).

### key functions

| function | purpose |
|----------|---------|
| `process_pdf` | validates PDF magic bytes, converts to EPUB via calibre, then calls `convert_epub_to_m4b` |
| `process_epub` | copies EPUB to work directory, calls `convert_epub_to_m4b` |
| `process_url` | reads URL from .url file, downloads via curl (600s timeout), validates as PDF, then calls `process_pdf` |
| `convert_epub_to_m4b` | core conversion — runs epub2tts-edge with the selected voice, handles .txt fallback, moves output to audiobookshelf |
| `parse_filename` | splits `Author - Title.ext` into PARSED_AUTHOR and PARSED_TITLE |
| `preprocess_text` | runs preprocess.py on text fallback files |
| `update_status` | writes JSON status to /tmp/tts-status.json (read by webapp.py) |
| `send_notification` | sends ntfy notification on success or failure (skips silently if NTFY_URL is unset) |

### epub2tts-edge integration

the pipeline calls `epub2tts-edge` as a CLI tool (installed in the Docker image via pip):

```bash
epub2tts-edge "$epub_path" --speaker "$speaker"
```

epub2tts-edge handles: chapter detection from the EPUB structure, text extraction per chapter, API calls to the edge-tts container for audio synthesis, chapter audio concatenation into a single M4B file with chapter markers.

### txt fallback path

some EPUBs have complex structures that epub2tts-edge can't parse directly. in these cases, it produces a .txt file instead of an M4B. the pipeline detects this and runs `preprocess.py` to clean the text, then re-runs epub2tts-edge on the cleaned .txt file.

---

## the web application

`webapp.py` is a Flask application that provides the browser-based interface.

### file upload flow

1. user selects a voice card and uploads a PDF or EPUB
2. Flask saves the file to the corresponding voice directory (e.g., `/input/ro-emil/`)
3. inotifywait in pipeline.sh detects the new file
4. pipeline.sh processes the file
5. web UI polls `/api/status` every 5 seconds to show progress
6. when conversion completes, the page auto-reloads to show the new book in the completed table

### URL submission flow

1. user pastes a direct PDF URL and provides an `Author - Title` filename
2. Flask creates a `.url` file in the voice directory containing the URL
3. pipeline.sh detects the .url file and downloads the PDF via curl
4. processing continues as PDF

### status polling

the web UI uses a JavaScript polling loop that calls `/api/status` every 5 seconds. the status JSON is written by pipeline.sh via the `update_status` function to `/tmp/tts-status.json`. the webapp reads this file to serve the current state.

state transitions trigger page reloads: when a conversion starts (idle → processing) or finishes (converting → idle), the page reloads to update the queue and completed tables.

### design notes

the web UI uses server-side rendered HTML (no JavaScript framework). it supports both light and dark mode via `prefers-color-scheme` media query. the favicon is an inline SVG to avoid external file dependencies.

---

## the Dockerfiles

### tts-pipeline Dockerfile

```
base:       python:3.11-slim
apt packages: espeak-ng, ffmpeg, git, calibre, inotify-tools, curl, wget
pip packages: epub2tts-edge (from git), flask
patches:    patch_epub2tts.py (skips non-alphanumeric sentences)
app files:  pipeline.sh, preprocess.py, webapp.py, start.sh
entrypoint: /app/start.sh
```

calibre provides `ebook-convert` for PDF → EPUB conversion. ffmpeg is needed by epub2tts-edge for audio processing. inotify-tools provides `inotifywait` for the filesystem watcher. espeak-ng is a dependency of epub2tts-edge.

### epub2tts-edge Dockerfile

```
base:       python:3.11-slim
apt packages: espeak-ng, ffmpeg, git
pip packages: epub2tts-edge (from git)
patches:    patch_epub2tts.py (same patch as tts-pipeline)
entrypoint: epub2tts-edge
```

this is a minimal image for on-demand manual conversions. no calibre (PDF conversion), no inotify-tools (no watcher), no Flask (no web UI).

### transmission Dockerfile

```
base:       lscr.io/linuxserver/transmission:4.0.5
added:      flood-for-transmission (latest release ZIP from GitHub)
installed to: /flood-for-transmission/
```

the Flood UI ZIP is downloaded at build time and extracted to `/flood-for-transmission/`. the `TRANSMISSION_WEB_HOME=/flood-for-transmission/` environment variable in docker-compose.yaml tells transmission to serve this UI instead of the default.

### patch_epub2tts.py

both tts-pipeline and epub2tts-edge apply the same patch to the epub2tts-edge Python package. the patch modifies the TTS processing to skip sentences that contain only non-alphanumeric characters (punctuation-only lines, decorative separators, etc.) instead of sending them to the TTS API. skipped sentences are logged and recorded in `skipped_sentences.txt` in the output directory.

---

## audiobookshelf integration

### output directory structure

the pipeline creates the following structure in audiobookshelf's library:

```
/audiobooks/cărți/
└── {Author}/
    └── {Title}/
        ├── {Title}.m4b          # the audiobook (chapters embedded)
        ├── {Title}.epub         # source EPUB (if available)
        ├── cover.png            # cover image (if extracted from EPUB)
        └── skipped_sentences.txt # log of skipped sentences (if any)
```

audiobookshelf uses the `Author/Title` directory convention for automatic library detection. the M4B format includes chapter markers, so audiobookshelf can navigate by chapter.

### automatic detection

audiobookshelf monitors its `/audiobooks` volume for new files. when the pipeline moves the M4B into the `cărți` library folder, audiobookshelf detects it within its scan interval and adds it to the library automatically. no manual library scan is required.

### EPUB companion

when processing a PDF (which is converted to EPUB as an intermediate step), the pipeline copies the generated EPUB alongside the M4B. when processing an EPUB directly, the source EPUB is copied. this allows users to read the text version alongside the audiobook.

---

## notifications

the pipeline sends ntfy notifications on conversion completion and failure. notifications go to the `tts-pipeline` topic on amy's ntfy server.

### configuration

the `NTFY_URL` environment variable is set in docker-compose.yaml:

```yaml
environment:
  - NTFY_URL=http://192.168.21.130:8888/tts-pipeline
```

if `NTFY_URL` is empty or unset, notifications are silently skipped — the pipeline still functions normally.

### notification events

| event | priority | tags | example message |
|-------|----------|------|-----------------|
| conversion complete | default | white_check_mark, book | "Author - Title (142 MB) is now in audiobookshelf" |
| no M4B produced | high | warning, book | "Author - Title (speaker): No M4B file produced" |
| invalid PDF | high | warning, book | "Author - Title: Not a valid PDF (possibly an HTML page)" |
| PDF to EPUB failed | high | warning, book | "Author - Title: PDF to EPUB conversion failed" |
| URL download failed | high | warning, book | "Author - Title: Failed to download from URL" |
| downloaded file not PDF | high | warning, book | "Author - Title: Downloaded file is not a valid PDF" |

### subscribing

subscribe to the `tts-pipeline` topic via the ntfy app or web UI at `http://ntfy.home.arpa:8888/tts-pipeline` or `https://ntfy.bunny-enigmatic.ts.net/tts-pipeline`.

---

## resource limits

| container | memory limit | CPU limit | rationale |
|-----------|-------------|-----------|-----------|
| edge-tts | 512 MB | 0.6 | lightweight API proxy — most work is done by Microsoft's cloud |
| tts-pipeline | 4 GB | 0.6 | calibre PDF conversion and epub2tts-edge audio processing can be memory-intensive |
| epub2tts-edge | 4 GB | 0.6 | same as tts-pipeline (profiles: tools, on-demand only) |

CPU is limited to 0.6 cores to prevent TTS processing from impacting other services on the HP MicroServer Gen8.

---

## status tracking

the pipeline communicates its state to the web UI via a JSON status file at `/tmp/tts-status.json`:

```json
{
  "state": "converting",
  "book": "Mihai Eminescu - Luceafărul",
  "voice": "ro-RO-EmilNeural",
  "detail": "Chapter: Capitolul 3",
  "timestamp": "2026-02-20 14:32:15"
}
```

| state | meaning |
|-------|---------|
| `idle` | no conversion in progress |
| `downloading` | downloading a file from a URL |
| `processing` | validating input, converting PDF → EPUB |
| `converting` | epub2tts-edge is generating audio (shows chapter progress) |
| `failed` | conversion failed (detail has the reason) |

the pipeline parses epub2tts-edge output in real-time to extract chapter names and percentage progress, updating the status file so the web UI can show live conversion progress.

---

## error handling

### input validation

- PDF files are validated by checking the first 5 bytes for `%PDF-` magic bytes. HTML pages disguised as PDFs (common when URLs require authentication) are rejected
- URLs are downloaded with a 600-second timeout. failed downloads are cleaned up
- unsupported file extensions are ignored with a warning

### conversion failures

- if epub2tts-edge fails to produce an M4B, the pipeline checks for a .txt fallback file (produced when EPUB parsing fails)
- the .txt fallback is preprocessed by preprocess.py and re-processed through epub2tts-edge
- if all attempts fail, the input file is renamed with `FAILED_` prefix

### failed file handling

failed files are prefixed with `FAILED_` and left in their voice directory:

```
/input/ro-emil/FAILED_Author - Title.pdf
```

the web UI shows these with a red "Failed" badge. to retry, rename the file (remove `FAILED_` prefix). to discard, delete the file.

### skipped sentences

some sentences (punctuation-only, decorative separators, non-alphanumeric content) are automatically skipped by the patched epub2tts-edge. these are logged to `skipped_sentences.txt` in the output directory. the web UI shows a warning badge with the count.

---

## usage examples

### via web UI

1. browse to `https://tts.bunny-enigmatic.ts.net` (or `http://tts.home.arpa:5051`)
2. choose a voice card (e.g., Romanian Male)
3. either upload a PDF/EPUB file, or paste a direct PDF URL with an `Author - Title` filename
4. watch the conversion progress in the queue table
5. when complete, open audiobookshelf — the book appears automatically

### via filesystem

```bash
# romanian male voice
cp "Mihai Eminescu - Luceafărul.epub" /mnt/BIG/filme/tts/input/ro-emil/

# british female voice
cp "Jane Austen - Pride and Prejudice.pdf" /mnt/BIG/filme/tts/input/en-sonia/

# URL download (creates a .url file that the pipeline processes)
echo "https://example.com/book.pdf" > "/mnt/BIG/filme/tts/input/en-ryan/Author - Title.url"
```

### via epub2tts-edge (manual, on-demand)

for one-off conversions without the pipeline:

```bash
cd /mnt/BIG/filme/docker-compose
docker compose run --rm epub2tts-edge /input/ro-emil/book.epub --speaker ro-RO-EmilNeural
```

---

## maintenance

### rebuild after changes

```bash
cd /mnt/BIG/filme/docker-compose

# rebuild tts-pipeline (after editing pipeline.sh, webapp.py, start.sh, or Dockerfile)
docker compose build --no-cache tts-pipeline
docker compose up -d tts-pipeline

# rebuild epub2tts-edge (after editing its Dockerfile)
docker compose build --no-cache epub2tts-edge
```

### check status

```bash
# verify containers
docker ps --format "{{.Names}}\t{{.Status}}" | grep -E "tts-pipeline|edge-tts"

# check pipeline logs
docker logs tts-pipeline --tail 50

# check edge-tts API
curl -s http://localhost:5050/v1/models | head -5

# check web UI
curl -s -o /dev/null -w "%{http_code}" http://localhost:5051

# check current conversion status
curl -s http://localhost:5051/api/status | python3 -m json.tool
```

### clean up work directories

the pipeline cleans up its `/tmp/tts-work/` directory after each conversion. if a crash leaves orphaned work directories:

```bash
docker exec tts-pipeline rm -rf /tmp/tts-work/job_*
```

### update epub2tts-edge

the epub2tts-edge package is installed from git during Docker build. to get the latest version:

```bash
docker compose build --no-cache tts-pipeline
docker compose build --no-cache epub2tts-edge
docker compose up -d tts-pipeline
```

---

## troubleshooting

### conversion produces no output

```bash
# check pipeline logs for errors
docker logs tts-pipeline --tail 100 | grep -i "error\|fail"

# check if edge-tts API is responding
curl -s http://localhost:5050/v1/models

# test edge-tts directly
curl -s -X POST http://localhost:5050/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input":"test","voice":"ro-RO-AlinaNeural"}' \
  -o /tmp/test.mp3 && echo "OK" || echo "FAILED"
rm -f /tmp/test.mp3
```

### "Not a valid PDF" error

the downloaded file is likely an HTML login page, not an actual PDF. verify the URL provides a direct PDF download without authentication.

### web UI not accessible

```bash
# check port 5051
curl -s -o /dev/null -w "%{http_code}" http://localhost:5051

# check webapp.py is running inside the container
docker exec tts-pipeline ps aux | grep -E "flask|webapp"

# check logs for Flask errors
docker logs tts-pipeline --tail 30 | grep -i "flask\|traceback\|error"

# if start.sh failed, rebuild
docker compose build --no-cache tts-pipeline
docker compose up -d tts-pipeline
```

### edge-tts rate limiting (429 errors)

Microsoft may rate-limit the free TTS API during heavy usage. the pipeline will fail on the affected chapter. wait a few minutes and retry by removing the `FAILED_` prefix from the input file.

### EPUB parsing produces .txt fallback

some EPUBs have non-standard structures. the pipeline automatically handles this by preprocessing the .txt and re-running conversion. if the final output is still missing, check `conversion.log` in the work directory (if it still exists) or the pipeline container logs.

### audiobookshelf doesn't show new book

```bash
# verify the M4B was written
ls -la /mnt/BIG/filme/audiobookshelf/audiobooks/cărți/

# check directory structure (must be Author/Title/file.m4b)
find /mnt/BIG/filme/audiobookshelf/audiobooks/cărți/ -name "*.m4b" -mmin -60

# force audiobookshelf library scan via the web UI
```

---

## design decisions

### why edge-tts instead of local TTS

the HP MicroServer Gen8 has no usable GPU (iGPU disabled by HP BIOS). CPU-only local TTS (Piper, Coqui) produces significantly lower quality output. Microsoft Edge's neural voices are free, require no API key, and produce near-human quality speech — making them the clear choice for a GPU-less system.

### why epub2tts-edge

epub2tts-edge handles the complex pipeline of EPUB chapter parsing → per-chapter TTS → M4B assembly with chapter markers. building this from scratch would require reimplementing EPUB parsing, audio concatenation, M4B metadata embedding, and chapter marker insertion.

### why custom Docker image (not a published image)

epub2tts-edge doesn't publish an official Docker image. the custom Dockerfile ensures the correct version is installed with all dependencies (calibre for PDF, ffmpeg for audio, inotify-tools for watching). the patch_epub2tts.py customization also requires a build step.

### why inotifywait instead of polling

inotifywait is event-driven — it reacts instantly when a file is placed in a directory, with zero CPU usage while waiting. a polling approach would need to scan 4 directories periodically and would add latency.

### why M4B format

M4B is the standard audiobook format. it supports embedded chapter markers (so listeners can navigate by chapter), is recognized by all audiobook players including audiobookshelf, and is a single file per book (simpler than a folder of MP3s).

### why the txt fallback path

some EPUBs (especially those converted from scanned PDFs or with complex formatting) can't be parsed by epub2tts-edge directly. rather than failing completely, the pipeline catches the .txt fallback, preprocesses it to clean up artifacts, and retries. this significantly improves the success rate for difficult inputs.

### why pre-baked Flood UI for transmission

the Flood UI was previously installed via linuxserver's `DOCKER_MODS` mechanism, which downloaded the UI ZIP on every container restart. this added 30–60 seconds to each restart and occasionally failed. the custom Dockerfile downloads Flood once at build time, making restarts instant and reliable.

---

*related documentation:*
- *[bender/docs/01-ARCHITECTURE.md](../bender/docs/01-ARCHITECTURE.md) — TTS architecture overview*
- *[bender/docs/02-SERVICES-CATALOG.md](../bender/docs/02-SERVICES-CATALOG.md) — edge-tts, tts-pipeline, epub2tts-edge service details*
- *[bender/docs/07-MAINTENANCE.md](../bender/docs/07-MAINTENANCE.md) — TTS maintenance procedures*
- *[bender/docs/08-TROUBLESHOOTING.md](../bender/docs/08-TROUBLESHOOTING.md) — TTS troubleshooting*
