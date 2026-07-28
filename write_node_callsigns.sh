#!/bin/bash
# write_node_callsigns.sh
#
# Original script by N5LSN
# Updated by Jory A. Pratt
#
# Make app_rpt telemetry use ASL callsigns instead of node numbers.
# Intended for use on ASL3.
#
# Updates vs original:
#   - Parallel sox jobs (GNU parallel / xargs -P) for much faster first runs
#   - Cached letter/digit audio paths (no per-character filesystem lookups)
#   - Resume-safe: skip existing .gsm unless callsign changed or -r
#   - Durable previous-db beside astdb.txt (not /tmp)
#   - Auto-locate astdb in /var/lib/asterisk or /var/log/asterisk
#   - Fixed -a / -n / -i / -v; added -j, -r, -s, -p
#   - Map punctuation (. / \ > _ ( ) ? , : & ' etc.) without breaking AUDIO_MAP_$char
#   - Skip unspeakable chars (e.g. #) instead of failing the whole node

set -euo pipefail

SRCDIR=""
DESTDIR="/usr/share/asterisk/sounds/en/rpt/nodenames"
RPTSOUNDS="/usr/share/asterisk/sounds/en/rpt"
LETTERS="/usr/share/asterisk/sounds/en/letters"
NUMBERS="/usr/share/asterisk/sounds/en/digits"
PREV_DB=""
JOBS="$(nproc 2>/dev/null || echo 4)"
MAX_PREVIEW=10

VERBOSE=0
INCNODE=0
FORCE_RUN=0
FORCE_REBUILD=0
PROCESS_ALL=0
SINGLE_NODE=""

declare -A PREV_CALLSIGNS

usage() {
    cat << EOF
Usage: write_node_callsigns.sh [options]

OPTIONS:
   -h          Show this message
   -a          Process all nodes (fill gaps; skips existing unless -r)
   -i          Append "node" + node number after the callsign
   -n NODE     Process a single node
   -d PATH     Destination directory (default: $DESTDIR)
   -j N        Parallel sox jobs (default: nproc)
   -v          Verbose output
   -f          Skip confirmation prompt
   -r          Force regenerate even when output already exists
   -s PATH     Directory containing astdb.txt
   -p PATH     Previous-db path used for change detection

Examples:
    ./write_node_callsigns.sh -a -f       # First full build, no prompt
    ./write_node_callsigns.sh -f          # Only new/changed nodes
    ./write_node_callsigns.sh -n 40000 -r # Rebuild one node
EOF
}

log()  { printf '%s\n' "$*"; }
vlog() { (( VERBOSE )) && printf '%s\n' "$*" || true; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

resolve_astdb_dir() {
    local dir candidates=()
    [[ -n "$SRCDIR" ]] && candidates+=("$SRCDIR")
    candidates+=("/var/lib/asterisk" "/var/log/asterisk")
    for dir in "${candidates[@]}"; do
        if [[ -f "$dir/astdb.txt" ]]; then
            SRCDIR="$dir"
            return 0
        fi
    done
    return 1
}

ensure_directory_exists() {
    if [[ ! -d "$1" ]]; then
        log "Creating directory: $1"
        mkdir -p "$1" || die "Failed to create directory $1"
    fi
}

resolve_audio() {
    local basepath=$1
    if [[ -f "${basepath}.gsm" ]]; then
        printf '%s\n' "${basepath}.gsm"
    elif [[ -f "${basepath}.ulaw" ]]; then
        printf '%s\n' "${basepath}.ulaw"
    else
        printf '\n'
    fi
}

# Cache letter/digit paths into exported env vars for parallel workers.
# Keys: AUDIO_MAP_0..9, AUDIO_MAP_a..z, plus named punctuation keys.
# Never use punctuation as part of an env var name (e.g. AUDIO_MAP_\ breaks bash).
cache_letter_sound() {
    local key=$1
    local basename=$2
    local required=${3:-0}
    local file
    file="$(resolve_audio "$LETTERS/$basename")"
    if [[ -z "$file" ]]; then
        (( required )) && die "Missing $basename audio under $LETTERS"
        return 1
    fi
    export "AUDIO_MAP_$key=$file"
    return 0
}

build_audio_cache() {
    local c file
    for c in {0..9}; do
        file="$(resolve_audio "$NUMBERS/$c")"
        [[ -n "$file" ]] || die "Missing digit audio for '$c' under $NUMBERS"
        export "AUDIO_MAP_$c=$file"
    done
    for c in {a..z}; do
        file="$(resolve_audio "$LETTERS/$c")"
        [[ -n "$file" ]] || die "Missing letter audio for '$c' under $LETTERS"
        export "AUDIO_MAP_$c=$file"
    done

    # Named / ascii punctuation used in astdb "callsigns"
    cache_letter_sound SLASH slash 1
    cache_letter_sound DASH dash 1
    cache_letter_sound DOT dot 1
    cache_letter_sound SPACE space 1

    cache_letter_sound BACKSLASH ascii92 || cache_letter_sound BACKSLASH slash 1
    cache_letter_sound PLUS plus || true
    cache_letter_sound ASTERISK asterisk || true
    cache_letter_sound AT at || true
    cache_letter_sound GT ascii62 || true          # >
    cache_letter_sound LT ascii60 || true          # <
    cache_letter_sound UNDERSCORE ascii95 || true  # _
    cache_letter_sound LPAREN ascii40 || true      # (
    cache_letter_sound RPAREN ascii41 || true      # )
    cache_letter_sound QUESTION ascii63 || true    # ?
    cache_letter_sound COMMA ascii44 || true       # ,
    cache_letter_sound COLON ascii58 || true       # :
    cache_letter_sound AMPERSAND ascii38 || true   # &
    cache_letter_sound QUOTE ascii39 || true       # '
    cache_letter_sound SEMICOLON ascii59 || true   # ;
    cache_letter_sound LBRACKET ascii91 || true    # [
    cache_letter_sound RBRACKET ascii93 || true    # ]
    cache_letter_sound CARET ascii94 || true       # ^
    cache_letter_sound DOLLAR dollar || cache_letter_sound DOLLAR ascii36 || true
    cache_letter_sound PERCENT ascii37 || true     # %
    cache_letter_sound DQUOTE ascii34 || true      # "
    # '#' has no stock letter sound on ASL3 — skipped at speak time

    if (( INCNODE )); then
        NODE_SOUND="$(resolve_audio "$RPTSOUNDS/node")"
        [[ -n "$NODE_SOUND" ]] || die "Missing node audio under $RPTSOUNDS"
        export NODE_SOUND
    fi
    export INCNODE DESTDIR VERBOSE
}

audio_lookup() {
    # Punctuation must be handled before AUDIO_MAP_$1 — chars like \ . break
    # indirect variable expansion ("AUDIO_MAP_" / invalid names).
    case "$1" in
        /) printf '%s' "${AUDIO_MAP_SLASH-}" ;;
        -) printf '%s' "${AUDIO_MAP_DASH-}" ;;
        .) printf '%s' "${AUDIO_MAP_DOT-}" ;;
        \\) printf '%s' "${AUDIO_MAP_BACKSLASH-}" ;;
        +) printf '%s' "${AUDIO_MAP_PLUS-}" ;;
        \*) printf '%s' "${AUDIO_MAP_ASTERISK-}" ;;
        @) printf '%s' "${AUDIO_MAP_AT-}" ;;
        ' ') printf '%s' "${AUDIO_MAP_SPACE-}" ;;
        '>') printf '%s' "${AUDIO_MAP_GT-}" ;;
        '<') printf '%s' "${AUDIO_MAP_LT-}" ;;
        _) printf '%s' "${AUDIO_MAP_UNDERSCORE-}" ;;
        '(') printf '%s' "${AUDIO_MAP_LPAREN-}" ;;
        ')') printf '%s' "${AUDIO_MAP_RPAREN-}" ;;
        '?') printf '%s' "${AUDIO_MAP_QUESTION-}" ;;
        ',') printf '%s' "${AUDIO_MAP_COMMA-}" ;;
        ':') printf '%s' "${AUDIO_MAP_COLON-}" ;;
        '&') printf '%s' "${AUDIO_MAP_AMPERSAND-}" ;;
        "'") printf '%s' "${AUDIO_MAP_QUOTE-}" ;;
        ';') printf '%s' "${AUDIO_MAP_SEMICOLON-}" ;;
        '[') printf '%s' "${AUDIO_MAP_LBRACKET-}" ;;
        ']') printf '%s' "${AUDIO_MAP_RBRACKET-}" ;;
        '^') printf '%s' "${AUDIO_MAP_CARET-}" ;;
        '$') printf '%s' "${AUDIO_MAP_DOLLAR-}" ;;
        '%') printf '%s' "${AUDIO_MAP_PERCENT-}" ;;
        '"') printf '%s' "${AUDIO_MAP_DQUOTE-}" ;;
        [0-9a-z])
            local var="AUDIO_MAP_$1"
            printf '%s' "${!var-}"
            ;;
        *)
            printf '%s' ''
            ;;
    esac
}

process_one_node() {
    local node=$1
    local callsign=${2,,}
    local out="$DESTDIR/$node.gsm"
    local -a inputs=()
    local i char file
    local skipped=0

    for (( i = 0; i < ${#callsign}; i++ )); do
        char="${callsign:i:1}"
        file="$(audio_lookup "$char")"
        if [[ -z "$file" ]]; then
            # Skip unspeakable chars (e.g. '#') rather than failing the whole node
            skipped=$((skipped + 1))
            if (( VERBOSE )); then
                printf 'Skip unmapped %q in node %s (%s)\n' "$char" "$node" "$2" >&2
            fi
            continue
        fi
        if [[ "$file" == *.ulaw ]]; then
            inputs+=(-t raw -e u-law -r 8000 -c 1 "$file")
        else
            inputs+=("$file")
        fi
    done

    if (( ${#inputs[@]} == 0 )); then
        printf 'Error: No speakable characters for node %s (%s)\n' "$node" "$2" >&2
        return 1
    fi

    if (( INCNODE )); then
        if [[ "${NODE_SOUND}" == *.ulaw ]]; then
            inputs+=(-t raw -e u-law -r 8000 -c 1 "$NODE_SOUND")
        else
            inputs+=("$NODE_SOUND")
        fi
        for (( i = 0; i < ${#node}; i++ )); do
            char="${node:i:1}"
            file="$(audio_lookup "$char")"
            if [[ -z "$file" ]]; then
                printf 'Error: No audio mapping for %q (node %s)\n' "$char" "$node" >&2
                return 1
            fi
            if [[ "$file" == *.ulaw ]]; then
                inputs+=(-t raw -e u-law -r 8000 -c 1 "$file")
            else
                inputs+=("$file")
            fi
        done
    fi

    sox "${inputs[@]}" "$out" || {
        printf 'sox failed for node %s (%s)\n' "$node" "$2" >&2
        return 1
    }
    if (( VERBOSE )); then
        printf 'OK %s %s\n' "$node" "$2"
    else
        printf '.'
    fi
}

export -f process_one_node audio_lookup

load_previous_database() {
    PREV_CALLSIGNS=()
    [[ -f "$PREV_DB" ]] || return 0
    local node callsign
    while IFS='|' read -r node callsign _; do
        [[ -n "$node" ]] || continue
        [[ "$node" == \;* ]] && continue
        PREV_CALLSIGNS["$node"]="$callsign"
    done < "$PREV_DB"
}

# Unique node|callsign lines (last occurrence wins).
latest_astdb_entries() {
    awk -F'|' '
        /^;/ || NF < 2 || $1 == "" { next }
        { node[$1] = $2 }
        END { for (n in node) print n "|" node[n] }
    ' "$SRCDIR/astdb.txt"
}

lookup_node_callsign() {
    local want=$1
    awk -F'|' -v want="$want" '
        /^;/ || NF < 2 { next }
        $1 == want { call = $2 }
        END { if (call != "") print call }
    ' "$SRCDIR/astdb.txt"
}

# Return 0 if sox should run for this node.
needs_rebuild() {
    local node=$1
    local callsign=$2
    local out="$DESTDIR/$node.gsm"
    local old="${PREV_CALLSIGNS[$node]-}"

    (( FORCE_REBUILD )) && return 0
    [[ -f "$out" ]] || return 0

    # Existing file: rebuild only when we know the callsign changed.
    if [[ -n "$old" && "$old" != "$callsign" ]]; then
        return 0
    fi
    return 1
}

queue_node() {
    local node=$1
    local callsign=$2
    local old="${PREV_CALLSIGNS[$node]-}"

    printf '%s|%s\n' "$node" "$callsign" >> "$WORK_FILE"
    if [[ -z "$old" ]]; then
        printf '%s: NEW -> %s\n' "$node" "$callsign" >> "$CHANGES_FILE"
    else
        printf '%s: %s -> %s\n' "$node" "$old" "$callsign" >> "$CHANGES_FILE"
    fi
}

confirm_processing() {
    local node_count=$1
    (( FORCE_RUN )) && return 0

    log "$node_count nodes need to be processed (jobs=$JOBS)."
    log "Preview of changes:"
    local i=0 line
    while IFS= read -r line; do
        log "  $line"
        (( ++i >= MAX_PREVIEW )) && { log "  ...and more."; break; }
    done < "$CHANGES_FILE"

    local response
    read -r -p "Continue? [y/n]: " response
    case "$response" in
        [yY]|[yY][eE][sS]) log "Starting processing..." ;;
        *) log "Aborting."; exit 0 ;;
    esac
}

run_parallel() {
    local total
    total="$(wc -l < "$WORK_FILE" | tr -d ' ')"

    if command -v parallel >/dev/null 2>&1; then
        parallel -j "$JOBS" --colsep '[|]' process_one_node {1} {2} < "$WORK_FILE"
    else
        while IFS='|' read -r node callsign; do
            printf '%s\0%s\0' "$node" "$callsign"
        done < "$WORK_FILE" \
            | xargs -0 -n 2 -P "$JOBS" bash -c 'process_one_node "$1" "$2"' _
    fi

    (( VERBOSE )) || printf '\n'
    log "Processed $total nodes."
}

update_previous_db() {
    ensure_directory_exists "$(dirname "$PREV_DB")"
    cp "$SRCDIR/astdb.txt" "$PREV_DB"
    vlog "Updated previous DB: $PREV_DB"
}

format_total_time() {
    local total_time_ms=$1
    if (( total_time_ms < 1000 )); then
        echo "${total_time_ms}ms"
    elif (( total_time_ms < 60000 )); then
        awk -v ms="$total_time_ms" 'BEGIN { printf "%.1fs\n", ms / 1000 }'
    elif (( total_time_ms < 3600000 )); then
        awk -v ms="$total_time_ms" 'BEGIN { printf "%.1fmin\n", ms / 60000 }'
    else
        awk -v ms="$total_time_ms" 'BEGIN { printf "%.1fh\n", ms / 3600000 }'
    fi
}

# --- options ---
while getopts "haij:n:d:s:p:fvr" OPTION; do
    case "$OPTION" in
        h) usage; exit 0 ;;
        a) PROCESS_ALL=1 ;;
        i) INCNODE=1 ;;
        j) JOBS="$OPTARG" ;;
        n) SINGLE_NODE="$OPTARG" ;;
        d) DESTDIR="$OPTARG" ;;
        s) SRCDIR="$OPTARG" ;;
        p) PREV_DB="$OPTARG" ;;
        f) FORCE_RUN=1 ;;
        v) VERBOSE=1 ;;
        r) FORCE_REBUILD=1 ;;
        *) usage; exit 1 ;;
    esac
done

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "-j must be a positive integer"

start_time="$(date +%s%3N)"

resolve_astdb_dir || die "astdb.txt not found (tried /var/lib/asterisk, /var/log/asterisk). Use -s PATH."
[[ -z "$PREV_DB" ]] && PREV_DB="$SRCDIR/previous_astdb.txt"

ensure_directory_exists "$DESTDIR"
command -v sox >/dev/null 2>&1 || die "sox is required but not installed"

build_audio_cache
load_previous_database

WORK_FILE="$(mktemp)"
CHANGES_FILE="$(mktemp)"
cleanup() { rm -f "$WORK_FILE" "$CHANGES_FILE"; }
trap cleanup EXIT

node_count=0

if [[ -n "$SINGLE_NODE" ]]; then
    callsign="$(lookup_node_callsign "$SINGLE_NODE")"
    [[ -n "$callsign" ]] || die "Node $SINGLE_NODE not found in $SRCDIR/astdb.txt"
    if needs_rebuild "$SINGLE_NODE" "$callsign"; then
        queue_node "$SINGLE_NODE" "$callsign"
        node_count=1
    fi
else
    while IFS='|' read -r node callsign; do
        [[ -n "$node" && -n "$callsign" ]] || continue
        old="${PREV_CALLSIGNS[$node]-}"

        if (( PROCESS_ALL )); then
            # All nodes: write missing (or changed / -r) files.
            if needs_rebuild "$node" "$callsign"; then
                queue_node "$node" "$callsign"
                (( ++node_count )) || true
            else
                vlog "Skipping $node ($callsign) — output exists"
            fi
            continue
        fi

        # Incremental: only new or changed callsigns.
        if [[ -n "$old" && "$old" == "$callsign" ]]; then
            continue
        fi
        if needs_rebuild "$node" "$callsign"; then
            queue_node "$node" "$callsign"
            (( ++node_count )) || true
        else
            vlog "Skipping $node ($callsign) — output exists (resume)"
        fi
    done < <(latest_astdb_entries)
fi

if (( node_count == 0 )); then
    log "No nodes need processing."
    if [[ ! -f "$PREV_DB" ]]; then
        update_previous_db
    fi
    end_time="$(date +%s%3N)"
    log "Total script execution time: $(format_total_time "$((end_time - start_time))")"
    exit 0
fi

confirm_processing "$node_count"
run_parallel
update_previous_db

end_time="$(date +%s%3N)"
log "Total script execution time: $(format_total_time "$((end_time - start_time))")"
