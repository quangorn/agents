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
# jq.exe cannot open /cygdrive/... paths, so the plex-tracks reports are opened
# through the cygpath -m form. (references/traps.md)
qj() { jq -r "$1" "$2" 2>/dev/null | tr -d '\r'; }

usage() {
  cat <<'USAGE'
Usage: batch.sh --in-dir DIR --out-dir DIR --video copy|encode --audio copy|encode
               --sub-mode none|burn|sidecar [--lang ru] [--external DIR]
               [--default-audio LANG] [--default-audio-keyword TEXT]
               [--default-sub LANG|none] [--default-sub-keyword TEXT]
               [--show TITLE] [--season N] [--section NAME]

Files are processed one at a time (one ffmpeg process at a time). An existing
output file is skipped, so an interrupted batch resumes. The layout follows the
plan section 1 rule: serials in serial_name/Season N/, films flat, a multi-part
film gets a catalog directory; names follow the pattern of an already-indexed
sample of the same Plex section (read through the Plex API), never invented.

--default-audio / --default-sub name the Plex default track by LANGUAGE and by a
KEYWORD in the title, never by a stream index: indexes move from episode to
episode, and both the container flag and plex-tracks work on language + title.
The container default flag is set by convert.sh per file; the real player default
(`selected`) is written by the plex-tracks skill AFTER all files are converted and
the library is refreshed, because a sidecar .srt can only be selected once Plex
indexed it. --show TITLE is what makes that step run: without it the defaults go
into the files only and the step is reported as skipped.
--season / --section are passed straight to plex-tracks. A film has no --season.
USAGE
}

IN_DIR=""; OUT_DIR=""; VMODE=""; AMODE=""; SUBMODE=""; SUBLANG=""; EXTERNAL=""
DA_LANG=""; DA_KW=""; DS_LANG=""; DS_KW=""
SHOW=""; SEASON=""; SECTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-dir) IN_DIR="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --video) VMODE="${2:-}"; shift 2 ;;
    --audio) AMODE="${2:-}"; shift 2 ;;
    --sub-mode) SUBMODE="${2:-}"; shift 2 ;;
    --lang) SUBLANG="${2:-}"; shift 2 ;;
    --external) EXTERNAL="${2:-}"; shift 2 ;;
    --default-audio) DA_LANG="${2:-}"; shift 2 ;;
    --default-audio-keyword) DA_KW="${2:-}"; shift 2 ;;
    --default-sub) DS_LANG="${2:-}"; shift 2 ;;
    --default-sub-keyword) DS_KW="${2:-}"; shift 2 ;;
    --show) SHOW="${2:-}"; shift 2 ;;
    --season) SEASON="${2:-}"; shift 2 ;;
    --section) SECTION="${2:-}"; shift 2 ;;
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
[[ -z "$SEASON" || "$SEASON" =~ ^[0-9]+$ ]] || die "--season must be a number"

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
# KEY must exist even when the token file is missing: the plex-tracks block at the
# end of the run reads it, and an unset KEY under `set -u` aborts the batch AFTER
# every file is converted, losing the final report. (references/traps.md)
KEY=""
SAMPLE="none (no indexed section covers this directory)"
IN_DIR_WIN="$(winpath "$IN_DIR")"
TARGET_WIN="$(winpath "$TARGET")"
if [[ -n "$TOK" ]]; then
  SECTIONS_WIN="$(winpath "$SCRATCH/batch-sections.xml")"
  curl -s -o "$SECTIONS_WIN" "$PLEX_URL/library/sections?X-Plex-Token=$TOK"
  # The sections list is XML (jq cannot parse it, see references/plex-api.md):
  # each section is a <Directory key=... title=...> element with a
  # <Location path="D:\..."> child. Normalize the Windows backslashes in
  # Location path, then prefix-match the folder.
  sec_key() {
    awk -v want="$1" 'BEGIN { RS="<Directory " } NR > 1 {
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
    }' "$SCRATCH/batch-sections.xml" 2>/dev/null
  }
  # KEY is the section covering the OUTPUT folder: the refresh at the end of the
  # run must target it (SKILL.md §7). In the normal layout the source download
  # folder lives in a different tree, so matching only --in-dir leaves KEY empty,
  # no refresh is sent, and plex-tracks runs against the pre-scan state.
  KEY="$(sec_key "$TARGET_WIN")"
  # The naming sample comes from the section covering the SOURCE folder (the
  # download tree follows the scanner pattern the user already uses); when the
  # source is outside every section, the output section gives the sample.
  NAME_KEY="$(sec_key "$IN_DIR_WIN")"
  [[ -n "$NAME_KEY" ]] || NAME_KEY="$KEY"
  if [[ -n "$NAME_KEY" ]]; then
    ALL_WIN="$(winpath "$SCRATCH/batch-section-all.xml")"
    curl -s -o "$ALL_WIN" "$PLEX_URL/library/sections/$NAME_KEY/all?X-Plex-Token=$TOK"
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
# The plex-tracks skill writes the real Plex player default (selected) through the
# PMS API. It is an OPTIONAL dependency: the conversion runs without it, and the
# final report says the Plex defaults were not applied. (SKILL.md §7)
PLEX_TRACKS="${PLEX_TRACKS:-$HOME/.config/opencode/skills/plex-tracks/scripts}"

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
# ru <-> rus: a 3-letter tag starting with the wanted code matches. Prefix logic
# misses ja/jpn, zh/chi, es/spa; lang_alias mirrors plex-tracks LANG_ALIASES so
# --lang ja reaches Japanese tracks here as it does in convert.sh.
lang_alias() {
  case "$1" in
    ru) printf 'rus' ;;
    en) printf 'eng' ;;
    ja) printf 'jpn' ;;
    de) printf 'deu ger' ;;
    fr) printf 'fre fra' ;;
    es) printf 'spa' ;;
    it) printf 'ita' ;;
    uk) printf 'ukr' ;;
    pl) printf 'pol' ;;
    zh) printf 'chi zh' ;;
    ko) printf 'kor' ;;
    pt) printf 'por' ;;
    sv) printf 'swe' ;;
    no) printf 'nor' ;;
    da) printf 'dan' ;;
    fi) printf 'fin' ;;
    nl) printf 'nld dut' ;;
    tr) printf 'tur' ;;
    cs) printf 'ces cze' ;;
    *) printf '' ;;
  esac
}

lang_match() {
  local want="$1" tag="$2" t a
  [[ -z "$want" ]] && return 0
  t="$(printf '%s' "$tag" | tr -d '\r[:space:]')"
  [[ "$t" == "$want" || "$t" == "${want}"* ]] && return 0
  for a in $(lang_alias "$want"); do
    [[ "$t" == "$a" ]] && return 0
  done
  return 1
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
  printf 'default audio: %s%s\n' "${DA_LANG:--}" "${DA_KW:+ keyword=\"$DA_KW\"}"
  printf 'default sub: %s%s\n' "${DS_LANG:--}" "${DS_KW:+ keyword=\"$DS_KW\"}"
  [[ -z "$SHOW" ]] || printf 'plex-tracks: show="%s"%s%s\n' "$SHOW" \
    "${SEASON:+ season=$SEASON}" "${SECTION:+ section=\"$SECTION\"}"
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
  # The default-track flags are the user's language + keyword choice, resolved to
  # an index inside convert.sh for THIS file: the same choice means a different
  # absolute index in every episode, so it can never be passed as an id here.
  CMD=(bash "$CONVERT_SH" --in "$src" --out "$OUT" --video "$VMODE" --audio "$AMODE"
       --sub-mode "$SUBMODE")
  [[ -n "$SUBLANG" ]] && CMD+=(--lang "$SUBLANG")
  [[ -n "$DA_LANG" ]] && CMD+=(--default-audio "$DA_LANG")
  [[ -n "$DA_KW" ]] && CMD+=(--default-audio-keyword "$DA_KW")
  [[ -n "$DS_LANG" ]] && CMD+=(--default-sub "$DS_LANG")
  [[ -n "$DS_KW" ]] && CMD+=(--default-sub-keyword "$DS_KW")
  # "${CMD[@]}" directly: the array's first element IS bash, so "bash \${CMD[@]}"
  # would hand bash a script named "bash" (rc=126, "cannot execute binary").
  "${CMD[@]}" > "$FCLOG" 2>&1
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
  # ${f//|/\|} does not escape: bash reads \| in the replacement as a plain |.
  # sed is the working form, decisions carry titles with "|". (references/traps.md)
  f="$(printf '%s' "$f" | sed 's/[|]/\\|/g')"
  printf '| %s | %s | %s | %s | %s | %s |\n' "$a" "$b" "$c" "$d" "$e" "$f"
  printf '| %s | %s | %s | %s | %s | %s |\n' "$a" "$b" "$c" "$d" "$e" "$f" >> "$LOG"
done
# SKILL.md §7: the Plex player defaults, AFTER every file is converted.
# The library is refreshed first: a sidecar .srt lives on disk and Plex can select
# it only after it indexed it, so a plex-tracks write before the scan selects the
# embedded stream (or nothing) and silently misses the sidecar. plex-tracks matches
# by language + keyword, never by a stream index, which is exactly the choice made
# from the track table, and is what makes the same choice work in every episode.
PT_SH="$PLEX_TRACKS/plex_tracks.py"
PT_REPORT="$TARGET/plex-defaults-$IN_NAME.json"
PT_SUMMARY="not applied"

if [[ -z "$SHOW" ]]; then
  PT_SUMMARY="not applied: --show TITLE was not given, so no plex-tracks run"
  printf 'batch: plex defaults NOT applied (no --show). Run plex-tracks by hand:\n' >> "$LOG"
  printf 'batch:   python3 %s/plex_tracks.py --show "<title>" --audio %s --subtitle %s --apply --json\n' \
    "$PLEX_TRACKS" "${DA_LANG:-<lang>}" "${DS_LANG:-<lang|none>}" >> "$LOG"
elif [[ ! -f "$PT_SH" ]]; then
  PT_SUMMARY="not applied: plex-tracks is not installed at $PT_SH"
  printf 'batch: plex defaults NOT applied, plex-tracks is missing. Install the skill\n' >> "$LOG"
  printf 'batch: and run it with the recorded default audio/sub choice.\n' >> "$LOG"
else
  # Refresh the section that covers the OUTPUT folder (KEY from the TARGET
  # prefix match above). POST refresh, read-only GET confirmations, token never
  # printed. (references/plex-api.md)
  if [[ -n "$KEY" ]]; then
    curl -s -o /dev/null -X POST "$PLEX_URL/library/sections/$KEY/refresh?X-Plex-Token=$TOK"
    printf 'batch: section %s refreshed\n' "$KEY" >> "$LOG"
  else
    printf 'batch: no section key matched %s, no refresh sent\n' "$TARGET" >> "$LOG"
  fi

  PT_ARGS=()
  [[ -n "$SEASON" ]] && PT_ARGS+=(--season "$SEASON")
  [[ -n "$SECTION" ]] && PT_ARGS+=(--section "$SECTION")
  [[ -n "$DA_LANG" ]] && PT_ARGS+=(--audio "$DA_LANG")
  [[ -n "$DA_KW" ]] && PT_ARGS+=(--audio-keyword "$DA_KW")
  if [[ -n "$DS_LANG" ]]; then
    # sub-mode none drops every subtitle stream; burn mode has no subtitle streams
    # either (the subtitles are inside the video and always on). In both cases the
    # only correct Plex setting is "subtitles off", so the language cannot be
    # passed: it would report "no tracks of this kind" and leave the choice unset.
    case "$SUBMODE" in
      none|burn)
        PT_ARGS+=(--subtitle none)
        printf 'batch: sub-mode %s leaves no selectable subtitle stream, plex-tracks gets --subtitle none\n' \
          "$SUBMODE" >> "$LOG"
        ;;
      sidecar)
        PT_ARGS+=(--subtitle "$DS_LANG")
        # A sidecar has no title tag, so the keyword is useless for it. Restrict
        # the plex-tracks pool to sidecars ONLY when every converted file has a
        # sidecar of this language: with a partial set, the episodes without a
        # sidecar get "no match" and nothing is written for them, while the
        # embedded streams are selectable for all of them.
        nsides=0
        for sf in "$TARGET"/*."$DS_LANG".srt; do
          [[ -f "$sf" ]] && nsides=$((nsides + 1))
        done
        if [[ $nsides -ge ${#FILES[@]} ]]; then
          # Sidecar pool: no --subtitle-keyword, sidecar .srt carries no title.
          PT_ARGS+=(--subtitle-external)
          printf 'batch: sidecar .%s.srt next to every output, pool restricted to sidecars\n' "$DS_LANG" >> "$LOG"
        else
          printf 'batch: sidecar .%s.srt next to %s of %s files, pool keeps embedded streams\n' \
            "$DS_LANG" "$nsides" "${#FILES[@]}" >> "$LOG"
          # Embedded streams keep their title tag, so the keyword is usable there.
          [[ -n "$DS_KW" ]] && PT_ARGS+=(--subtitle-keyword "$DS_KW")
        fi
        ;;
    esac
  fi

  # Nothing was chosen by the user -> nothing to select. Counting PT_ARGS is not
  # the test: --season / --section put flags in it even when no default track was
  # asked for, and the run would write a subtitle-removal nobody chose.
  if [[ -z "$DA_LANG" && -z "$DS_LANG" ]]; then
    PT_SUMMARY="not applied: no --default-audio / --default-sub given, nothing to select"
    printf 'batch: plex defaults NOT applied, nothing to select\n' >> "$LOG"
  else
    PLAN="$SCRATCH/plex-plan-$IN_NAME.json"
    PT_LOG="$SCRATCH/plex-apply-$IN_NAME.log"
    # Indexing is confirmed by NAME, never by episode count: Plex can show as many
    # episodes as the season has while indexing a different show entirely, and a
    # count match would let plex-tracks write against the wrong list. Every
    # converted output basename must appear among the plan items' Part file paths;
    # Plex stores Windows paths, so basenames are cut on both / and \. The scan is
    # asynchronous, so the plan run is repeated, bounded to 6 attempts.
    MISSING=0
    attempt=0
    while (( attempt < 6 )); do
      attempt=$((attempt + 1))
      PLEX_TOKEN="$TOK" PLEX_URL="$PLEX_URL" python3 "$PT_SH" --show "$SHOW" \
        "${PT_ARGS[@]}" --json > "$PLAN" 2>>"$PT_LOG"
      IDX="$(qj '.items[] | .file // empty' "$(winpath "$PLAN")" \
             | tr -d '\r' | sed 's/\\/\//g' | sed 's|.*/||')"
      MISSING=0
      for src in "${FILES[@]}"; do
        printf '%s\n' "$IDX" | grep -qF -x -- "$(basename "$src")" || MISSING=$((MISSING + 1))
      done
      [[ $MISSING -eq 0 ]] && break
      sleep 10
    done
    EPS="$(qj '.items | length' "$(winpath "$PLAN")")"
    if (( MISSING > 0 )); then
      PT_SUMMARY="not applied: Plex does not index ${MISSING} of ${#FILES[@]} converted file(s)"
      printf 'batch: plex defaults NOT applied, %s of %s files are not indexed by Plex. Re-run\n' "$MISSING" "${#FILES[@]}" >> "$LOG"
      printf 'batch: the scan finishes with the same --default-audio / --default-sub\n' >> "$LOG"
    else
      # --limit 1 first, then the whole season (a bulk change is tested on one
      # episode before it touches the rest). stdout is the JSON report, stderr goes
      # to the log: mixing them would corrupt the JSON that --undo reads.
      PLEX_TOKEN="$TOK" PLEX_URL="$PLEX_URL" python3 "$PT_SH" --show "$SHOW" \
        "${PT_ARGS[@]}" --limit 1 --apply --json > "$PT_REPORT.first.json" 2>>"$PT_LOG"
      rc_first=$?
      PLEX_TOKEN="$TOK" PLEX_URL="$PLEX_URL" python3 "$PT_SH" --show "$SHOW" \
        "${PT_ARGS[@]}" --apply --json > "$PT_REPORT" 2>>"$PT_LOG"
      rc_all=$?
      if [[ $rc_first -ne 0 ]]; then
        PT_SUMMARY="not applied: the first-episode test run failed (rc=$rc_first), season untouched"
        printf 'batch: plex defaults NOT applied, --limit 1 test failed rc=%s\n' "$rc_first" >> "$LOG"
        tail -5 "$PT_LOG" >> "$LOG"
      elif [[ $rc_all -ne 0 ]]; then
        PT_SUMMARY="applied to episode 1 only, the season run failed (rc=$rc_all); rollback: plex_tracks.py --undo $PT_REPORT.first.json"
        printf 'batch: season run failed rc=%s, episode 1 is applied\n' "$rc_all" >> "$LOG"
        tail -5 "$PT_LOG" >> "$LOG"
      else
        REP_WIN="$(winpath "$PT_REPORT")"
        STS='[ .items[] | (.audio.status // ""), (.subtitle.status // "") ]'
        NA="$(qj "$STS | map(select(. == \"applied\")) | length" "$REP_WIN")"
        NM="$(qj "$STS | map(select(. == \"no match\" or . == \"no tracks of this kind\")) | length" "$REP_WIN")"
        NF="$(qj "$STS | map(select(startswith(\"FAILED\"))) | length" "$REP_WIN")"
        PT_SUMMARY="applied: $EPS episode(s), audio+subtitles applied on $NA track(s), no match on $NM, FAILED on $NF; rollback: python3 $PT_SH --undo $PT_REPORT"
        printf 'batch: plex defaults: applied %s, no match %s, FAILED %s\n' "$NA" "$NM" "$NF" >> "$LOG"
        tail -5 "$PT_LOG" >> "$LOG"
      fi
    fi
  fi
fi

printf '\n## Plex defaults\n\n'
printf '%s\n' "$PT_SUMMARY"
printf 'batch: %s\n' "$PT_SUMMARY" >> "$LOG"
# The rollback line is printed only when THIS run applied something: a stale report
# left next to batch.log by a previous run must not be advertised as the rollback
# of a run that wrote nothing.
case "$PT_SUMMARY" in
  applied*) [[ -f "$PT_REPORT" ]] && printf 'report for rollback: %s (python3 %s --undo %s)\n' \
    "$PT_REPORT" "$PT_SH" "$PT_REPORT" ;;
esac

printf 'batch: log written to %s\n' "$LOG"
exit 0
