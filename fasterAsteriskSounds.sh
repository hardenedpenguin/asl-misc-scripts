#!/bin/bash
# Build sped-up Asterisk prompt overrides under /usr/local/share so package
# upgrades of /usr/share/asterisk/sounds/en are never overwritten.
#
# Requires: sox, root (or write access to DEST_DIR)
# Asterisk: sounds_search_custom_dir = yes  (ASL3 default)
#   → plays DEST_DIR/<path> before sounds/en/<path>

set -euo pipefail

# Stock language tree (package-owned; read-only source)
SOURCE_DIR="${SOURCE_DIR:-/usr/share/asterisk/sounds/en}"

# Custom overrides (survives apt). On ASL3 this is what
# /usr/share/asterisk/sounds/custom points at.
DEST_DIR="${DEST_DIR:-/usr/local/share/asterisk/sounds}"

TEMPO_ADJUSTMENT="${TEMPO_ADJUSTMENT:-1.1}"

# Minimum run of quiet audio (seconds) before sox trims leading/trailing silence.
# Note: 1% / 0.2s is aggressive and can wipe some short prompts (e.g. digits/6);
# empty outputs fall back to tempo-only.
SILENCE_DURATION_SEC="${SILENCE_DURATION_SEC:-0.2}"
SILENCE_PERCENTAGE="${SILENCE_PERCENTAGE:-1%}"
REMOVE_SILENCE="${REMOVE_SILENCE:-true}"

DRY_RUN="${DRY_RUN:-false}"
OWNER="${OWNER:-asterisk:asterisk}"

usage() {
    cat <<EOF
Usage: sudo $0 [--dry-run] [--tempo N] [--no-silence]

Reads .ulaw/.gsm from SOURCE_DIR and writes processed copies into DEST_DIR,
preserving relative paths (e.g. digits/1.ulaw). Stock package files are left alone.

Environment overrides: SOURCE_DIR DEST_DIR TEMPO_ADJUSTMENT REMOVE_SILENCE
EOF
}

run_sox() {
    # run_sox <fmt> <src> <dest> [extra sox effects...]
    local fmt=$1 src=$2 out=$3
    shift 3
    sox -t "$fmt" -r 8000 -c 1 "$src" -t "$fmt" "$out" "$@" 2>"$sox_err"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --tempo) TEMPO_ADJUSTMENT="$2"; shift 2 ;;
        --no-silence) REMOVE_SILENCE=false; shift ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ "$(id -u)" -ne 0 && "$DRY_RUN" != true ]]; then
    echo "Must run as root to write to $DEST_DIR (or use --dry-run)." >&2
    exit 1
fi

if ! command -v sox >/dev/null 2>&1; then
    echo "sox is required but not installed." >&2
    exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Source directory not found: $SOURCE_DIR" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"

ok=0
fail=0
skip=0
fallback=0

sox_err=$(mktemp /tmp/faster-sounds-sox.XXXXXX)
trap 'rm -f "$sox_err" ${temp_file:-}' EXIT

echo "Source:  $SOURCE_DIR"
echo "Dest:    $DEST_DIR"
echo "Tempo:   $TEMPO_ADJUSTMENT"
echo "Silence: $REMOVE_SILENCE (duration=${SILENCE_DURATION_SEC}s, thresh=${SILENCE_PERCENTAGE})"
echo "Dry-run: $DRY_RUN"
echo

while IFS= read -r -d '' file; do
    rel="${file#"$SOURCE_DIR"/}"
    dest="$DEST_DIR/$rel"
    dest_dir=$(dirname "$dest")
    ext="${file##*.}"

    case "$ext" in
        ulaw) fmt=ul ;;
        gsm)  fmt=gsm ;;
        *) echo "Skip unsupported: $rel"; skip=$((skip + 1)); continue ;;
    esac

    echo "Processing $rel ..."

    if [[ "$DRY_RUN" == true ]]; then
        ok=$((ok + 1))
        continue
    fi

    mkdir -p "$dest_dir"
    temp_file=$(mktemp /tmp/faster-sounds-out.XXXXXX)

    # silence/* is near-zero amplitude; silence-trim always destroys it.
    # Short tones/digits can also be wiped by aggressive trim — fall back.
    use_silence=false
    if [[ "$REMOVE_SILENCE" == true && "$rel" != silence/* ]]; then
        use_silence=true
    fi

    processed=false
    if [[ "$use_silence" == true ]]; then
        if run_sox "$fmt" "$file" "$temp_file" \
            silence 1 "$SILENCE_DURATION_SEC" "$SILENCE_PERCENTAGE" reverse \
            silence 1 "$SILENCE_DURATION_SEC" "$SILENCE_PERCENTAGE" reverse \
            tempo "$TEMPO_ADJUSTMENT" \
            && [[ -s "$temp_file" ]]; then
            processed=true
        else
            echo "  silence-trim emptied/failed; retrying tempo-only"
            : >"$temp_file"
            fallback=$((fallback + 1))
        fi
    fi

    if [[ "$processed" != true ]]; then
        if run_sox "$fmt" "$file" "$temp_file" tempo "$TEMPO_ADJUSTMENT" \
            && [[ -s "$temp_file" ]]; then
            processed=true
        fi
    fi

    if [[ "$processed" == true && -s "$temp_file" ]]; then
        cp -f "$temp_file" "$dest"
        chown "$OWNER" "$dest" 2>/dev/null || true
        chmod 644 "$dest"
        ok=$((ok + 1))
    else
        echo "  FAILED: $rel ($(tr '\n' ' ' <"$sox_err"))" >&2
        # Never leave a zero-byte override that shadows stock audio
        if [[ -f "$dest" && ! -s "$dest" ]]; then
            rm -f "$dest"
            echo "  removed empty override $rel"
        fi
        fail=$((fail + 1))
    fi
    rm -f "$temp_file"
done < <(find "$SOURCE_DIR" -type f \( -name '*.ulaw' -o -name '*.gsm' \) -print0)

echo
echo "Done. ok=$ok fail=$fail skip=$skip tempo_only_fallback=$fallback"
if [[ "$DRY_RUN" != true ]]; then
    echo "Asterisk will prefer these over $SOURCE_DIR when sounds_search_custom_dir=yes."
fi

[[ "$fail" -eq 0 ]]
