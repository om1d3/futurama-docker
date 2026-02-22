FROM lscr.io/linuxserver/transmission:4.0.5

RUN mkdir -p /flood-for-transmission && \
    curl -fsSL -o /tmp/flood.zip https://github.com/johman10/flood-for-transmission/releases/latest/download/flood-for-transmission.zip && \
    unzip -o /tmp/flood.zip -d / && \
    rm /tmp/flood.zip
