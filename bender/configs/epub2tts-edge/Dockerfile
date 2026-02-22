FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    espeak-ng \
    ffmpeg \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/aedocw/epub2tts-edge.git /app
WORKDIR /app
RUN pip install --no-cache-dir .

# Same patch as tts-pipeline: skip non-alphanumeric sentences
COPY patch_epub2tts.py /tmp/patch_epub2tts.py
RUN python3 /tmp/patch_epub2tts.py && rm /tmp/patch_epub2tts.py

ENTRYPOINT ["epub2tts-edge"]
