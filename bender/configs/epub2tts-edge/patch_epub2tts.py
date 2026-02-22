#!/usr/bin/env python3
"""Patch epub2tts-edge: replace run_edgespeak entirely by locating it by function boundary."""
import os, site, re

# Find the installed file
target = None
for d in site.getsitepackages():
    c = os.path.join(d, "epub2tts_edge", "epub2tts_edge.py")
    if os.path.exists(c):
        target = c
        break
if not target:
    for root, dirs, files in os.walk("/usr/local/lib"):
        if "epub2tts_edge.py" in files and "epub2tts_edge" in root:
            target = os.path.join(root, "epub2tts_edge.py")
            break

assert target, "Could not find epub2tts_edge.py!"
print(f"Patching: {target}")

with open(target, "r") as f:
    content = f.read()

# Find the function boundaries using regex
# Match from "def run_edgespeak" to the next top-level "def " or "async def " or "class "
pattern = re.compile(
    r'^(def run_edgespeak\(.*?\n)'   # function definition line
    r'(.*?)'                          # function body
    r'(?=^(?:def |async def |class )|\Z)',  # until next top-level definition or EOF
    re.MULTILINE | re.DOTALL
)

match = pattern.search(content)
assert match, "Could not find run_edgespeak function!"

print(f"Found run_edgespeak at position {match.start()}-{match.end()}")
print(f"Original function length: {len(match.group())} chars")

# The replacement function
new_function = '''def run_edgespeak(sentence, speaker, filename):
    import re as _re
    # PATCH: if sentence has no alphanumeric chars, create silence and return
    if isinstance(sentence, str) and not _re.search(r"[a-zA-Z0-9]", sentence):
        print(f"  Skipping non-alphanumeric: {repr(sentence[:50])}")
        from pydub import AudioSegment as _AS
        _AS.silent(duration=100).export(filename, format="mp3")
        return
    for speakattempt in range(3):
        try:
            communicate = edge_tts.Communicate(sentence, speaker)
            run_save(communicate, filename)
            if os.path.getsize(filename) == 0:
                raise Exception("Failed to save file from edge_tts")
            break
        except Exception as e:
            print(f"Attempt {speakattempt+1}/3 failed with \\'{sentence}\\' in run_edgespeak with error: {e}")
            time.sleep(3)
    else:
        # PATCH: all retries failed — create silence instead of exit()
        print(f"  SKIPPED sentence \\'{sentence}\\' after 3 attempts. Inserting silence.")
        from pydub import AudioSegment as _AS
        _AS.silent(duration=500).export(filename, format="mp3")


'''

# Replace
patched = content[:match.start()] + new_function + content[match.end():]

with open(target, "w") as f:
    f.write(patched)

print(f"Replaced function ({len(match.group())} chars -> {len(new_function)} chars)")

# Verify by reading back and checking
with open(target, "r") as f:
    verify = f.read()

# Extract the new function to verify
new_match = pattern.search(verify)
if new_match:
    func_text = new_match.group()
    checks = {
        "Skipping non-alphanumeric": "skip check" in func_text or "non-alphanumeric" in func_text,
        "silent(duration=100)": "silent(duration=100)" in func_text,
        "silent(duration=500)": "silent(duration=500)" in func_text,
        "export(filename": "export(filename" in func_text,
        "NO exit()": "exit()" not in func_text,
        "NO return without file": func_text.count("return") <= 1,  # only the one after silence export
    }
    for desc, passed in checks.items():
        print(f"  {'✅' if passed else '❌'} {desc}")
else:
    print("❌ FATAL: Could not find patched function!")
