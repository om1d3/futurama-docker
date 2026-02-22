#!/bin/bash
# Start both the pipeline watcher and the web interface
/app/pipeline.sh &
python3 /app/webapp.py
