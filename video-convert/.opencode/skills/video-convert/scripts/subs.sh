#!/usr/bin/env bash
# subs.sh - the subtitle path of the video-convert skill (plan section 4, SKILL.md
# section 3). Everything is read-only on the source; outputs go to --out-dir.
#
# sidecar mode:
#   embedded ASS/SSA  -> mkvextract to "<base>.<lang>.ass" next to the target
#       video (the styled original carries fonts and positioning, so the .ass
#       travels with the file), then python3 "$ASS2SRT/convert.py" writes the
#       default "colors" variant as "<base>.<lang>.srt".
#   embedded subrip   -> mkvextract straight to "<base>.<lang>.srt", no conversion.
#   PGS               -> REFUSED as a sidecar: PGS lives only inside the
#       container, ffmpeg cannot encode PGS and cannot write .sup, and an
#       external .sup is not picked up by Plex. A .sup archive export happens
#       only with --export-sup, through mkvextract, verified by the PG magic
#       "50 47". No OCR. (references/traps.md, references/lg-oled-codecs.md)
#   external .ass packs from --external DIR: more than one pack -> print the
#       pack list with counts and exit rc=2, the agent must ask the user which
#       pack; never pick silently. A single pack is converted.
#
# burn mode:
#   ONE ffmpeg invocation burns the chosen subtitle with -vf subtitles= (the
#   subtitle stream is NOT in the output), video re-encoded with the fixed HEVC
#   set of SKILL.md section 2, audio by the ladder of SKILL.md section 3 (the
#   same audio_plan() as convert.sh: copy-set <=6 channels copied, >6 channels
#   -> E-AC-3 5.1, DTS re-encoded), output "<base>.mkv" in --out-dir. Fonts:
#   the subtitle's own folder first, then the system fonts - the same
#   implementation as convert.sh, so there is one burn pattern.
#
# CLI contract (SKILL.md):
#   bash scripts/subs.sh --in FILE --out-dir DIR --lang ru --mode sidecar|burn \
#        [--external DIR|FILE] [--sub-ids IDS] [--export-sup]
# --lang is repeatable and a CSV list is allowed: "--lang ru,eng" is the same as
# "--lang ru --lang eng". Track ids are ABSOLUTE stream indexes, the ones
# probe.sh prints and "ffmpeg -map 0:ID" expects. Language "und" is included,
# with a note. Sidecar names follow the plan section 1 pattern
# "<video filename>.<lang>.srt" next to the target video.
set -uo pipefail

FFMPEG_BIN="${FFMPEG_BIN:-/cygdrive/c/Program Files/ffmpeg/bin/ffmpeg.exe}"
FFPROBE_BIN="${FFPROBE_BIN:-$(dirname "$FFMPEG_BIN")/ffprobe.exe}"
SCRATCH="${SCRATCH:-/cygdrive/d/tmp/cygwin/opencode}"
ASS2SRT="${ASS2SRT:-$HOME/.config/opencode/skills/ass-to-srt/scripts}"
WINFONTS="${WINFONTS:-C:/Windows/Fonts}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf 'subs: %s\n' "$*"; }

# Native binaries (ffmpeg, ffprobe, mkvmerge, mkvextract) do not understand
# /cygdrive/... paths; the closing quote after "$(cygpath -m ...)" is mandatory.
# (references/traps.md)
winpath() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

# Windows jq.exe emits CRLF on every value: "rus\r" fails ^[a-z]{2,3}$ and the
# language shows as "und", "subrip\r" misses the case arms. Strip \r centrally.
# (references/traps.md)
jqf() { printf '%s' "$1" | jq -r "$2" 2>/dev/null | tr -d '\r'; }

need_tool() { command -v "$1" >/dev/null 2>/dev/null || die "missing required tool: $1"; }

# The subtitles filter needs ':' in a Windows path escaped: ffmpeg filter
# parsing is two levels, the graph level eats one backslash, so 'D:' inside a
# filter value needs \: escaped once at argument level and the whole value
# wrapped in single quotes. Copied from convert.sh verbatim: one burn pattern.
fesc() {
  local s="$1"
  s=$(printf '%s' "$s" | sed 's/:/\\:/g')
  printf "%s" "'$s'"
}

usage() {
  cat <<'USAGE'
Usage: subs.sh --in FILE --out-dir DIR --lang ru --mode sidecar|burn [options]

  --in FILE        source MKV/MP4. Read-only: the source is never modified.
  --out-dir DIR    where the sidecars, the .ass copies and the burned .mkv go.
                   Sidecars are named "<video base>.<lang>.srt", the plan
                   section 1 pattern next to the target video; out-dir stands
                   in for the target location.
  --lang LIST      ru, or ru,eng. Repeatable: --lang ru --lang eng. A 3-letter
                   stream tag matches the 2-letter prefix (rus <-> ru).
                   "und" tracks are always included, with a note.
  --mode sidecar   ASS/SSA -> mkvextract .ass + ass-to-srt .srt; subrip -> .srt
                   extracted directly; PGS is refused as a sidecar; external
                   packs via --external DIR.
  --mode burn      one ffmpeg invocation with -vf subtitles=, video re-encoded
                   with the fixed HEVC set, audio by the ladder (copy-set <=6
                   channels copied, >6 channels -> E-AC-3 5.1, DTS re-encoded),
                   no subtitle streams in the output, zero transcode on the TV.
  --external DIR   sidecar: a directory of external .ass packs. More than one
                   pack -> the pack list with counts is printed and the script
                   exits rc=2: the agent must ask the user which pack.
                   burn: one external .srt/.ass/.ssa file to burn in.
  --sub-ids IDS    burn: absolute stream index of the embedded subtitle to burn
                   (mkvextract first; PGS is never burnable).
  --export-sup     sidecar: export the PGS .sup for the archive through
                   mkvextract, PG magic "50 47" verified. This is NOT a sidecar
                   path: Plex does not read an external .sup.
  -h, --help       this help
USAGE
}

IN=""; OUT_DIR=""; MODE=""; LANG_RAW=""; EXTERNAL=""; SUB_IDS=""; EXPORT_SUP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) IN="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --lang) LANG_RAW="$LANG_RAW ${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --external) EXTERNAL="${2:-}"; shift 2 ;;
    --sub-ids) SUB_IDS="${2:-}"; shift 2 ;;
    --export-sup) EXPORT_SUP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "$IN" && -f "$IN" ]] || { usage >&2; die "--in FILE is required"; }
[[ -n "$OUT_DIR" ]] || { usage >&2; die "--out-dir DIR is required"; }
case "$MODE" in sidecar|burn) ;; *) die "--mode must be sidecar|burn" ;; esac
command -v cygpath >/dev/null 2>/dev/null || die "cygpath is required to pass Windows paths to native tools"
need_tool jq

# --lang tokens: repeatable and CSV. Lowercase so "RU,ENG" matches "rus".
LANGS=()
read -r -a LANGS <<< "$(printf '%s' "$LANG_RAW" | tr ',' ' ')"
for i in "${!LANGS[@]}"; do
  LANGS[$i]="$(printf '%s' "${LANGS[$i]}" | tr 'A-Z' 'a-z')"
done

# Language filter. Empty filter = everything. "und" is always included (the
# caller prints the note). ru <-> rus: a 3-letter tag starting with the wanted
# 2-letter code matches, exactly as in convert.sh.
lang_match() {
  local tag="$1" t want
  [[ ${#LANGS[@]} -eq 0 ]] && return 0
  t="$(printf '%s' "$tag" | tr -d '\r[:space:]')"
  [[ "$t" == "und" ]] && return 0
  for want in "${LANGS[@]}"; do
    [[ "$t" == "$want" || "$t" == "${want}"* ]] && return 0
  done
  return 1
}

# Name token to write into the sidecar file name. When a --lang filter matched,
# the requested code is used ("ru", the plan section 1 pattern), otherwise the
# stream tag itself.
name_lang() {
  local tag="$1" want
  [[ ${#LANGS[@]} -eq 0 ]] && { printf '%s' "$tag"; return; }
  for want in "${LANGS[@]}"; do
    [[ "$tag" == "$want" ]] && { printf '%s' "$want"; return; }
  done
  for want in "${LANGS[@]}"; do
    [[ "$tag" == "${want}"* ]] && { printf '%s' "$want"; return; }
  done
  printf '%s' "$tag"
}

# Plex sidecar name "<stem>.<lang>.<ext>" -> language token, as probe.sh.
# The extension is stripped FIRST, exactly as convert.sh does (rel=${rel%.*}):
# without that strip the trailing extension is tokenized, so "test.ru.ass" gets
# the language "ass" and external packs are silently skipped by --lang and
# renamed to "<base>.ass.srt".
sidecar_lang() {
  local rel="$1" lang="und" tok
  rel="${rel%.*}"
  for tok in $(printf '%s' "$rel" | tr '.' ' '); do
    [[ "$tok" =~ ^[a-z]{2,3}$ ]] && lang="$tok"
  done
  printf '%s' "$lang"
}

# Base name: the file base of --in, with the HDR/DV markers stripped at token
# boundaries, the same boundary rule as dv.sh. Whitespace is kept: the sidecars
# already in the collection keep the spaces of the source name, and the Plex
# scanner reads "<video filename>.<lang>.srt" as one name.
#
# One HDR/DV regex, written once and applied twice inside a single sed. Two
# markers can be adjacent ("...Hybrid.DV.HDR10+ Group") and every substitution
# eats the separator that sits between them, so a single pass leaves the second
# marker standing: the double pass of dv.sh is kept, the duplicated literal is
# not.
HDR_RE='s/([. _-]|^)(HDR10\+?|HDR|DV|Dolby[ .]?Vision)([. _-]|$)/./gI'
IN_BASE="$(basename "$IN")"
IN_BASE="${IN_BASE%.*}"
OUT_BASE="$(printf '%s' "$IN_BASE" \
  | sed -E -e "$HDR_RE" -e "$HDR_RE" \
  | sed -E 's/\.{2,}/./g; s/[ ._-]+$//; s/^[ ._-]+//')"
[[ -n "$OUT_BASE" ]] || OUT_BASE="video"

SRC_WIN="$(winpath "$IN")"
mkdir -p "$OUT_DIR" 2>/dev/null || die "cannot create $OUT_DIR"

# Plain -show_streams, NO -show_entries combination: ffmpeg 4.4 silently drops
# fields when the two are combined. (references/traps.md)
STREAM_JSON="$("$FFPROBE_BIN" -v error -show_streams -of json "$SRC_WIN" 2>/dev/null)"
FORMAT_JSON="$("$FFPROBE_BIN" -v error -show_format -of json "$SRC_WIN" 2>/dev/null)"
# A corrupt / truncated file makes ffprobe print an EMPTY stream list and exit
# 0, so a non-empty JSON string is not enough: the stream count is the guard.
# Without it every later jq lookup comes back empty and the script runs on to a
# partial output with nothing to convert.
[[ -n "$STREAM_JSON" ]] && [[ "$(jqf "$STREAM_JSON" '.streams | length')" -gt 0 ]] || die "ffprobe cannot read $IN"

# Lookup by absolute index, select(.index==N). "-select_streams s:N" is relative
# to the stream type and silently returns the wrong track; never used for
# metadata. (references/traps.md, the most dangerous trap)
smeta() {
  local idx="$1" expr="$2" out
  out="$(jqf "$STREAM_JSON" ".streams[] | select(.index==$idx) | ($expr) // empty")"
  printf '%s' "$out" | tr -d '\r' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//'
}

SUB_IDS_AVAIL="$(jqf "$STREAM_JSON" '.streams[] | select(.codec_type=="subtitle") | .index' | tr '\n' ' ')"
AUDIO_IDS_AVAIL="$(jqf "$STREAM_JSON" '.streams[] | select(.codec_type=="audio") | .index' | tr '\n' ' ')"
VID_IDX="$(jqf "$STREAM_JSON" '[ .streams[] | select(.codec_type=="video") ]
  | .[0].index // empty')"

# The scratch work dir stays a Cygwin path for the bash builtins (mktemp, cp,
# redirections, tail, python3). There is no WORK_WIN variable: every argument
# that goes to a native binary is wrapped in "$(winpath ...)" inline at the call
# site (mkvextract tracks "$SRC_WIN" "$TRACK_ID:$(winpath "$sup")"), so no
# native tool ever sees a Cygwin path.
# (references/traps.md: mktemp returns a path ffmpeg cannot write to; the closing
# quote after "$(cygpath -m ...)" is mandatory)
WORK="$(mktemp -d "$SCRATCH/subs.XXXXXXXX" 2>/dev/null)" || die "cannot create scratch work dir"
# The EXIT trap is an inline string, as in dv.sh: cleanup runs on every exit,
# including die().
trap 'rm -rf "$WORK"' EXIT

# Records inside the script are joined with US (0x1f), never "|": titles
# legitimately carry "|". (references/traps.md)
SEP=$'\x1f'

# mkvmerge -i lists Track IDs in file order; the nth listed Track ID is ffprobe
# stream index n-1. Every extraction reads its Track ID out of this list and
# checks the positional mapping, never assumes it: a localized mkvmerge prints
# "Идентификатор дорожки N:", attachment lines also carry " N: ", so a shifted
# mapping has to be loud, not silent. (references/traps.md: ID из mkvmerge -i)
TRACK_IDS=()
TRACK_ID=""
track_ids() {
  [[ ${#TRACK_IDS[@]} -gt 0 ]] && return 0
  mapfile -t TRACK_IDS < <(mkvmerge -i "$SRC_WIN" 2>/dev/null | tr -d '\r' \
    | sed -n 's/.* \([0-9]\{1,\}\): .*/\1/p')
  [[ ${#TRACK_IDS[@]} -gt 0 ]]
}

# track_id <absolute stream index>: sets TRACK_ID, returns 1 when the mapping is
# not provable. die() runs in the caller, not inside command substitution.
track_id() {
  local id="$1"
  need_tool mkvmerge
  need_tool mkvextract
  track_ids || return 1
  [[ ${#TRACK_IDS[@]} -gt id ]] || return 1
  TRACK_ID="${TRACK_IDS[$id]}"
  [[ "$TRACK_ID" == "$id" ]] || return 1
  return 0
}

extract_track() {   # absolute stream index, destination path
  local id="$1" dest="$2" rc=0
  if ! track_id "$id"; then
    die "mkvmerge -i positional Track ID check failed for stream index $id; the mapping is never assumed"
  fi
  mkvextract tracks "$SRC_WIN" "$TRACK_ID:$(winpath "$dest")" > "$WORK/mkvextract.log" 2>&1 || rc=$?
  if [[ $rc -ne 0 || ! -s "$dest" ]]; then
    tail -5 "$WORK/mkvextract.log" >&2
    rm -f "$dest"
    die "mkvextract failed for track $id (rc=$rc)"
  fi
  return 0
}

# "<base>.<lang>.<ext>" is the plan section 1 pattern; a second track with the
# same language cannot share one name, so it gets its disambiguator in the name.
sidecar_path() {   # lang, ext, disambiguator
  local lang="$1" ext="$2" tag="$3" p
  p="$OUT_DIR/$OUT_BASE.$lang.$ext"
  [[ -e "$p" ]] && p="$OUT_DIR/$OUT_BASE.$tag.$lang.$ext"
  printf '%s' "$p"
}

# ass-to-srt: convert.py writes "<stem>.srt" from the input stem, so a file
# named "<base>.<lang>.ass" produces exactly "<base>.<lang>.srt". The default
# "colors" variant keeps the formatting and the per-class colours.
WRITTEN=0
FAILED=0
ass_to_srt() {   # the .ass path next to the target
  local ass="$1" srt="${1%.*}.srt"
  if python3 "$ASS2SRT/convert.py" --input "$ass" --out-dir "$OUT_DIR" > "$WORK/ass2srt.log" 2>&1; then
    if [[ -s "$srt" ]]; then
      WRITTEN=$((WRITTEN + 2))
      log "ass-to-srt: $(basename "$srt") written, styled original kept as $(basename "$ass")"
    else
      FAILED=$((FAILED + 1))
      log "ass-to-srt: no .srt produced for $(basename "$ass")"
      tail -5 "$WORK/ass2srt.log" >&2
    fi
  else
    FAILED=$((FAILED + 1))
    log "ass-to-srt FAILED for $(basename "$ass"), sidecar not written"
    tail -5 "$WORK/ass2srt.log" >&2
  fi
}

# A long native-tool run prints a heartbeat every 20 s, otherwise the log looks
# frozen and a session reports a "stuck" script for a running process.
run_logged() {
  local label="$1"; shift
  local start=$SECONDS rc=0 pid
  { "$@" > "$WORK/native.log" 2>&1; } &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 20
    if kill -0 "$pid" 2>/dev/null; then
      log "$label, $((SECONDS - start))s elapsed"
    fi
  done
  wait "$pid" || rc=$?
  return $rc
}

# PGS fact, plainly as the plan writes it: printed for every PGS stream.
pgs_fact() {
  printf 'subs: PGS %s\n' "только внутри контейнера; ffmpeg не кодирует PGS; .sup export доступен для архива через mkvextract, OCR нет"
}

# Audio ladder (SKILL.md §3), returns "act|codec|ac|bitrate". Ported verbatim
# from convert.sh so the burn path follows the same ladder as the batch path:
# copying every audio stream verbatim burned a DTS track into the output, which
# the TV cannot play, and kept >6-channel eac3/truehd streams that Plex cannot
# direct-play.
#  1. copy-set at <=6 channels is direct play on the TV: ac3, eac3, aac, mp3,
#     vorbis, opus, pcm_s16le, flac. DD+ Atmos with a 5.1 base is eac3 at 6ch,
#     so rule 2 (copy) is covered by this arm (file 32 verified).
#  3. any codec with >6 channels -> E-AC-3 5.1 downmix, Atmos metadata lost.
#  4. dts/DTS-HD never plays on the TV -> always re-encode; stereo -> PCM16.
#  5. codec outside the copy-set: stereo -> PCM16, multichannel <=5.1 -> E-AC-3
#     with the same channel count.
# Bitrate caps for eac3: 5.1 -> 1024k, stereo/<=4ch -> 640k.
# Never produce truehd/dca: -c:a truehd / -c:a dca is experimental, without
# -strict -2 ffmpeg returns rc=127 and an empty file. (traps.md #4)
audio_plan() {
  local codec="$1" ch="${2:-0}"
  # The copy-set arm is unconditional: the ladder copies ac3/eac3/aac/mp3/
  # vorbis/opus/pcm_s16le/flac at <=6 channels even under --audio encode, the
  # flag states intent, the ladder decides. (SKILL.md §3 rule 1)
  COPYSET=" ac3 eac3 aac mp3 vorbis opus pcm_s16le flac "
  case "$COPYSET" in
    *" $codec "*)
      (( ch >= 1 && ch <= 6 )) && { printf 'copy|-|-'; return; }
      ;;
  esac
  [[ "$codec" == "dts" && "$ch" -le 2 ]] && { printf 'encode|pcm_s16le|2|-'; return; }
  (( ch > 6 )) && { printf 'encode|eac3|6|1024k'; return; }
  (( ch == 6 )) && { printf 'encode|eac3|6|1024k'; return; }
  (( ch <= 2 )) && { printf 'encode|pcm_s16le|2|-'; return; }
  printf 'encode|eac3|%s|640k' "$ch"
}

# -------------------------------------------------------------------------- #
# sidecar mode
# -------------------------------------------------------------------------- #

if [[ "$MODE" == "sidecar" ]]; then
  if [[ -f "$ASS2SRT/convert.py" && -f "$ASS2SRT/ass2srt.py" ]]; then
    :
  else
    die "ass-to-srt scripts not found (ASS2SRT=$ASS2SRT has no convert.py/ass2srt.py); install the ass-to-srt skill"
  fi

  for id in $SUB_IDS_AVAIL; do
    codec="$(smeta "$id" '.codec_name')"
    lang="$(smeta "$id" '.tags.language')"
    lang="$(printf '%s' "$lang" | tr 'A-Z' 'a-z')"
    [[ -n "$lang" ]] || lang="und"
    [[ -n "$codec" ]] || continue
    if ! lang_match "$lang"; then
      log "sub $id ($lang) skipped by --lang ${LANGS[*]:-all}"
      continue
    fi
    [[ "$lang" == "und" && ${#LANGS[@]} -gt 0 ]] && log "sub $id: language 'und' included (the stream has no language tag)"
    nl="$(name_lang "$lang")"

    case "$codec" in
      ass|ssa)
        p="$(sidecar_path "$nl" ass "$id")"
        extract_track "$id" "$p"
        log "sub $id ($lang): ASS/SSA extracted with mkvextract -> $(basename "$p") (styled original travels with the file)"
        ass_to_srt "$p"
        ;;
      subrip)
        p="$(sidecar_path "$nl" srt "$id")"
        extract_track "$id" "$p"
        WRITTEN=$((WRITTEN + 1))
        log "sub $id ($lang): subrip extracted straight to $(basename "$p"), no conversion"
        ;;
      hdmv_pgs_subtitle)
        pgs_fact
        if [[ $EXPORT_SUP -eq 1 ]]; then
          sup="$OUT_DIR/$OUT_BASE.$id.$lang.sup"
          # The Track ID comes out of mkvmerge -i through the same positional
          # check extract_track uses ("ID из mkvmerge -i, не предполагать"); the
          # ffprobe stream index is NOT a Track ID.
          track_id "$id" || die "mkvmerge -i positional Track ID check failed for PGS stream $id; the mapping is never assumed"
          run_logged "PGS export" mkvextract tracks "$SRC_WIN" "$TRACK_ID:$(winpath "$sup")" \
            || { tail -10 "$WORK/native.log" >&2; rm -f "$sup"; die "PGS .sup export failed for track $id"; }
          # PG magic 50 47 = "PG": the exported file must start with it.
          magic="$(head -c 2 "$sup" | od -An -tx1 | tr -d ' \n')"
          [[ "$magic" == "5047" ]] || { rm -f "$sup"; die "PGS export for track $id has no PG magic ($magic)"; }
          log "sub $id ($lang): $OUT_BASE.$id.$lang.sup written for the archive, NOT as a sidecar path (Plex does not read .sup)"
        fi
        ;;
      *)
        log "sub $id ($lang): codec '$codec' has no sidecar path, skipped"
        ;;
    esac
  done

  # External .ass packs. A pack is one directory holding .ass/.ssa files. More
  # than one pack is never picked silently: rc=2 and the pack list go to the
  # agent, who must ask the user which pack.
  PACKS=()
  scan_packs() {
    local d="$1" n=0 f sub
    n=0
    for f in "$d"/*.ass "$d"/*.ssa; do
      [[ -f "$f" ]] && n=$((n + 1))
    done
    [[ $n -gt 0 ]] && PACKS+=("$d$SEP$n")
    for sub in "$d"/*/; do
      [[ -d "${sub%/}" ]] && scan_packs "${sub%/}"
    done
    return 0
  }

  if [[ -n "$EXTERNAL" ]]; then
    if [[ -f "$EXTERNAL" ]]; then
      case "$EXTERNAL" in *.ass|*.ssa) PACKS+=("$EXTERNAL$SEP1") ;; esac
    elif [[ -d "$EXTERNAL" ]]; then
      scan_packs "$EXTERNAL"
    else
      die "--external is neither a file nor a directory: $EXTERNAL"
    fi

    if [[ ${#PACKS[@]} -gt 1 ]]; then
      printf 'subs: %s packs of .ass found in %s, the pack is not picked silently:\n' "${#PACKS[@]}" "$EXTERNAL"
      for rec in "${PACKS[@]}"; do
        IFS="$SEP" read -r pdir pcount <<< "$rec"
        printf '  pack %s  (%s .ass/.ssa files)\n' "$pdir" "$pcount"
      done
      printf 'subs: the agent must ask the user which pack, then re-run --external with that single pack\n'
      exit 2
    fi

    if [[ ${#PACKS[@]} -eq 1 ]]; then
      pack="${PACKS[0]%%$SEP*}"
      if [[ -f "$pack" ]]; then
        files="$pack"
      else
        files="$(for f in "$pack"/*.ass "$pack"/*.ssa; do [[ -f "$f" ]] && printf '%s\n' "$f"; done)"
      fi
      # Per-file disambiguator. A pack routinely has several files with the same
      # language ("A.ru.ass", "C.ru.ass"), and one shared tag made a later file
      # overwrite an earlier copy. The counter is per file, so every collision
      # gets a name that has never been used, and WRITTEN counts unique files.
      EXT_TAG=0
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        lang="$(sidecar_lang "$(basename "$f")")"
        if ! lang_match "$lang"; then
          log "external pack file $(basename "$f") skipped by --lang ${LANGS[*]:-all}"
          continue
        fi
        [[ "$lang" == "und" && ${#LANGS[@]} -gt 0 ]] && log "external pack file: language 'und' included"
        nl="$(name_lang "$lang")"
        p="$(sidecar_path "$nl" ass "ext$EXT_TAG")"
        EXT_TAG=$((EXT_TAG + 1))
        cp "$f" "$p"
        log "external pack: $(basename "$f") copied as $(basename "$p")"
        ass_to_srt "$p"
      done <<< "$files"
    fi
  fi

  if [[ $WRITTEN -eq 0 && $FAILED -eq 0 ]]; then
    log "no subtitles found for lang=${LANGS[*]:-all} in $IN (PGS is never a sidecar)"
  fi
  log "sidecars written: $WRITTEN file(s) in $OUT_DIR, failures: $FAILED"
  [[ $FAILED -eq 0 ]] || exit 1
  exit 0
fi

# -------------------------------------------------------------------------- #
# burn mode
# -------------------------------------------------------------------------- #

# Burn-in consumes the video decode, so the video is always re-encoded with the
# fixed set. Audio follows the ladder of SKILL.md §3, the same audio_plan() as
# convert.sh: copy-set <=6 channels copied, >6 channels -> E-AC-3 5.1, DTS is
# never copied (the TV cannot play it). One ffmpeg invocation, one process at a
# time (GPU rule).
[[ -n "$VID_IDX" ]] || die "no video stream in $IN"
OUT="$OUT_DIR/$OUT_BASE.mkv"
[[ -e "$OUT" ]] && die "output already exists: $OUT"
OUT_WIN="$(winpath "$OUT")"

BURN_SUB=""; BURN_LANG="und"
if [[ -n "$EXTERNAL" ]]; then
  # burn takes one external file, not a pack directory.
  [[ -f "$EXTERNAL" ]] || die "--external for burn must be one .srt/.ass/.ssa file, not a directory: $EXTERNAL"
  case "$EXTERNAL" in *.srt|*.ass|*.ssa) ;; *) die "burn cannot read '$EXTERNAL' (only .srt/.ass/.ssa)" ;; esac
  BURN_SUB="$EXTERNAL"
  BURN_LANG="$(sidecar_lang "$(basename "$EXTERNAL")")"
  lang_match "$BURN_LANG" || log "burn: external file language $BURN_LANG is outside --lang ${LANGS[*]:-all}, burned as given"
  log "burn source: external sidecar $EXTERNAL (lang $BURN_LANG)"
elif [[ -n "$SUB_IDS" ]]; then
  for id in ${SUB_IDS//,/ }; do
    codec="$(smeta "$id" '.codec_name')"
    lang="$(smeta "$id" '.tags.language')"
    lang="$(printf '%s' "$lang" | tr 'A-Z' 'a-z')"
    [[ -n "$lang" ]] || lang="und"
    [[ -n "$codec" ]] || { log "sub $id does not exist"; continue; }
    case "$codec" in
      subrip) ext=srt ;;
      ass|ssa) ext=ass ;;
      hdmv_pgs_subtitle)
        pgs_fact
        log "sub $id ($lang): PGS cannot be burned, ffmpeg has no PGS encoder and libass does not decode PGS"
        continue
        ;;
      *) log "sub $id ($lang): codec '$codec' cannot be burned, skipped"; continue ;;
    esac
    lang_match "$lang" || { log "sub $id ($lang) skipped by --lang ${LANGS[*]:-all}"; continue; }
    [[ "$lang" == "und" && ${#LANGS[@]} -gt 0 ]] && log "sub $id: language 'und' included"
    p="$WORK/$OUT_BASE.$id.$lang.$ext"
    extract_track "$id" "$p"
    BURN_SUB="$p"; BURN_LANG="$lang"
    log "burn source: embedded stream $id ($lang) extracted to scratch as $(basename "$p")"
    break
  done
else
  die "--mode burn needs --sub-ids N (embedded stream) or --external FILE"
fi

[[ -n "$BURN_SUB" ]] || die "no burnable subtitle found for lang=${LANGS[*]:-any}"

# Fonts: the subtitle's own folder first, then the system fonts. The exact
# pattern of convert.sh, so the burn implementation stays single.
BURN_WIN="$(winpath "$BURN_SUB")"
SUBDIR="$(dirname "$BURN_SUB")"
fonts=0
for f in "$SUBDIR"/*.ttf "$SUBDIR"/*.otf "$SUBDIR"/*.ttc; do
  [[ -f "$f" ]] && fonts=1
done
fontdir="$SUBDIR"
[[ $fonts -eq 1 ]] || fontdir="$WINFONTS"
fontdir_win="$(winpath "$fontdir")"

# Video: the fixed flag set of SKILL.md section 2, verbatim. No -profile:v main,
# no -f mkv; matroska and -avoid_negative_ts make_zero ('make_window' is not a
# valid constant). (references/traps.md)
VENC=(hevc_nvenc -preset p4 -rc vbr -b:v 0 -cq 10 -maxrate 200M -bufsize 100M \
      -rc-lookahead 32 -spatial-aq 1 -temporal-aq 1 -aq-strength 12)

FF=("$FFMPEG_BIN" -hide_banner -v info -y -i "$SRC_WIN")
FF+=(-map "0:$VID_IDX" -c:v "${VENC[@]}")
# Stream-index rule, mirrored from convert.sh: -c:a:N and -b:a:N address the N-th
# AUDIO stream of the output (media index = POSA), while -ac:N is the ABSOLUTE
# output-stream index in -map order (POSALL: every -map, video or audio, advances
# the counter). The burn path maps exactly one video stream, so POSALL is seeded
# with 1 when the video map closes, and both counters advance once per mapped
# audio stream. -ac:"$POSA" is the bug this rule exists to prevent: the first
# audio stream is absolute index 1, so -ac:0 targets the video stream and the
# downmix is silently lost (live test: a mono pcm_s24le source stayed 1ch, the
# verification FAILED). The copy arm advances POSALL too, its -map consumes an
# absolute index.
POSALL=1
POSA=0
EXP_A=()
for id in $AUDIO_IDS_AVAIL; do
  codec="$(smeta "$id" '.codec_name')"
  ch="$(smeta "$id" '.channels')"; ch="${ch:-0}"
  prof="$(smeta "$id" '.profile')"
  [[ -n "$codec" ]] || continue
  plan="$(audio_plan "$codec" "$ch")"
  IFS='|' read -r act pcodec pac pbr <<< "$plan"
  FF+=(-map "0:$id")
  if [[ "$act" == "copy" ]]; then
    FF+=(-c:a:"$POSA" copy)
    EXP_A+=("$codec$SEP$ch")
    extra=""
    [[ "$codec" == "eac3" ]] && printf '%s' "$prof" | grep -qi atmos && extra=" (DD+ Atmos, 5.1 base copied)"
    log "audio $id: $codec ${ch}ch -> copy${extra}"
  else
    # -ac is indexed by the ABSOLUTE output-stream index, -c:a/-b:a by the audio
    # media index (the rule above the loop).
    FF+=(-c:a:"$POSA" "$pcodec" -ac:"$POSALL" "$pac")
    [[ "$pbr" != "-" ]] && FF+=(-b:a:"$POSA" "$pbr")
    EXP_A+=("$pcodec$SEP$pac")
    log "audio $id: $codec ${ch}ch -> $pcodec ${pac}ch${pbr:+ $pbr}"
  fi
  POSA=$((POSA + 1)); POSALL=$((POSALL + 1))
done
FF+=(-vf "subtitles=$(fesc "$BURN_WIN"):fontsdir=$(fesc "$fontdir_win")")
log "burn-in: $(basename "$BURN_SUB") lang=$BURN_LANG, fonts dir: $fontdir"
FF+=(-f matroska -avoid_negative_ts make_zero "$OUT_WIN")

log "running the single ffmpeg invocation (hevc_nvenc fixed set, p4, cq 10)"
run_logged "burn encode" "${FF[@]}"
RC=$?
if [[ $RC -ne 0 ]]; then
  tail -25 "$WORK/native.log" >&2
  rm -f "$OUT"
  die "ffmpeg failed rc=$RC, partial output deleted"
fi

# Verification: streams are video + audio only, codec hevc, every audio stream
# matches the ladder plan recorded in EXP_A (copied codec/channels, or the
# encoder and -ac the ladder asked for), duration within 1 s of the source. On
# failure the partial output is deleted.
OUT_JSON="$("$FFPROBE_BIN" -v error -show_streams -of json "$OUT_WIN" 2>/dev/null)"
OUT_FORMAT="$("$FFPROBE_BIN" -v error -show_format -of json "$OUT_WIN" 2>/dev/null)"
[[ -n "$OUT_JSON" ]] || { rm -f "$OUT"; die "output cannot be probed, deleted"; }
FAIL=""

SUBOUT="$(jqf "$OUT_JSON" '[.streams[] | select(.codec_type=="subtitle")] | length')"
[[ "$SUBOUT" == "0" ]] || FAIL="$FAIL subtitle streams $SUBOUT, expected 0 (burn-in leaves no subtitle stream)"
OTHER="$(jqf "$OUT_JSON" '[.streams[] | select(.codec_type!="video" and .codec_type!="audio")] | length')"
[[ "$OTHER" == "0" ]] || FAIL="$FAIL non video/audio streams $OTHER, expected 0"

V0="$(jqf "$OUT_JSON" '[.streams[] | select(.codec_type=="video")] | .[0].codec_name // empty')"
[[ "$V0" == "hevc" ]] || FAIL="$FAIL video codec '$V0', expected hevc"

ASEL='[.streams[] | select(.codec_type=="audio")]'
i=0
for rec in "${EXP_A[@]}"; do
  IFS="$SEP" read -r wantcodec wantch <<< "$rec"
  got="$(jqf "$OUT_JSON" "$ASEL | .[$i].codec_name // empty")"
  gotch="$(jqf "$OUT_JSON" "$ASEL | .[$i].channels // empty")"
  if [[ "$got" != "$wantcodec" ]]; then
    FAIL="$FAIL audio stream $i codec '$got' expected '$wantcodec'"
  fi
  # In jq the number 0 is truthy: compare explicitly, never by truthiness.
  if [[ -n "$wantch" && "$wantch" != "0" && "$gotch" != "$wantch" ]]; then
    FAIL="$FAIL audio stream $i channels '$gotch' expected '$wantch'"
  fi
  i=$((i + 1))
done

D1="$(jqf "$FORMAT_JSON" '.format.duration // empty')"
D2="$(jqf "$OUT_FORMAT" '.format.duration // empty')"
if [[ -n "$D1" && -n "$D2" ]] && ! awk -v a="$D1" -v b="$D2" 'BEGIN { d=a-b; if (d<0) d=-d; exit (d>1) }'; then
  FAIL="$FAIL duration ${D2}s vs source ${D1}s (>1 s)"
fi

if [[ -n "$FAIL" ]]; then
  rm -f "$OUT"
  printf 'subs: VERIFY FAILED:%s\n' "$FAIL" >&2
  printf 'subs: partial output deleted\n' >&2
  exit 1
fi

SPEED="$(grep -o 'speed=[0-9.]*x' "$WORK/native.log" | tail -1)"
SIZE="$(stat -c%s "$OUT" 2>/dev/null || printf '0')"
log "verified: video hevc, audio ${#EXP_A[@]} stream(s) by the ladder, subtitle streams 0, duration ${D2:-?}s (source ${D1:-?}s)"
printf 'subs: DONE burned %s, %s bytes, %s\n' "$OUT" "$SIZE" "${SPEED:-encode time not reported}"
exit 0
