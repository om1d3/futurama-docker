#!/usr/bin/env python3
"""Preprocess text files for Edge TTS compatibility."""
import sys, re

filepath = sys.argv[1]

with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

original_len = len(content)
content = re.sub(r'(?<=\s)[?!.;:]+(?=\s)', ' ', content)
content = re.sub(r'^\s*[?!.;:]+\s*$', '', content, flags=re.MULTILINE)
content = re.sub(r'  +', ' ', content)
content = re.sub(r'\n{3,}', '\n\n', content)

with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)

removed = original_len - len(content)
if removed > 0:
    print(f"[tts-pipeline] Text preprocessing: cleaned {removed} characters")
else:
    print(f"[tts-pipeline] Text preprocessing: no standalone punctuation found")
