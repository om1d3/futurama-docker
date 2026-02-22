#!/bin/bash
set -uo pipefail

OUTPUT_DIR="/audiobooks/cărți"
WORK_DIR="/tmp/tts-work"
STATUS_FILE="/tmp/tts-status.json"
LOG_PREFIX="[tts-pipeline]"

declare -A VOICE_MAP
VOICE_MAP["/input/ro-emil"]="ro-RO-EmilNeural"
VOICE_MAP["/input/ro-alina"]="ro-RO-AlinaNeural"
VOICE_MAP["/input/en-ryan"]="en-GB-RyanNeural"
VOICE_MAP["/input/en-sonia"]="en-GB-SoniaNeural"

log()  { echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') INFO: $1"; }
err()  { echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') ERROR: $1" >&2; }
warn() { echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') WARN: $1"; }

update_status() {
    local state="$1"
    local book="${2:-}"
    local voice="${3:-}"
    local detail="${4:-}"
    printf '{"state":"%s","book":"%s","voice":"%s","detail":"%s","timestamp":"%s"}\n' \
        "$state" "$book" "$voice" "$detail" "$(date '+%Y-%m-%d %H:%M:%S')" > "$STATUS_FILE"
}

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
for dir in "${!VOICE_MAP[@]}"; do
    mkdir -p "$dir"
done

update_status "idle"

parse_filename() {
    local filename="$1"
    local name_no_ext="${filename%.*}"
    if [[ "$name_no_ext" == *" - "* ]]; then
        PARSED_AUTHOR="${name_no_ext%% - *}"
        PARSED_TITLE="${name_no_ext#* - }"
    else
        PARSED_AUTHOR="Unknown"
        PARSED_TITLE="$name_no_ext"
    fi
}

preprocess_text() {
    local txt_file="$1"
    python3 /app/preprocess.py "$txt_file"
}

convert_epub_to_m4b() {
    local epub_path="$1"
    local author="$2"
    local title="$3"
    local work_subdir="$4"
    local speaker="$5"
    local source_epub_for_copy="${6:-}"

    log "Converting EPUB to M4B with speaker: $speaker"
    log "This may take 10-60 minutes depending on book length..."
    update_status "converting" "$author - $title" "$speaker" "Starting TTS conversion..."

    cd "$work_subdir"

    epub2tts-edge "$epub_path" --speaker "$speaker" 2>&1 | tee "$work_subdir/conversion.log" | while IFS= read -r line; do
        echo "$line"
        if [[ "$line" == *"Chapter name:"* ]]; then
            chapter=$(echo "$line" | sed 's/.*Chapter name: "\(.*\)".*/\1/')
            update_status "converting" "$author - $title" "$speaker" "Chapter: $chapter"
        elif [[ "$line" == *"Generating audio files:"* && "$line" == *"%"* ]]; then
            pct=$(echo "$line" | grep -oP '\d+%' | tail -1)
            if [ -n "$pct" ]; then
                update_status "converting" "$author - $title" "$speaker" "Generating audio: $pct"
            fi
        fi
    done

    local m4b_file
    m4b_file=$(find "$work_subdir" -maxdepth 1 -name "*.m4b" -type f | head -1)

    if [ -z "$m4b_file" ] || [ ! -f "$m4b_file" ]; then
        local txt_file
        txt_file=$(find "$work_subdir" -maxdepth 1 -name "*.txt" -type f | head -1)

        if [ -n "$txt_file" ] && [ -f "$txt_file" ]; then
            log "EPUB parsing produced a .txt fallback. Preprocessing and re-running..."
            update_status "converting" "$author - $title" "$speaker" "Re-processing from text fallback..."
            preprocess_text "$txt_file"
            epub2tts-edge "$txt_file" --speaker "$speaker" 2>&1 | tee -a "$work_subdir/conversion.log" | while IFS= read -r line; do
                echo "$line"
                if [[ "$line" == *"Chapter name:"* ]]; then
                    chapter=$(echo "$line" | sed 's/.*Chapter name: "\(.*\)".*/\1/')
                    update_status "converting" "$author - $title" "$speaker" "Chapter: $chapter"
                elif [[ "$line" == *"Generating audio files:"* && "$line" == *"%"* ]]; then
                    pct=$(echo "$line" | grep -oP '\d+%' | tail -1)
                    if [ -n "$pct" ]; then
                        update_status "converting" "$author - $title" "$speaker" "Generating audio: $pct"
                    fi
                fi
            done
            m4b_file=$(find "$work_subdir" -maxdepth 1 -name "*.m4b" -type f | head -1)
        fi
    fi

    if [ -z "$m4b_file" ] || [ ! -f "$m4b_file" ]; then
        err "No .m4b file found after conversion"
        update_status "failed" "$author - $title" "$speaker" "No M4B file produced"
        return 1
    fi

    update_status "converting" "$author - $title" "$speaker" "Finalizing..."

    local book_dir="$OUTPUT_DIR/$author/$title"
    mkdir -p "$book_dir"
    mv "$m4b_file" "$book_dir/"

    if [ -n "$source_epub_for_copy" ] && [ -f "$source_epub_for_copy" ]; then
        cp "$source_epub_for_copy" "$book_dir/"
        log "Copied EPUB to: $book_dir/$(basename "$source_epub_for_copy")"
    fi

    local cover_file
    cover_file=$(find "$work_subdir" -maxdepth 1 -name "*.png" -type f | head -1)
    if [ -n "$cover_file" ] && [ -f "$cover_file" ]; then
        cp "$cover_file" "$book_dir/cover.png"
    fi

    if grep -q "SKIPPED\|Skipping non-alphanumeric" "$work_subdir/conversion.log" 2>/dev/null; then
        grep "SKIPPED\|Skipping non-alphanumeric\|silence placeholder" "$work_subdir/conversion.log" > "$book_dir/skipped_sentences.txt"
        local skipped_count
        skipped_count=$(wc -l < "$book_dir/skipped_sentences.txt")
        warn "$skipped_count sentences were skipped. See: $book_dir/skipped_sentences.txt"
    fi

    local final_path="$book_dir/$(basename "$m4b_file")"
    local size
    size=$(du -h "$final_path" | cut -f1)
    log "Audiobook ready: $final_path ($size)"
    log "   Audiobookshelf will auto-detect the new book."
    update_status "idle"
    return 0
}

process_pdf() {
    local pdf_path="$1"
    local speaker="$2"
    local input_dir="$3"
    local filename
    filename=$(basename "$pdf_path")
    parse_filename "$filename"

    log "========================================="
    log "Processing PDF: $filename"
    log "  Author: $PARSED_AUTHOR"
    log "  Title:  $PARSED_TITLE"
    log "  Voice:  $speaker"
    log "========================================="
    update_status "processing" "$PARSED_AUTHOR - $PARSED_TITLE" "$speaker" "Validating PDF..."

    local file_type
    file_type=$(head -c 5 "$pdf_path" 2>/dev/null)
    if [[ "$file_type" != "%PDF-" ]]; then
        err "File is not a valid PDF (got: $file_type). Possibly an HTML page."
        update_status "failed" "$PARSED_AUTHOR - $PARSED_TITLE" "$speaker" "Not a valid PDF"
        mv "$pdf_path" "$input_dir/FAILED_${filename}" 2>/dev/null
        return 1
    fi

    local work_subdir="$WORK_DIR/job_$(date +%s)_$$"
    mkdir -p "$work_subdir"

    local name_no_ext="${filename%.*}"
    local epub_path="$work_subdir/$name_no_ext.epub"

    log "Step 1/2: Converting PDF to EPUB..."
    update_status "processing" "$PARSED_AUTHOR - $PARSED_TITLE" "$speaker" "Converting PDF to EPUB..."
    if ! ebook-convert "$pdf_path" "$epub_path" \
        --title "$PARSED_TITLE" \
        --authors "$PARSED_AUTHOR" \
        --no-images 2>&1; then
        err "PDF to EPUB conversion failed for: $filename"
        update_status "failed" "$PARSED_AUTHOR - $PARSED_TITLE" "$speaker" "PDF to EPUB failed"
        rm -rf "$work_subdir"
        mv "$pdf_path" "$input_dir/FAILED_${filename}" 2>/dev/null
        return 1
    fi
    log "Step 1/2: EPUB created successfully"

    log "Step 2/2: Converting EPUB to M4B..."
    if ! convert_epub_to_m4b "$epub_path" "$PARSED_AUTHOR" "$PARSED_TITLE" "$work_subdir" "$speaker" "$epub_path"; then
        rm -rf "$work_subdir"
        mv "$pdf_path" "$input_dir/FAILED_${filename}" 2>/dev/null
        return 1
    fi

    rm -f "$pdf_path"
    rm -rf "$work_subdir"
    log "Processing complete for: $filename"
}

process_epub() {
    local epub_path="$1"
    local speaker="$2"
    local input_dir="$3"
    local filename
    filename=$(basename "$epub_path")
    parse_filename "$filename"

    log "========================================="
    log "Processing EPUB: $filename"
    log "  Author: $PARSED_AUTHOR"
    log "  Title:  $PARSED_TITLE"
    log "  Voice:  $speaker"
    log "========================================="
    update_status "processing" "$PARSED_AUTHOR - $PARSED_TITLE" "$speaker" "Preparing EPUB..."

    local work_subdir="$WORK_DIR/job_$(date +%s)_$$"
    mkdir -p "$work_subdir"

    cp "$epub_path" "$work_subdir/"
    local work_epub="$work_subdir/$filename"

    log "Step 1/1: Converting EPUB to M4B..."
    if ! convert_epub_to_m4b "$work_epub" "$PARSED_AUTHOR" "$PARSED_TITLE" "$work_subdir" "$speaker" "$epub_path"; then
        rm -rf "$work_subdir"
        mv "$epub_path" "$input_dir/FAILED_${filename}" 2>/dev/null
        return 1
    fi

    rm -f "$epub_path"
    rm -rf "$work_subdir"
    log "Processing complete for: $filename"
}

process_url() {
    local url_file="$1"
    local speaker="$2"
    local input_dir="$3"
    local filename
    filename=$(basename "$url_file")
    local name_no_ext="${filename%.*}"
    local url
    url=$(head -1 "$url_file" | tr -d '[:space:]')

    if [ -z "$url" ]; then
        err "Empty URL file: $filename"
        rm -f "$url_file"
        return 1
    fi

    log "========================================="
    log "Processing URL: $filename"
    log "  URL: $url"
    log "  Voice: $speaker"
    log "========================================="
    update_status "downloading" "$name_no_ext" "$speaker" "Downloading from URL..."

    log "Downloading from URL..."
    local pdf_path="$input_dir/$name_no_ext.pdf"

    if ! curl -fsSL --max-time 600 -o "$pdf_path" "$url" 2>&1; then
        err "Failed to download from: $url"
        update_status "failed" "$name_no_ext" "$speaker" "Download failed"
        rm -f "$url_file" "$pdf_path"
        return 1
    fi

    local size
    size=$(du -h "$pdf_path" | cut -f1)
    log "Downloaded: $size"

    local file_type
    file_type=$(head -c 5 "$pdf_path" 2>/dev/null)
    if [[ "$file_type" != "%PDF-" ]]; then
        err "Downloaded file is not a valid PDF (got: $file_type). URL may point to an HTML page."
        update_status "failed" "$name_no_ext" "$speaker" "Downloaded file is not a PDF"
        rm -f "$url_file" "$pdf_path"
        return 1
    fi

    rm -f "$url_file"
    process_pdf "$pdf_path" "$speaker" "$input_dir"
}

process_directory() {
    local input_dir="$1"
    local speaker="$2"

    for f in "$input_dir"/*.pdf "$input_dir"/*.PDF; do
        [ -f "$f" ] || continue
        [[ "$(basename "$f")" == FAILED_* ]] && continue
        process_pdf "$f" "$speaker" "$input_dir"
    done
    for f in "$input_dir"/*.epub "$input_dir"/*.EPUB; do
        [ -f "$f" ] || continue
        [[ "$(basename "$f")" == FAILED_* ]] && continue
        process_epub "$f" "$speaker" "$input_dir"
    done
    for f in "$input_dir"/*.url "$input_dir"/*.URL; do
        [ -f "$f" ] || continue
        process_url "$f" "$speaker" "$input_dir"
    done
}

process_file_in_dir() {
    local filepath="$1"
    local input_dir="$2"
    local speaker="$3"
    local filename
    filename=$(basename "$filepath")

    [ -f "$filepath" ] || return
    [[ "$filename" == FAILED_* ]] && return

    sleep 3

    case "${filename,,}" in
        *.pdf)  process_pdf "$filepath" "$speaker" "$input_dir" ;;
        *.epub) process_epub "$filepath" "$speaker" "$input_dir" ;;
        *.url)  process_url "$filepath" "$speaker" "$input_dir" ;;
        *)      warn "Ignoring unsupported file: $filename" ;;
    esac
}

# ============================================================
# Main
# ============================================================

log "TTS Pipeline starting..."
log "  Output directory: $OUTPUT_DIR"
log "  Voice directories:"
for dir in "${!VOICE_MAP[@]}"; do
    log "    $dir -> ${VOICE_MAP[$dir]}"
done

log "Checking for existing files..."
for dir in "${!VOICE_MAP[@]}"; do
    process_directory "$dir" "${VOICE_MAP[$dir]}"
done

log "Watching all input directories for new files..."
inotifywait -m -r -e close_write -e moved_to \
    /input/ro-emil /input/ro-alina /input/en-ryan /input/en-sonia \
    --format '%w %f' | while read -r dir filename; do
    filepath="${dir}${filename}"
    dir="${dir%/}"

    speaker=""
    for vdir in "${!VOICE_MAP[@]}"; do
        if [ "$dir" = "$vdir" ]; then
            speaker="${VOICE_MAP[$vdir]}"
            break
        fi
    done

    if [ -z "$speaker" ]; then
        warn "File in unknown directory: $dir/$filename"
        continue
    fi

    process_file_in_dir "$filepath" "$dir" "$speaker"
done
