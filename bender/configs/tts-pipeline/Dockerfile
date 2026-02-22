FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    espeak-ng \
    ffmpeg \
    git \
    calibre \
    inotify-tools \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/aedocw/epub2tts-edge.git /opt/epub2tts-edge \
    && cd /opt/epub2tts-edge \
    && pip install --no-cache-dir .

RUN pip install --no-cache-dir flask

COPY patch_epub2tts.py /tmp/patch_epub2tts.py
RUN python3 /tmp/patch_epub2tts.py && rm /tmp/patch_epub2tts.py

COPY pipeline.sh /app/pipeline.sh
COPY preprocess.py /app/preprocess.py
COPY webapp.py /app/webapp.py
COPY start.sh /app/start.sh
RUN chmod +x /app/pipeline.sh /app/start.sh

WORKDIR /app
ENTRYPOINT ["/app/start.sh"]
