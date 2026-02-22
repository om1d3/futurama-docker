#!/usr/bin/env python3
"""TTS Pipeline Web Interface - Upload files or paste URLs for audiobook conversion."""

import os
import json
import time
from pathlib import Path
from flask import Flask, request, redirect, url_for, jsonify

app = Flask(__name__)

VOICES = {
    "ro-emil": {"name": "Romanian Male", "speaker": "ro-RO-EmilNeural", "path": "/input/ro-emil", "icon": "🇷🇴", "accent": "#3b82f6"},
    "ro-alina": {"name": "Romanian Female", "speaker": "ro-RO-AlinaNeural", "path": "/input/ro-alina", "icon": "🇷🇴", "accent": "#ec4899"},
    "en-ryan": {"name": "British Male", "speaker": "en-GB-RyanNeural", "path": "/input/en-ryan", "icon": "🇬🇧", "accent": "#10b981"},
    "en-sonia": {"name": "British Female", "speaker": "en-GB-SoniaNeural", "path": "/input/en-sonia", "icon": "🇬🇧", "accent": "#f59e0b"},
}

STATUS_FILE = "/tmp/tts-status.json"

for v in VOICES.values():
    os.makedirs(v["path"], exist_ok=True)


def get_status():
    try:
        with open(STATUS_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {"state": "idle", "book": "", "voice": "", "detail": "", "timestamp": ""}


def get_queue():
    items = []
    for key, v in VOICES.items():
        p = Path(v["path"])
        for f in sorted(p.iterdir()):
            if f.is_file() and not f.name.startswith("."):
                items.append({"file": f.name, "voice": v["name"], "icon": v["icon"], "failed": f.name.startswith("FAILED_")})
    return items


def get_completed():
    books = []
    carti = Path("/audiobooks/cărți")
    if carti.exists():
        for author_dir in sorted(carti.iterdir()):
            if author_dir.is_dir():
                for book_dir in sorted(author_dir.iterdir()):
                    if book_dir.is_dir():
                        m4bs = list(book_dir.glob("*.m4b"))
                        if m4bs:
                            stat = m4bs[0].stat()
                            size_mb = stat.st_size / (1024 * 1024)
                            skipped = book_dir / "skipped_sentences.txt"
                            skip_count = sum(1 for _ in open(skipped)) if skipped.exists() else 0
                            has_epub = bool(list(book_dir.glob("*.epub")))
                            books.append({
                                "author": author_dir.name,
                                "title": book_dir.name,
                                "size": f"{size_mb:.0f} MB",
                                "date": time.strftime("%Y-%m-%d %H:%M", time.localtime(stat.st_mtime)),
                                "skipped": skip_count,
                                "has_epub": has_epub,
                            })
    books.sort(key=lambda x: x["date"], reverse=True)
    return books[:20]


FAVICON = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
<circle cx="32" cy="32" r="30" fill="#3b82f6"/>
<path d="M20 28c0-6.6 5.4-12 12-12s12 5.4 12 12" stroke="#fff" stroke-width="4" fill="none" stroke-linecap="round"/>
<rect x="16" y="28" width="8" height="14" rx="4" fill="#fff"/>
<rect x="40" y="28" width="8" height="14" rx="4" fill="#fff"/>
<rect x="28" y="44" width="8" height="4" rx="2" fill="#fff"/>
</svg>'''


@app.route("/api/status")
def api_status():
    return jsonify(get_status())


@app.route("/")
def index():
    queue = get_queue()
    completed = get_completed()
    status = get_status()
    msg = request.args.get("msg", "")
    err = request.args.get("err", "")

    queue_rows = ""
    if status["state"] not in ("idle", ""):
        state_label = status["state"].capitalize()
        detail = status["detail"] or ""
        queue_rows += f'''<tr id="active-job">
            <td>🔊 {status["voice"]}</td>
            <td class="mono">{status["book"]}</td>
            <td><span class="badge badge-active">{state_label}</span> <span class="detail" id="job-detail">{detail}</span></td>
        </tr>\n'''

    if queue:
        for item in queue:
            if item["failed"]:
                st = '<span class="badge badge-err">Failed</span>'
            else:
                st = '<span class="badge badge-queue">Queued</span>'
            queue_rows += f'<tr><td>{item["icon"]} {item["voice"]}</td><td class="mono">{item["file"]}</td><td>{st}</td></tr>\n'

    if not queue_rows:
        queue_rows = '<tr><td colspan="3" class="empty">No files in queue — upload something above</td></tr>'

    completed_rows = ""
    if completed:
        for b in completed:
            badges = ""
            if b["skipped"]:
                badges += f' <span class="badge badge-warn">{b["skipped"]} skipped</span>'
            if b["has_epub"]:
                badges += ' <span class="badge badge-epub">EPUB</span>'
            completed_rows += f'<tr><td>{b["author"]}</td><td>{b["title"]}{badges}</td><td>{b["size"]}</td><td>{b["date"]}</td></tr>\n'
    else:
        completed_rows = '<tr><td colspan="4" class="empty">No audiobooks generated yet</td></tr>'

    voice_cards = ""
    for key, v in VOICES.items():
        voice_cards += f'''
        <div class="card" style="--accent: {v["accent"]}">
            <div class="card-header">
                <span class="card-icon">{v["icon"]}</span>
                <div>
                    <div class="card-title">{v["name"]}</div>
                    <div class="card-subtitle">{v["speaker"]}</div>
                </div>
            </div>
            <div class="card-body">
                <form action="/upload/{key}" method="post" enctype="multipart/form-data" class="form-group">
                    <label>Upload PDF or EPUB</label>
                    <div class="file-input-wrap">
                        <input type="file" name="file" accept=".pdf,.epub,.PDF,.EPUB" required>
                    </div>
                    <button type="submit" style="background: {v["accent"]}">Upload</button>
                </form>
                <div class="divider">or</div>
                <form action="/url/{key}" method="post" class="form-group">
                    <label>Paste a direct PDF URL</label>
                    <input type="text" name="url" placeholder="https://example.com/book.pdf" required>
                    <input type="text" name="filename" placeholder="Author - Title" required>
                    <button type="submit" style="background: {v["accent"]}">Fetch &amp; Convert</button>
                </form>
            </div>
        </div>'''

    toast = ""
    if msg:
        toast = f'<div class="toast toast-ok">{msg}</div>'
    elif err:
        toast = f'<div class="toast toast-err">{err}</div>'

    return f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TTS Pipeline</title>
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,{FAVICON.replace('"', '%22').replace('#', '%23').replace('<', '%3C').replace('>', '%3E').replace(' ', '%20')}">
<style>
:root {{ --bg: #f8fafc; --surface: #ffffff; --border: #e2e8f0; --text: #1e293b;
         --muted: #64748b; --radius: 12px; }}
@media (prefers-color-scheme: dark) {{
  :root {{ --bg: #0f172a; --surface: #1e293b; --border: #334155; --text: #f1f5f9;
           --muted: #94a3b8; }}
}}
* {{ margin: 0; padding: 0; box-sizing: border-box; }}
body {{ font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        background: var(--bg); color: var(--text); line-height: 1.6; }}
.container {{ max-width: 1200px; margin: 0 auto; padding: 24px; }}
header {{ margin-bottom: 32px; }}
header h1 {{ font-size: 1.75rem; font-weight: 700; display: flex; align-items: center; gap: 10px; }}
header h1 span {{ background: linear-gradient(135deg, #3b82f6, #ec4899); -webkit-background-clip: text;
                  -webkit-text-fill-color: transparent; }}
header h1 .logo {{ width: 32px; height: 32px; }}
header p {{ color: var(--muted); font-size: 0.95rem; margin-top: 4px; }}
header .hint {{ font-size: 0.8rem; color: var(--muted); margin-top: 2px;
                font-family: 'SF Mono', Monaco, monospace; opacity: 0.7; }}
.section-title {{ font-size: 1.1rem; font-weight: 600; margin: 32px 0 16px 0;
                   display: flex; align-items: center; gap: 8px; }}
.section-title::before {{ content: ''; display: block; width: 4px; height: 20px;
                          border-radius: 2px; background: linear-gradient(135deg, #3b82f6, #ec4899); }}
.cards {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 16px; }}
.card {{ background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
         overflow: hidden; transition: box-shadow .2s, border-color .2s; }}
.card:hover {{ box-shadow: 0 4px 24px rgba(0,0,0,.08); border-color: var(--accent); }}
.card-header {{ display: flex; align-items: center; gap: 12px; padding: 16px 16px 0; }}
.card-icon {{ font-size: 1.8rem; }}
.card-title {{ font-weight: 600; font-size: 1rem; }}
.card-subtitle {{ font-family: 'SF Mono', Monaco, monospace; font-size: 0.75rem; color: var(--muted); }}
.card-body {{ padding: 12px 16px 16px; }}
.form-group {{ display: flex; flex-direction: column; gap: 6px; }}
label {{ font-size: 0.8rem; font-weight: 500; color: var(--muted); text-transform: uppercase;
         letter-spacing: .04em; }}
input[type="text"], input[type="file"] {{
    width: 100%; padding: 8px 12px; border-radius: 8px; border: 1px solid var(--border);
    background: var(--bg); color: var(--text); font-size: 0.9rem; transition: border-color .2s; }}
input[type="text"]:focus {{ outline: none; border-color: var(--accent, #3b82f6); }}
input[type="file"] {{ padding: 6px; font-size: 0.85rem; }}
button {{ padding: 8px 16px; border: none; border-radius: 8px; color: #fff; font-weight: 600;
          font-size: 0.9rem; cursor: pointer; transition: opacity .2s; width: 100%; }}
button:hover {{ opacity: .85; }}
.divider {{ text-align: center; color: var(--muted); font-size: 0.8rem; margin: 10px 0;
            position: relative; }}
.divider::before, .divider::after {{ content: ''; position: absolute; top: 50%; width: 40%;
    height: 1px; background: var(--border); }}
.divider::before {{ left: 0; }}
.divider::after {{ right: 0; }}
table {{ width: 100%; border-collapse: collapse; background: var(--surface);
         border-radius: var(--radius); overflow: hidden; border: 1px solid var(--border); }}
th {{ background: var(--bg); font-size: 0.8rem; text-transform: uppercase; letter-spacing: .04em;
      color: var(--muted); font-weight: 600; text-align: left; padding: 10px 16px; }}
td {{ padding: 10px 16px; border-top: 1px solid var(--border); font-size: 0.9rem; }}
.mono {{ font-family: 'SF Mono', Monaco, monospace; font-size: 0.82rem; }}
.empty {{ text-align: center; color: var(--muted); padding: 24px 16px; font-style: italic; }}
.badge {{ display: inline-block; padding: 2px 8px; border-radius: 99px; font-size: 0.75rem;
          font-weight: 600; }}
.badge-queue {{ background: #dbeafe; color: #1d4ed8; }}
.badge-err {{ background: #fee2e2; color: #dc2626; }}
.badge-warn {{ background: #fef3c7; color: #b45309; }}
.badge-active {{ background: #d1fae5; color: #059669; animation: pulse 2s infinite; }}
.badge-epub {{ background: #ede9fe; color: #7c3aed; }}
.detail {{ font-size: 0.82rem; color: var(--muted); }}
@media (prefers-color-scheme: dark) {{
  .badge-queue {{ background: #1e3a5f; color: #93c5fd; }}
  .badge-err {{ background: #450a0a; color: #fca5a5; }}
  .badge-warn {{ background: #451a03; color: #fcd34d; }}
  .badge-active {{ background: #052e16; color: #6ee7b7; }}
  .badge-epub {{ background: #2e1065; color: #c4b5fd; }}
}}
@keyframes pulse {{ 0%, 100% {{ opacity: 1; }} 50% {{ opacity: .6; }} }}
.toast {{ padding: 12px 20px; border-radius: var(--radius); margin-bottom: 20px; font-size: 0.9rem; }}
.toast-ok {{ background: #dcfce7; color: #166534; border: 1px solid #86efac; }}
.toast-err {{ background: #fee2e2; color: #991b1b; border: 1px solid #fca5a5; }}
@media (prefers-color-scheme: dark) {{
  .toast-ok {{ background: #052e16; color: #86efac; border-color: #166534; }}
  .toast-err {{ background: #450a0a; color: #fca5a5; border-color: #991b1b; }}
}}
footer {{ margin-top: 48px; text-align: center; color: var(--muted); font-size: 0.8rem; padding: 16px; }}
</style>
</head>
<body>
<div class="container">
    <header>
        <h1>
            <svg class="logo" viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg">
                <circle cx="32" cy="32" r="30" fill="#3b82f6"/>
                <path d="M20 28c0-6.6 5.4-12 12-12s12 5.4 12 12" stroke="#fff" stroke-width="4" fill="none" stroke-linecap="round"/>
                <rect x="16" y="28" width="8" height="14" rx="4" fill="#fff"/>
                <rect x="40" y="28" width="8" height="14" rx="4" fill="#fff"/>
                <rect x="28" y="44" width="8" height="4" rx="2" fill="#fff"/>
            </svg>
            <span>TTS Pipeline</span>
        </h1>
        <p>Drop a PDF, EPUB, or URL — get an audiobook in Audiobookshelf</p>
        <p class="hint">Filename format: Author - Title.pdf</p>
    </header>

    {toast}

    <div class="section-title">Choose a Voice</div>
    <div class="cards">{voice_cards}</div>

    <div class="section-title">Conversion Queue</div>
    <table id="queue-table">
        <tr><th>Voice</th><th>File</th><th>Status</th></tr>
        {queue_rows}
    </table>

    <div class="section-title">Completed Audiobooks</div>
    <table>
        <tr><th>Author</th><th>Title</th><th>Size</th><th>Completed</th></tr>
        {completed_rows}
    </table>

    <footer>TTS Pipeline v109 &middot; Edge TTS &middot; epub2tts-edge &middot; Audiobookshelf</footer>
</div>

<script>
(function() {{
    let lastState = "";
    function poll() {{
        fetch("/api/status")
            .then(r => r.json())
            .then(data => {{
                const row = document.getElementById("active-job");
                const detail = document.getElementById("job-detail");
                if (data.state === "idle" || data.state === "") {{
                    if (row) row.style.display = "none";
                    if (lastState !== "" && lastState !== "idle") {{
                        // Conversion just finished — reload to update completed table
                        window.location.reload();
                    }}
                }} else {{
                    if (row) {{
                        row.style.display = "";
                    }} else {{
                        // No active row in DOM — reload to show it
                        if (lastState === "idle" || lastState === "") {{
                            window.location.reload();
                        }}
                    }}
                    if (detail) {{
                        detail.textContent = data.detail || "";
                    }}
                }}
                lastState = data.state;
            }})
            .catch(() => {{}});
    }}
    setInterval(poll, 5000);
    poll();
}})();
</script>
</body>
</html>'''


@app.route("/upload/<voice_key>", methods=["POST"])
def upload(voice_key):
    if voice_key not in VOICES:
        return redirect(url_for("index", err="Invalid voice selection"))
    f = request.files.get("file")
    if not f or f.filename == "":
        return redirect(url_for("index", err="No file selected"))
    ext = f.filename.rsplit(".", 1)[-1].lower() if "." in f.filename else ""
    if ext not in ("pdf", "epub"):
        return redirect(url_for("index", err="Only PDF and EPUB files are supported"))
    dest = os.path.join(VOICES[voice_key]["path"], f.filename)
    f.save(dest)
    return redirect(url_for("index", msg=f"Uploaded '{f.filename}' for {VOICES[voice_key]['name']}. Conversion will start shortly."))


@app.route("/url/<voice_key>", methods=["POST"])
def fetch_url(voice_key):
    if voice_key not in VOICES:
        return redirect(url_for("index", err="Invalid voice selection"))
    url = request.form.get("url", "").strip()
    filename = request.form.get("filename", "").strip()
    if not url:
        return redirect(url_for("index", err="URL is required"))
    if not filename:
        return redirect(url_for("index", err="Filename (Author - Title) is required"))
    dest = os.path.join(VOICES[voice_key]["path"], f"{filename}.url")
    with open(dest, "w") as fh:
        fh.write(url + "\n")
    return redirect(url_for("index", msg=f"Queued URL for '{filename}' with {VOICES[voice_key]['name']}."))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5051, debug=False)
