# audiobook-foundry

**document version:** 5.0
**infrastructure version:** bender 20260809
**last updated:** august 2026

Drop a PDF or EPUB into a folder. Get a chaptered M4B audiobook in the
Audiobookshelf library, narrated by a neural voice, with no attention
required and no cost.

---

## naming history

The container has been renamed twice. All three names appear in older
changelogs, so the lineage matters when reading them.

| version | name |
|---------|------|
| v108 | tts-pipeline |
| v113 | lrrr |
| 20260729 | audiobook-foundry |

The v113 rename followed the Futurama convention. Lrrr, ruler of the planet
Omicron Persei 8, was a reasonable name for a machine that turns silent text
into a booming voice.

The 20260729 rename came from publishing the code. `lrrr` says nothing to a
stranger browsing a repository, and the trailing letters read as
*arr-adjacent, which invites the wrong expectations for a format converter.
So the public project is `audiobook-foundry`, and the container was renamed
to match.

The ntfy topic is still `tts-pipeline`. That was kept deliberately, so
notification history stays continuous across both renames.

---

## the three containers

```
                    /mnt/BIG/filme/tts/input/
                    ├── ro-emil/     ro-RO-EmilNeural
                    ├── ro-alina/    ro-RO-AlinaNeural
                    ├── en-ryan/     en-GB-RyanNeural
                    └── en-sonia/    en-GB-SoniaNeural
                              │
                              │  inotify
                              ▼
                    ┌──────────────────────┐
                    │  audiobook-foundry   │  :5051 web UI
                    │  watcher + Flask     │  build context is a git checkout
                    └──────────┬───────────┘
                               │
                    ┌──────────┴───────────┐
                    │      edge-tts        │  :5050
                    │  free Edge voices    │  unofficial endpoint
                    └──────────┬───────────┘
                               │
                               ▼
              /mnt/BIG/filme/audiobookshelf/audiobooks/cărți/
                               │
                               ▼
                       audiobookshelf  :8081
                       picks it up automatically
```

`epub2tts-edge` is a third container, behind `profiles: tools`. It is the
same converter used manually, for one-off jobs. It does not run by default.

---

## how a conversion happens

1. A file lands in one of the four voice directories
2. `inotify` fires, and the voice is chosen by which directory received it
3. A PDF is converted to EPUB first, with Calibre's `ebook-convert`
4. `epub2tts-edge` splits the text and requests speech from `edge-tts`
5. The result is assembled into a chaptered M4B with embedded cover art
6. Metadata is sanitized, see below
7. The file is moved to `/audiobooks/cărți/Author/Title/`
8. ntfy reports success or failure

Filenames follow `Author - Title.ext`. That convention becomes the library
metadata, so it is not cosmetic.

The source EPUB is copied alongside the M4B. Any sentences that could not be
spoken are listed in `skipped_sentences.txt` in the same directory.

---

## two design decisions worth knowing

### the resilience patch

`patch_epub2tts.py` runs at image build time. It replaces upstream's
`run_edgespeak` function with a version that survives failure.

Upstream aborts the whole conversion when a sentence cannot be spoken, or
when the endpoint fails three times. On a forty-minute book that is
expensive. The patched version inserts a short silence placeholder and
continues, then logs what it skipped.

The patch locates the function by regex against a function boundary. So if
upstream refactors it, the build fails loudly at the patch's own assertions
rather than producing a quietly broken image. The Dockerfile clones upstream
at HEAD, so pinning a known-good commit there is a reasonable improvement.

### the metadata sanitizer

Some ebook sources produce M4B files whose `description` or `comment` tag
holds megabytes of text. Audiobookshelf ingests that faithfully. Then
ShelfDroid on Android crashes at launch with
`SQLiteBlobTooBigException`, because a single metadata row exceeds Android's
hard 2 MB CursorWindow limit.

The pipeline now caps oversized text tags at 4000 characters, using a
lossless stream-copy remux, and warns when a book exceeds 200 chapters.

This fixes the problem at the generation boundary, so every downstream client
is protected rather than each one being patched.

**It applies to new conversions only.** Library items generated before
20260729 keep their original metadata until they are regenerated or trimmed
by hand.

---

## configuration

Everything is environment-driven. Defaults come from the repository, and
bender overrides only what it must.

| variable | bender's value | note |
|----------|----------------|------|
| `AF_OUTPUT_DIR` | `/audiobooks/cărți` | required; the repository default is `/audiobooks` |
| `NTFY_URL` | `http://10.30.0.11:8888/tts-pipeline` | topic name predates both renames |
| `AF_VOICES` | repository default | four voices, as listed above |
| `AF_MAX_DESCRIPTION_CHARS` | 4000 | 0 disables the cap |
| `AF_CHAPTER_WARN` | 200 | log only |
| `AF_PORT` | 5051 | LOCKED |

Any voice from `edge-tts --list-voices` works, in any language. Adding one
means adding a `subdir:VoiceName` pair to `AF_VOICES` and creating the
directory.

---

## the build context is a git checkout

`/mnt/BIG/filme/configs/audiobook-foundry` is a clone of the public
repository, not a loose directory.

That matters. Before 20260729 the only copy of this code lived on one ZFS
dataset with no history, and the question "do we still have the source"
had to be answered by archaeology. Now `git log` answers it.

Updating is therefore:

```bash
cd /mnt/BIG/filme/configs/audiobook-foundry
git remote -v        # confirm which remote this checkout tracks
git pull
cd /mnt/BIG/filme/docker-compose
docker compose build --no-cache audiobook-foundry
docker compose up -d audiobook-foundry
```

**A recreate without a build uses the old image.** This is a build-based
service, so `docker compose up -d` alone changes nothing about the code.

`configs/tts-pipeline/` is the retired pre-rename context. Archive it once a
conversion has succeeded on the new image.

---

## the honest risk

`edge-tts` reaches Microsoft's Edge read-aloud endpoint through an unofficial
library. It is free and it is not a supported API.

So it may be rate-limited, changed, or withdrawn without notice. That is the
single largest operational risk in this subsystem, and there is no mitigation
beyond the resilience patch, which turns a hard failure into a silence
placeholder.

The published repository states this openly in its README, alongside a
Microsoft non-affiliation notice.

---

## troubleshooting

### nothing happens after dropping a file

Check the watcher is running and saw the file:

```bash
docker logs --tail 30 audiobook-foundry
curl -s http://10.30.0.12:5051/api/status
```

The status endpoint returns `idle` when nothing is queued. A healthy start
logs a four-voice banner and the metadata cap value.

### the file was renamed to FAILED_

The pipeline does that when input validation fails. The most common cause is
a `.url` file pointing at an HTML page rather than a PDF, or a PDF that is
actually an HTML error page. Check the log for the exact reason.

### the build fails at the patch

That is the assertion working. Upstream changed `run_edgespeak`, so the
regex no longer matches. Read the patch output, then either update the patch
or pin the Dockerfile to a known-good upstream commit.

### a book has hundreds of chapters or a huge description

The sanitizer warns rather than blocking. Check the conversion log for
`[sanitize]` lines. If a library item predates 20260729, its metadata was
never capped; regenerate it or trim it in the Audiobookshelf editor.

### an Android client crashes at launch

That is the CursorWindow fault described above. Clearing the app's data lets
it start, but it will crash again after syncing unless the offending library
item is fixed server-side.

---

## the source repository

The project is published as open source, MIT licensed. Two copies exist.

**forgejo, on bender.** The private mirror, and the copy that survives an
internet outage:

<http://git.home.arpa:3030/horia/audiobook-foundry>

**GitHub.** The public copy:

<https://github.com/om1d3/audiobook-foundry>

Bender's build context clones from GitHub, because it needs no credentials
for a public repository. Use the forgejo URL when GitHub is unreachable, or
when working entirely inside the LAN.

Its README carries a vibe-coded disclaimer, stated plainly: the code has no
test suite, and it was verified by running it and observing the results in
one home lab.
