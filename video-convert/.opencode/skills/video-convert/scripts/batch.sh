#!/usr/bin/env bash
# batch.sh - sequential batch over a directory: one convert.sh-style ffmpeg at
# a time (GPU rule), resume by skipping existing outputs, per-file probe ->
# decision (that is exactly what convert.sh does), batch.log in the output dir,
# a final markdown table. A failure of one file does not stop the batch.
set -uo pipefail

FFMPEG_BIN="${FFMPEG_BIN:-/cygdrive/c/Program Files/ffmpeg/bin/ffmpeg.exe}"
FFPROBE_BIN="${FFPROBE_BIN:-$(dirname "$FFMPEG_BIN")/ffprobe.exe}"
SCRATCH="${SCRATCH:-/cygdrive/d/tmp/cygwin/opencode}"
PLEX_URL="${PLEX_URL:-http://127.0.0.1:32400}"
PLEX_TOKEN_FILE="${PLEX_TOKEN_FILE:-${USERPROFILE:-$HOME}/AppData/Local/Plex Media Server/.LocalAdminToken}"
CONVERT_SH="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/convert.sh"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Native binaries need Windows paths, closing quote after "$(cygpath -m ...)"
# is mandatory. (references/traps.md)
winpath() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
# Windows jq.exe emits CRLF on every value. (references/traps.md)
jqf() { printf '%s' "$1" | jq -r "$2" 2>/dev/null | tr -d '\r'; }

usage() {
  cat <<'USAGE'
Usage: batch.sh --in-dir DIR --out-dir DIR --video copy|encode --audio copy|encode
               --sub-mode none|burn|sidecar [--lang ru] [--external DIR]

Files are processed one at a time (one ffmpeg process at a time). An existing
output file is skipped, so an interrupted batch resumes. The layout follows the
plan section 1 rule: serials in serial_name/Season N/, films flat, a multi-part
film gets a catalog directory; names follow the pattern of an already-indexed
sample of the same Plex section (read through the Plex API), never invented.
USAGE
}

IN_DIR=""; OUT_DIR=""; VMODE=""; AMODE=""; SUBMODE=""; SUBLANG=""; EXTERNAL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-dir) IN_DIR="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --video) VMODE="${2:-}"; shift 2 ;;
    --audio) AMODE="${2:-}"; shift 2 ;;
    --sub-mode) SUBMODE="${2:-}"; shift 2 ;;
    --lang) SUBLANG="${2:-}"; shift 2 ;;
    --external) EXTERNAL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "$IN_DIR" && -d "$IN_DIR" ]] || { usage >&2; die "--in-dir DIR is required"; }
[[ -n "$OUT_DIR" ]] || { usage >&2; die "--out-dir is required"; }
case "$VMODE" in copy|encode) ;; *) die "--video must be copy|encode" ;; esac
case "$AMODE" in copy|encode) ;; *) die "--audio must be copy|encode" ;; esac
case "$SUBMODE" in none|burn|sidecar) ;; *) die "--sub-mode must be none|burn|sidecar" ;; esac
[[ -f "$CONVERT_SH" ]] || die "convert.sh not found next to batch.sh: $CONVERT_SH"

# Records are joined with US (0x1f), never "|": titles carry "|" and the
# columns of the final table must never shift. (references/traps.md)
SEP=$'\x1f'

# Layout of plan section 1, applied to the output path: a Season folder whose
# basename is "Season <N>" maps to OUT_DIR/Season N/; films stay flat in
# OUT_DIR. The season name is taken from the source directory itself, never
# invented. (Target resolution through the Plex API happens in step 1.)
TARGET="$OUT_DIR"
SEASON_RULE=""
IS_SERIES=0
IN_NAME="$(basename "$IN_DIR")"
if [[ "$IN_NAME" =~ ^Season\ ([0-9]+)$ ]]; then
  IS_SERIES=1
  TARGET="$OUT_DIR/Season ${BASH_REMATCH[1]}"
  SEASON_RULE="rule: in-dir basename is 'Season ${BASH_REMATCH[1]}' -> outputs go to $TARGET/"
fi
mkdir -p "$TARGET" 2>/dev/null || die "cannot create $TARGET"
LOG="$TARGET/batch.log"
EXTERNAL="${EXTERNAL:-$IN_DIR}"

# Files of the in-dir, sorted.
FILES=()
while IFS= read -r f; do
  case "$f" in *.mkv|*.mp4|*.ts|*.m4v|*.mov) FILES+=("$f") ;; esac
done < <(ls -1 "$IN_DIR" 2>/dev/null | sed "s|^|$IN_DIR/|" | sort)
[[ ${#FILES[@]} -gt 0 ]] || die "no media files in $IN_DIR"

# Layout note (plan section 1) + naming pattern from an already-indexed sample
# of the same Plex section, read through the Plex API (references/plex-api.md).
# Read-only GET; refresh is not called here. The token is never printed.
LAYOUT="film (flat collection folder; a multi-part film gets a catalog directory)"
[[ "$IN_NAME" == Season\ [0-9]* ]] && IS_SERIES=1
(( IS_SERIES )) && LAYOUT="series (serial_name/Season N/)"
TOK=""
if [[ -r "$PLEX_TOKEN_FILE" ]]; then TOK="$(head -c 42 "$PLEX_TOKEN_FILE" | tr -d '\r\n')"; fi
SAMPLE="none (no indexed section covers this directory)"
IN_DIR_WIN="$(winpath "$IN_DIR")"
if [[ -n "$TOK" ]]; then
  SECTIONS_WIN="$(winpath "$SCRATCH/batch-sections.xml")"
  curl -s -o "$SECTIONS_WIN" "$PLEX_URL/library/sections?X-Plex-Token=$TOK"
  # Match a section whose Location path is a prefix of the target directory,
  # then ask that section for its first indexed Part file.
  # The sections list is XML (jq cannot parse it, see references/plex-api.md):
  # each section is a <Directory key=... title=...> element with a
  # <Location path="D:\..."> child. Normalize the Windows backslashes in
  # Location path, then prefix-match the target directory.
  KEY="$(awk -v want="$IN_DIR_WIN" 'BEGIN { RS="<Directory " } NR > 1 {
    k = ""
    if (match($0, /key="[^"]*"/)) { k = substr($0, RSTART + 5, RLENGTH - 6) }
    # one section can have several <Location path="..."> children, every one
    # of them is a collection root; Plex XML writes backslashes in paths.
    s = $0
    while (match(s, /path="[^"]*"/)) {
      p = substr(s, RSTART + 6, RLENGTH - 7)
      gsub(/\\+/, "/", p)
      if (k != "" && index(want, p) == 1) { print k; exit }
      s = substr(s, RSTART + RLENGTH)
    }
  }' "$SCRATCH/batch-sections.xml" 2>/dev/null)"
  if [[ -n "$KEY" ]]; then
    ALL_WIN="$(winpath "$SCRATCH/batch-section-all.xml")"
    curl -s -o "$ALL_WIN" "$PLEX_URL/library/sections/$KEY/all?X-Plex-Token=$TOK"
    F="$(sed -n 's/.*file="\([^"]*\)".*/\1/p' "$SCRATCH/batch-section-all.xml" | head -1)"
    [[ -n "$F" ]] && SAMPLE="$(basename "$F")"
  fi
fi
printf 'batch: layout %s\n' "$LAYOUT"
[[ -n "$SEASON_RULE" ]] && printf 'batch: %s\n' "$SEASON_RULE"
printf 'batch: naming pattern from indexed section sample: %s\n' "$SAMPLE"
printf 'batch: file names keep the source base name, that is the scanner-friendly\n'
printf 'batch: pattern of the same section; the sample above proves it.\n'

ASS2SRT="${ASS2SRT:-$HOME/.config/opencode/skills/ass-to-srt/scripts}"

# Language token of a Plex sidecar name "<stem>.<lang>.<ext>".
# The extension is a 3-letter token itself, so counting the last token as a
# language made "movie.srt" come out as lang=srt. Strip the extension, skip the
# known subtitle extensions, accept only 2-3 lowercase letters. (subs.sh
# sidecar_lang uses the same rule.)
sidecar_lang() {
  local rel="$1" lang="und" tok
  rel="${rel%.*}"
  for tok in $(printf '%s' "$rel" | tr '.' ' '); do
    case "$tok" in srt|ass|ssa|sub|vtt) continue ;; esac
    [[ "$tok" =~ ^[a-z]{2,3}$ ]] && lang="$tok"
  done
  printf '%s' "$lang"
}
# ru <-> rus: a 3-letter tag starting with the wanted code matches.
lang_match() {
  local want="$1" tag="$2" t
  [[ -z "$want" ]] && return 0
  t="$(printf '%s' "$tag" | tr -d '\r[:space:]')"
  [[ "$t" == "$want" || "$t" == "${want}"* ]]
}
# Name token written into the sidecar file name, copied from subs.sh name_lang()
# and adapted to the single --lang token of batch.sh: when --lang matched, the
# 2-letter code is the name ("ru", the plan section 9.6 pattern ".ru.srt"). The
# raw 3-letter stream tag "rus" is never a sidecar name.
name_lang() {
  local tag="$1" want="${SUBLANG:-}" t
  [[ -z "$want" ]] && { printf '%s' "$tag"; return; }
  t="$(printf '%s' "$tag" | tr -d '\r[:space:]')"
  [[ "$t" == "$want" ]] && { printf '%s' "$want"; return; }
  [[ "$t" == "${want}"* ]] && { printf '%s' "$want"; return; }
  printf '%s' "$tag"
}

human_mb() { awk -v b="${1:-0}" 'BEGIN { printf "%.1f MB", b/1048576 }'; }

RECORDS=()
{
  printf 'batch log: %s -> %s, video=%s audio=%s sub-mode=%s lang=%s\n' \
    "$IN_DIR" "$TARGET" "$VMODE" "$AMODE" "$SUBMODE" "${SUBLANG:-all}"
  printf 'layout: %s\n' "$LAYOUT"
  printf '%s\n' "${SEASON_RULE:-layout rule: flat film collection, outputs in $TARGET/}"
  printf 'naming pattern sample: %s\n\n' "$SAMPLE"
} > "$LOG"

for src in "${FILES[@]}"; do
  base="$(basename "$src")"
  stem="${base%.*}"
  OUT="$TARGET/$stem.mkv"
  start=$SECONDS

  if [[ -e "$OUT" ]]; then
    # resume rule: an output that already exists is skipped, the source is
    # never touched, one ffmpeg per missing file only. The row has the same 6
    # fields as a success row: source, output, size, bitrate, speed, decision;
    # "skipped" belongs in the decision column, never in bitrate.
    OF="$("$FFPROBE_BIN" -v error -show_format -of json "$(winpath "$OUT")" 2>/dev/null)"
    SIZE="$(jqf "$OF" '.format.size // empty')"; BR="$(jqf "$OF" '.format.bit_rate // empty')"
    RECORDS+=("$base$SEP$stem.mkv$SEP$(human_mb "$SIZE")$SEP${BR:-?} bit/s$SEP-$SEP skipped, presumed existing: output exists")
    printf 'batch: %s skipped, output exists\n' "$base" >> "$LOG"
    continue
  fi

  FCLOG="$SCRATCH/batch-$stem.log"
  # The per-file conversion is convert.sh itself: probe -> decision -> one
  # ffmpeg -> ffprobe verification, all sequential, one process at a time.
  if [[ -n "$SUBLANG" ]]; then
    bash "$CONVERT_SH" --in "$src" --out "$OUT" --video "$VMODE" --audio "$AMODE" \
      --sub-mode "$SUBMODE" --lang "$SUBLANG" > "$FCLOG" 2>&1
  else
    bash "$CONVERT_SH" --in "$src" --out "$OUT" --video "$VMODE" --audio "$AMODE" \
      --sub-mode "$SUBMODE" > "$FCLOG" 2>&1
  fi
  rc=$?
  wall=$((SECONDS - start))
  DEC="$(sed -n 's/^convert: //p' "$FCLOG" | tr '\n' ';' | sed 's/;$//')"
  printf '%s\n' "$DEC" >> "$LOG"

  if [[ $rc -ne 0 ]]; then
    # A failure of one file does not stop the batch; convert.sh already deleted
    # the partial output on verification failure. The row carries the same 6
    # fields as a success row: the output column is a -<stem>.mkv placeholder,
    # size/bitrate/speed/decision sit in their own columns.
    FSRC="$(stat -c%s "$src" 2>/dev/null || printf 0)"
    FDAT="$(printf '%s' "$DEC" | tr '\n' ';')"
    RECORDS+=("$base$SEP-$stem.mkv$SEP$(human_mb "$FSRC")$SEP- bit/s$SEP wall ${wall}s$SEP FAILED rc=$rc${FDAT:+; }${FDAT}")
    printf 'batch: %s FAILED rc=%s\n' "$base" "$rc" >> "$LOG"
    tail -25 "$FCLOG" >> "$LOG"
    continue
  fi

  # External sidecars from --external (default: the in-dir) move next to the
  # output for this file. PGS is never exported; ASS goes through ass-to-srt.
  # The block is BELOW the resume skip above (a rerun of an interrupted batch
  # must not re-export ASS for a file that is already converted) and BELOW the
  # per-file conversion rc check above (a failed conversion leaves no orphan
  # sidecars in the collection, journal item 5).
  # Dedupe: convert.sh has already exported the embedded subtitle streams of this
  # file, so a language whose sidecar exists next to the output is not exported a
  # second time; the plan section 4 forbids duplicate sidecars for one language.
  if [[ "$SUBMODE" == "sidecar" ]]; then
    EXT_TAG=0
    for f in "$EXTERNAL/$stem".*; do
      case "$f" in *.srt|*.ass|*.ssa) ;; *) continue ;; esac
      [[ -f "$f" ]] || continue
      lang="$(sidecar_lang "$(basename "$f")")"
      lang_match "$SUBLANG" "$lang" || continue
      nl="$(name_lang "$lang")"
      tag="ext$EXT_TAG"
      EXT_TAG=$((EXT_TAG + 1))
      if [[ -e "$TARGET/$stem.$nl.srt" ]]; then
        printf 'batch: sidecar %s skipped, %s.%s.srt is already exported for this file\n' \
          "$(basename "$f")" "$stem" "$nl" >> "$LOG"
        continue
      fi
      p="$TARGET/$stem.$nl.srt"
      [[ -e "$p" ]] && p="$TARGET/$stem.$tag.$nl.srt"
      case "$f" in
        *.srt)
          if cp "$f" "$p"; then
            printf 'batch: sidecar %s -> %s\n' "$(basename "$f")" "$(basename "$p")" >> "$LOG"
          else
            printf 'batch: sidecar copy FAILED for %s\n' "$(basename "$f")" >> "$LOG"
          fi
          ;;
        *.ass|*.ssa)
          # convert.py writes "<stem>.srt" from the stem of its input, so the
          # scratch copy is named after the target sidecar stem: the result is
          # exactly "<name>.<2-letter lang>.srt", never a raw stream tag.
          scc="$SCRATCH/$(basename "${p%.*}").ass"
          cp "$f" "$scc"
          if python3 "$ASS2SRT/convert.py" --input "$scc" --out-dir "$TARGET" >> "$LOG" 2>&1; then
            printf 'batch: sidecar %s -> %s\n' "$(basename "$f")" "$(basename "$p")" >> "$LOG"
          else
            printf 'batch: ass-to-srt failed for %s\n' "$(basename "$f")" >> "$LOG"
          fi
          rm -f "$scc"
          ;;
      esac
    done
  fi

  OF="$("$FFPROBE_BIN" -v error -show_format -of json "$(winpath "$OUT")" 2>/dev/null)"
  SIZE="$(jqf "$OF" '.format.size // empty')"; BR="$(jqf "$OF" '.format.bit_rate // empty')"
  SPEED="$(grep -o 'speed=[0-9.]*x' "$FCLOG" | tail -1)"
  [[ -n "$SPEED" ]] || SPEED="wall ${wall}s"
  RECORDS+=("$base$SEP$stem.mkv$SEP$(human_mb "$SIZE")$SEP${BR:-?} bit/s$SEP$SPEED$SEP$DEC")
  printf 'batch: %s -> %s done\n' "$base" "$stem.mkv" >> "$LOG"
done

# Final markdown table. Titles inside decisions can carry "|", the columns are
# escaped so they never shift; records are US-separated inside the script.
printf '\n## Batch result\n\n'
printf '| source | output | size | bitrate | speed | decisions |\n'
printf '|--------|--------|------|---------|-------|-----------|\n'
{
  printf '\n## Batch result\n\n'
  printf '| source | output | size | bitrate | speed | decisions |\n'
  printf '|--------|--------|------|---------|-------|-----------|\n'
} >> "$LOG"
for rec in "${RECORDS[@]}"; do
  IFS="$SEP" read -r a b c d e f <<< "$rec"
  f="${f//|/\|}"
  printf '| %s | %s | %s | %s | %s | %s |\n' "$a" "$b" "$c" "$d" "$e" "$f"
  printf '| %s | %s | %s | %s | %s | %s |\n' "$a" "$b" "$c" "$d" "$e" "$f" >> "$LOG"
done
printf 'batch: log written to %s\n' "$LOG"
exit 0
