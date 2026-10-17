#!/usr/bin/env bash
# list-tracks.sh - print audio and subtitle tracks of an MKV as a markdown table.
# The agent shows this table to the user and asks which track ids to keep.
#
# Two traps this script exists to avoid, both hit during development:
#   1. "-show_entries" together with "-show_streams" makes this ffprobe build
#      (4.4) silently drop tags such as language, so plain -show_streams is used.
#   2. jq on Windows is a native binary and emits CRLF. Every value read from it
#      is stripped of "\r" by jqf(), otherwise "rus\r" fails every regex and the
#      language silently degrades to "und".
#
# Track ids printed here are ABSOLUTE stream indexes, the ones that
# "ffmpeg -map 0:ID" expects. Never feed them to "ffprobe -select_streams a:ID",
# that selector is relative to the stream type and returns the wrong track.
set -uo pipefail

SRC="${1:-}"
[[ -n "$SRC" ]] || { printf 'usage: list-tracks.sh FILE.mkv\n' >&2; exit 2; }
[[ -f "$SRC" ]] || { printf 'not found: %s\n' "$SRC" >&2; exit 2; }

winpath() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
SRC_WIN="$(winpath "$SRC")"

command -v jq >/dev/null 2>&1 || { printf 'ERROR: jq is required\n' >&2; exit 1; }

# jqf <json> <filter> - run jq and normalise the CRLF that Windows jq emits.
jqf() { printf '%s' "$1" | jq -r "$2" 2>/dev/null | tr -d '\r'; }

JSON="$(ffprobe -v error -show_streams -of json "$SRC_WIN" 2>/dev/null)"
[[ -n "$JSON" ]] || { printf 'ERROR: ffprobe returned nothing for %s\n' "$SRC" >&2; exit 1; }

escape() { printf '%s' "${1-}" | sed 's/|/\\|/g'; }

clean_title() {
  printf '%s' "${1-}" | tr -d '\000-\037' \
    | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//'
}

valid_lang() {
  local l="${1-}"
  l="$(printf '%s' "$l" | tr -d '\r[:space:]')"
  [[ "$l" =~ ^[a-z]{2,3}$ ]] && printf '%s' "$l" || printf 'und'
}

valid_int() {
  local n="${1-}"
  n="$(printf '%s' "$n" | tr -d '\r[:space:]')"
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf ''
}

bitrate_of() {
  local b
  b="$(valid_int "${1-}")"
  if [[ -n "$b" ]]; then printf '%d kbit/s' $((b / 1000)); else printf 'unknown'; fi
}

exported_as() {
  case "$(printf '%s' "${1-}" | tr -d '\r')" in
    subrip|srt)        printf '.srt' ;;
    ass|ssa)           printf '.ass + .srt' ;;
    hdmv_pgs_subtitle) printf '.sup (PGS, no OCR)' ;;
    *)                 printf 'unsupported' ;;
  esac
}

printf 'Source: `%s`\n\n' "$SRC"

# ------------------------------------------------------------- video line ----

VID_LINE="$(jqf "$JSON" '[ .streams[] | select(.codec_type=="video" and .codec_name=="hevc") ][0]
  | if . == null then empty else "\(.width // "?")x\(.height // "?")" end')"
[[ -n "$VID_LINE" ]] && printf 'Video: HEVC %s\n\n' "$VID_LINE"

# ----------------------------------------------------------------- audio -----

printf '### Audio tracks\n\n'
printf '| id | codec | channels | bitrate | language | title | delay |\n'
printf '|----|-------|----------|---------|----------|-------|-------|\n'

while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  idx=$(jqf "$line" '.index')
  codec=$(jqf "$line" '.codec_name // "?"')
  ch=$(jqf "$line" '"\(.channels // "?")" + (if .channel_layout then " (" + .channel_layout + ")" else "" end)')
  br=$(jqf "$line" '.bit_rate // ""')
  lang=$(jqf "$line" '.tags.language // ""')
  title=$(jqf "$line" '.tags.title // ""')
  start=$(jqf "$line" '.start_pts // 0')
  printf '| %s | %s | %s | %s | %s | %s | %s ms |\n' \
    "$idx" "$codec" "$ch" "$(bitrate_of "$br")" \
    "$(valid_lang "$lang")" "$(escape "$(clean_title "$title")")" "${start:-0}"
done < <(jqf "$JSON" '.streams[] | select(.codec_type=="audio") | @json')

# ------------------------------------------------------------- subtitles -----

printf '\n### Subtitle tracks\n\n'
printf '| id | codec | language | title | forced | exported as |\n'
printf '|----|-------|----------|-------|--------|-------------|\n'

while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  idx=$(jqf "$line" '.index')
  codec=$(jqf "$line" '.codec_name // "?"')
  lang=$(jqf "$line" '.tags.language // ""')
  title=$(jqf "$line" '.tags.title // ""')
  # Compare against 1 explicitly: in jq the number 0 is truthy, so
  # "if .disposition.forced" would report every track as forced.
  forced=$(jqf "$line" 'if .disposition.forced == 1 then "1" else "0" end')
  printf '| %s | %s | %s | %s | %s | %s |\n' \
    "$idx" "$codec" "$(valid_lang "$lang")" \
    "$(escape "$(clean_title "$title")")" "$forced" "$(exported_as "$codec")"
done < <(jqf "$JSON" '.streams[] | select(.codec_type=="subtitle") | @json')

printf '\nIds are absolute stream indexes, pass them straight through:\n\n'
printf '```bash\ndv2mp4.sh -i "%s" -a <audio-ids> -s <subtitle-ids>\n```\n' "$SRC"
