#!/usr/bin/env bash
# dv.sh - Dolby Vision mode of the video-convert skill: MKV -> Dolby Vision MP4.
# Ported verbatim in behaviour from dv2mp4.sh of the retired dv-mkv-to-mp4 skill;
# the old dv2mp4 audio table is replaced with the plan section 3 ladder.
# Requires: ffmpeg, ffprobe, jq, MP4Box (GPAC >= 2), dovi_tool, mkvextract, mkvmerge.
# Every intermediate file lives in a temp dir under $DV_TMP (default ~/tmp)
# and is removed on exit, including on failure.
set -uo pipefail

# The NVENC ffmpeg build for this machine. FFMPEG_BIN is the default path below
# and FFPROBE_BIN defaults to the ffprobe.exe sitting in the same directory as
# FFMPEG_BIN; both defaults are honoured as environment overrides.
FFMPEG_BIN="${FFMPEG_BIN:-/cygdrive/c/Program Files/ffmpeg/bin/ffmpeg.exe}"

# ---------------------------------------------------------------- helpers ----

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'dv: %s\n' "$*"; }

# Native Windows executables need Windows paths. cygpath -m yields "D:/x/y".
winpath() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

# Strip control chars and the quote characters that would break MP4Box -name.
sanitize_name() {
  printf '%s' "${1-}" | tr -d '\000-\037' | sed 's/["'"'"'`,]//g' \
    | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//'
}

need_tool() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# Run a long command while printing a heartbeat. Extracting the video of a 22 GB
# source takes minutes and, without this, the log looks frozen and people
# assume the script is stuck.
run_with_heartbeat() {
  local label="$1"; shift
  local start
  start=$SECONDS
  local rc=0
  "$@" &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 20
    if kill -0 "$pid" 2>/dev/null; then
      note "$label, $((SECONDS - start))s elapsed"
    fi
  done
  wait "$pid" || rc=$?
  return $rc
}

# ---- stream metadata -------------------------------------------------------
# Track ids used below are ABSOLUTE stream indexes, which is what
# "ffmpeg -map 0:ID" expects. "ffprobe -select_streams a:ID" must not be used
# for lookups: that selector is relative to the stream type and silently returns
# a different track whenever the indexes diverge. Metadata is read once into
# STREAM_JSON and looked up by absolute index instead.
#
# jq on Windows is a native binary that emits CRLF, so jqf strips "\r".
STREAM_JSON=""

jqf() { printf '%s' "$1" | jq -r "$2" 2>/dev/null | tr -d '\r'; }

# dovi_tool prints "Parsing RPU file..." on stdout before the JSON, so the output
# has to be cut at the first brace before jq can read it.
dovi_json() { dovi_tool info -i "$1" -f 0 2>/dev/null | tr -d '\r' | sed -n '/^{/,$p'; }

# Records are joined with US (0x1f) instead of "|". Track titles legitimately
# contain "|", as in "Dublazh | Some Studio", which silently shifted every
# field of the pipe separated form. sanitize_name already strips \000-\037, so
# 0x1f can never survive inside a title.
SEP=$'\x1f'

# smeta <absolute-index> <jq-expression-of-a-stream>
smeta() {
  local idx="$1" expr="$2" out=""
  [[ -n "$STREAM_JSON" ]] || { printf ''; return 0; }
  out="$(jqf "$STREAM_JSON" ".streams[] | select(.index==$idx) | ($expr) // empty")"
  out="$(printf '%s' "$out" | tr -d '\r' \
    | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//')"
  printf '%s' "$out"
}

valid_lang() {
  local l
  l="$(printf '%s' "${1-}" | tr -d '\r[:space:]')"
  [[ "$l" =~ ^[a-z]{2,3}$ ]] && printf '%s' "$l" || printf 'und'
}

# Base layer transfer characteristics of the first HEVC video stream. This
# decides the Dolby Vision compatibility ID, so a wrong or missing value here
# silently produces the wrong MP4 signalling.
video_xfer() {
  jqf "$STREAM_JSON" '[ .streams[]
    | select(.codec_type=="video" and .codec_name=="hevc") ]
    | .[0].color_transfer // empty'
}

valid_int() {
  local n
  n="$(printf '%s' "${1-}" | tr -d '\r[:space:]')"
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf ''
}

# ------------------------------------------------------------- arguments ----

INPUT=""; OUTPUT=""; AUDIO_IDS=""; SUB_IDS=""; LANGS="all"
KEEP_TMP=0; ASM=0; PROBE=0; LIST=0; REMOVE_SRC=0; DVP_OVERRIDE=""; MOVIE_TITLE=""; TMP_PARENT=""
OUTPUT_SEEN=0   # set when -o was passed, so "-o ''" can be told from "no -o"

usage() {
  cat <<'USAGE'
Usage: dv.sh -i INPUT.mkv [-o OUTPUT.mp4] [options]

Required:
  -i, --input FILE      source MKV with Dolby Vision

Output:
  -o, --output FILE     output MP4. Optional: by default a source with Dolby
                        Vision becomes <base>.DV-MP4.mp4 and a source without
                        becomes <base>.mp4, next to the source file

Track selection (ids are absolute stream indexes):
  -a, --audio IDS       comma separated audio ids to keep (default: all)
  -s, --subs IDS        comma separated subtitle ids to export as sidecars
                        (default: none). subrip -> .srt, hdmv_pgs -> .sup
                        (via mkvextract), ASS/SSA tracks are always exported,
                        as .ass plus a derived .srt, with or without -s.
  -l, --langs LIST      comma separated language filter, e.g. rus,eng

Behaviour:
       --probe          only report whether the file has Dolby Vision and which
                        profile, then exit. Reads just the head of the video
                        stream, so it is fast even on a huge source
       --list           print the audio and subtitle tracks as a markdown table
                        for the user to pick ids from, then exit
       --asm            also write "<out>.asm.mkv" with audio+subs, no video
       --remove-source  delete the source MKV after a successful conversion.
                        Use only after explicit confirmation from the user: the
                        source is read-only by skill rule
       --keep           keep the temp working directory (debugging)
       --title TEXT     title written into the MP4
       --dvp VALUE      force the GPAC dvp= value, e.g. 8.1.hdr10
       --tmp DIR        parent dir for the temp working dir (default: $DV_TMP,
                        which defaults to ~/tmp)
  -h, --help           this help

Audio handling, chosen for TV playback (video-convert ladder):
  copy-set at <=6 channels: ac3, eac3, aac, mp3, vorbis, opus, pcm_s16le, flac
    -> stream copy. DD+ Atmos (E-AC-3 JOC) with a 5.1 base is in this set and
    is copied.
  any codec with more than 6 channels (truehd, dts, eac3 8ch, aac, flac, pcm,
    vorbis, opus...) -> downmix to E-AC-3 5.1 at 1024 kbit/s. Atmos metadata is
    lost, the script logs that.
  dts / DTS-HD are never copied: stereo -> PCM16, multichannel -> E-AC-3 5.1.
  codec outside the copy-set: stereo -> PCM16, up to 5.1 -> E-AC-3 with the
    same channel count.
  The old dv2mp4 AC-3 rule is retired: the ladder never targets AC-3 for
  encoding, so the 640 kbit/s AC-3 cap machinery is not used here (references/
  dv-pitfalls.md item 14 keeps the verified cap facts).

Subtitles are never muxed into the MP4, they are always sidecar files next to
it. ASS/SSA tracks are exported automatically as both .ass and .srt because the
styled original cannot be represented in SRT. PGS is exported with mkvextract;
ffmpeg cannot write .sup. No OCR.

Notes:
  * Dolby Vision is detected with dovi_tool. mediainfo is not trusted for this:
    it stops reporting "Dolby Vision" on remuxed MKVs even when the RPU is fine.
  * A source with no Dolby Vision RPU is still converted: the video stream is
    copied unchanged into the MP4, no DV signalling is written, and the summary
    states that the file has no Dolby Vision. HEVC and h264 sources are handled;
    anything else belongs to convert.sh.
  * Verification on the result: DolbyVision box present for a DV source and
    absent for a non-DV source, decoded pictures compared with ffmpeg -f
    framemd5 on sampled windows, the RPU extracted back out of the MP4 compared
    byte for byte for DV, and the output duration within 1 s of the source.
  * Dolby Vision profile 8 is the only profile verified on real hardware here.
    Profiles 4, 5 and 7 are ported from dvmkv2mp4 and remain unverified.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)      INPUT="${2:-}";  shift 2 ;;
    -o|--output)     OUTPUT="${2:-}"; OUTPUT_SEEN=1; shift 2 ;;
    -a|--audio)      AUDIO_IDS="${2:-}"; shift 2 ;;
    -s|--subs)       SUB_IDS="${2:-}";  shift 2 ;;
    -l|--langs)      LANGS="${2:-all}"; shift 2 ;;
    --asm)           ASM=1; shift ;;
    --probe)         PROBE=1; shift ;;
    --list)          LIST=1; shift ;;
    --remove-source) REMOVE_SRC=1; shift ;;
    --keep)          KEEP_TMP=1; shift ;;
    --title)         MOVIE_TITLE="${2:-}"; shift 2 ;;
    --dvp)           DVP_OVERRIDE="${2:-}"; shift 2 ;;
    --tmp)           TMP_PARENT="${2:-}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "$INPUT" ]] || { usage >&2; die "-i is required"; }
[[ -f "$INPUT" ]] || die "input not found: $INPUT"
# "-o ''" is an explicit empty path, not the default naming; reject it up front
# so no conversion work runs against "".
[[ $OUTPUT_SEEN -eq 0 || -n "$OUTPUT" ]] || die "-o given as an empty path; pass a real output file"

command -v cygpath >/dev/null 2>&1 || die "cygpath is required to pass Windows paths to native tools"
need_tool jq

if [[ -x "$FFMPEG_BIN" ]]; then
  FF="$FFMPEG_BIN"
  # FFPROBE_BIN is honoured as an environment override; its default is the
  # ffprobe.exe sitting in the same directory as FFMPEG_BIN.
  FP="${FFPROBE_BIN:-$(dirname "$FFMPEG_BIN")/ffprobe.exe}"
  [[ -x "$FP" ]] || FP="ffprobe"
elif command -v ffmpeg >/dev/null 2>&1; then
  FF="ffmpeg"; FP="${FFPROBE_BIN:-ffprobe}"
  note "FFMPEG_BIN not found, using ffmpeg/ffprobe from PATH"
else
  die "ffmpeg not found: set FFMPEG_BIN (the default '$FFMPEG_BIN' does not exist)"
fi
[[ -x "$FP" ]] || command -v ffprobe >/dev/null 2>&1 || die "ffprobe not found (set FFMPEG_BIN next to it)"

SRC_WIN="$(winpath "$INPUT")"

# --------------------------------------------------------------- probing ----

STREAM_JSON="$("$FP" -v error -show_streams -of json "$SRC_WIN" 2>/dev/null)"
[[ -n "$STREAM_JSON" ]] || die "ffprobe could not read $INPUT"

VCOUNT="$(jqf "$STREAM_JSON" '[ .streams[]
  | select(.codec_type=="video" and .codec_name=="hevc") ] | length')"
V_FIRST_CODEC="$(jqf "$STREAM_JSON" '[ .streams[] | select(.codec_type=="video") ]
  | .[0].codec_name // empty')"
[[ -n "$V_FIRST_CODEC" ]] || die "no video stream in $INPUT"

# HEVC is the Dolby Vision path; an h264 source is the passthrough case the plan
# section 3 copy-set also allows. Anything else is convert.sh territory.
#
# A source can mix h264 and HEVC tracks (preview + main), so the extraction and
# the frame verification map the ABSOLUTE index of the resolved codec's stream,
# never a hardcoded "0:v:0": with several video streams "0:v:0" is whatever
# happens to sit first, which can be the wrong codec.
HEVC_IDX="$(jqf "$STREAM_JSON" '[ .streams[]
  | select(.codec_type=="video" and .codec_name=="hevc") ] | .[0].index // empty')"
HEVC_IDX2="$(jqf "$STREAM_JSON" '[ .streams[]
  | select(.codec_type=="video" and .codec_name=="hevc") ] | .[1].index // empty')"
H264_IDX="$(jqf "$STREAM_JSON" '[ .streams[]
  | select(.codec_type=="video" and .codec_name=="h264") ] | .[0].index // empty')"

if [[ "$VCOUNT" -ge 1 ]]; then
  V_MODE="hevc"; V_IDX="$HEVC_IDX"
  [[ -n "$V_IDX" ]] || die "hevc video index resolution failed"
elif [[ "$V_FIRST_CODEC" == "h264" ]]; then
  V_MODE="h264"; V_IDX="$H264_IDX"
  [[ -n "$V_IDX" ]] || die "h264 video index resolution failed"
else
  die "dv.sh handles HEVC (Dolby Vision) and h264 sources; '$V_FIRST_CODEC' belongs to convert.sh"
fi

AUDIO_IDS_AVAIL="$(jqf "$STREAM_JSON" '.streams[]
  | select(.codec_type=="audio") | .index' | tr '\n' ' ')"
SUB_IDS_AVAIL="$(jqf "$STREAM_JSON" '.streams[]
  | select(.codec_type=="subtitle") | .index' | tr '\n' ' ')"

if [[ -n "$AUDIO_IDS" ]]; then WANT_AUDIO=" ${AUDIO_IDS//,/ } "; else WANT_AUDIO=" $AUDIO_IDS_AVAIL "; fi
if [[ -n "$SUB_IDS" ]]; then WANT_SUBS=" ${SUB_IDS//,/ } "; else WANT_SUBS=""; fi

# ---------------------------------------------------------------- --list ----
# This is list-tracks.sh folded in as an option, one script for the skill.
# Two traps it inherits from the original, both hit during development:
#   1. "-show_entries" together with "-show_streams" makes this ffprobe build
#      (4.4) silently drop tags such as language, so plain -show_streams is used.
#   2. jq on Windows is a native binary and emits CRLF. Every value read from it
#      is stripped of "\r" by jqf(), otherwise "rus\r" fails every regex and the
#      language silently degrades to "und".

if [[ $LIST -eq 1 ]]; then
  escape() { printf '%s' "${1-}" | sed 's/|/\\|/g'; }

  clean_title() {
    printf '%s' "${1-}" | tr -d '\000-\037' \
      | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//'
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
      hdmv_pgs_subtitle) printf '.sup (PGS, no OCR, via mkvextract)' ;;
      *)                 printf 'unsupported' ;;
    esac
  }

  printf 'Source: `%s`\n\n' "$INPUT"

  # --------------------------------------------------------- video line ----

  VID_LINE="$(jqf "$STREAM_JSON" '[ .streams[] | select(.codec_type=="video") ][0]
    | if . == null then empty else "\(.codec_name // "?") \(.width // "?")x\(.height // "?")" end')"
  [[ -n "$VID_LINE" ]] && printf 'Video: %s\n\n' "$VID_LINE"

  # ----------------------------------------------------------- audio ----

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
  done < <(jqf "$STREAM_JSON" '.streams[] | select(.codec_type=="audio") | @json')

  # --------------------------------------------------------- subtitles ----

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
  done < <(jqf "$STREAM_JSON" '.streams[] | select(.codec_type=="subtitle") | @json')

  printf '\nIds are absolute stream indexes, pass them straight through:\n\n'
  printf '```bash\nbash scripts/dv.sh -i "%s" -a <audio-ids> -s <subtitle-ids>\n```\n' "$INPUT"
  exit 0
fi

# --------------------------------------------------------- temp workspace ----
# $DV_TMP is a cygwin path, but ffmpeg, MP4Box and dovi_tool are native Windows
# binaries and cannot write to "/cygdrive/<drive>/tmp/...". Every native tool is
# therefore given WORK_WIN, while bash itself keeps using WORK.

TMP_PARENT="${TMP_PARENT:-${DV_TMP:-$HOME/tmp}}"
mkdir -p "$TMP_PARENT" 2>/dev/null || die "cannot create temp parent: $TMP_PARENT"
WORK="$(mktemp -d "$TMP_PARENT/dv.XXXXXXXX")" || die "cannot create work dir"
WORK_WIN="$(winpath "$WORK")"
mkdir -p "$WORK_WIN" 2>/dev/null

# The EXIT trap removes the temp dir on every exit, including a die(). It is an
# inline trap string, not a function, so shellcheck sees the cleanup directly.
trap 'if [[ $KEEP_TMP -eq 1 ]]; then note "temp kept at $WORK"; else rm -rf "$WORK"; fi' EXIT

note "source   $INPUT"
note "workdir  $WORK"

# ------------------------------------------------------------ output name ----

if [[ -z "$OUTPUT" ]]; then
  base="$(basename "$INPUT")"; base="${base%.*}"
  # Drop the HDR/DV markers together with their surrounding separators, so
  # "...Hybrid.DV.HDR10+ SomeGroup" becomes "...Hybrid.SomeGroup" rather than
  # gluing the neighbouring words together.
  #
  # The marker must sit on a separator boundary, otherwise "DVDRip" would become
  # "DRip". Two markers can be adjacent ("...Hybrid.DV.HDR10+ ..."), so the
  # substitution is applied twice, once per marker.
  base="$(printf '%s' "$base" \
    | sed -E 's/([. _-]|^)(HDR10\+?|HDR|DV|Dolby[ .]?Vision)([. _-]|$)/./gI' \
    | sed -E 's/([. _-]|^)(HDR10\+?|HDR|DV|Dolby[ .]?Vision)([. _-]|$)/./gI' \
    | sed -E 's/\.{2,}/./g; s/[[:space:]]+//g; s/[ ._-]+$//; s/^[ ._-]+//')"
  [[ -n "$base" ]] || base="video"
  OUTPUT_EXPLICIT=0
else
  OUTPUT_EXPLICIT=1
fi
OUTPUT_DIR="$(dirname "$INPUT")"

if [[ $PROBE -eq 1 ]]; then
  need_tool dovi_tool
else
  need_tool MP4Box; need_tool dovi_tool; need_tool mkvextract; need_tool mkvmerge
fi

# -------------------------------------------------- extract video + RPU ------
# Single layer (profiles 4/5/8): the video track already carries BL+RPU.
# Dual layer (profile 7): video track 0 is BL, track 1 carries the RPU.
#
# In probe mode only the head of the stream is needed: the RPU is present on
# every frame, so a short sample is enough to detect Dolby Vision. That keeps
# the probe fast even on a 22 GB source.

PROBE_SECONDS=120
EXTRACT_ARGS=()
PROBE_HINT=""
if [[ $PROBE -eq 1 ]]; then
  EXTRACT_ARGS=(-t "$PROBE_SECONDS")
  PROBE_HINT=" (first ${PROBE_SECONDS}s only)"
fi

SRC_BYTES=$(stat -c%s "$INPUT" 2>/dev/null || printf '0')
SRC_HUMAN="$(awk -v b="$SRC_BYTES" 'BEGIN { if (b > 1073741824) printf "%.1f GB", b/1073741824; else printf "%.0f MB", b/1048576 }')"
note "reading the video stream${PROBE_HINT} (source $SRC_HUMAN)"

RAW_WIN=""
if [[ "$VCOUNT" -ge 2 ]]; then
  note "dual layer video detected, using the profile 7 path"
  run_with_heartbeat "extracting the base layer" \
    "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$HEVC_IDX" -c:v copy \
    -bsf:v hevc_mp4toannexb "${EXTRACT_ARGS[@]}" -f hevc "$WORK_WIN/BL.hevc" \
    || die "BL extraction failed"
  run_with_heartbeat "extracting the enhancement layer" \
    "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$HEVC_IDX2" -c:v copy \
    -bsf:v hevc_mp4toannexb "${EXTRACT_ARGS[@]}" -f hevc "$WORK_WIN/EL.hevc" \
    || die "EL extraction failed"
  dovi_tool extract-rpu -i "$WORK_WIN/EL.hevc" -o "$WORK_WIN/RPU_EL.bin" >/dev/null 2>&1 \
    || die "no RPU in the enhancement layer; not a profile 7 source after all"
  dovi_tool inject-rpu -i "$WORK_WIN/BL.hevc" --rpu-in "$WORK_WIN/RPU_EL.bin" \
    -o "$WORK_WIN/BL_RPU.hevc" >/dev/null 2>&1 || die "inject-rpu failed"
  RAW_WIN="$WORK_WIN/BL_RPU.hevc"
elif [[ "$V_MODE" == "hevc" ]]; then
  run_with_heartbeat "extracting the video stream" \
    "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$V_IDX" -c:v copy \
    -bsf:v hevc_mp4toannexb "${EXTRACT_ARGS[@]}" -f hevc "$WORK_WIN/BL_RPU.hevc" \
    || die "video extraction failed"
  RAW_WIN="$WORK_WIN/BL_RPU.hevc"
else
  run_with_heartbeat "extracting the video stream" \
    "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$V_IDX" -c:v copy \
    -bsf:v h264_mp4toannexb "${EXTRACT_ARGS[@]}" -f h264 "$WORK_WIN/video.h264" \
    || die "video extraction failed"
  RAW_WIN="$WORK_WIN/video.h264"
fi

# ----------------------------------------------- detect DV via dovi_tool -----
# A source without a Dolby Vision RPU is not an error: the user asked for the
# video stream to be copied unchanged and to be told there is no DV layer. In
# that case the elementary stream is muxed as-is and the dvp= option is omitted
# entirely, so nothing Dolby specific is written into the container.

HAS_DV=0
DVP=""

dovi_tool extract-rpu -i "$RAW_WIN" -o "$WORK_WIN/RPU.bin" >/dev/null 2>&1
RPU_BYTES=$(stat -c%s "$WORK/RPU.bin" 2>/dev/null || printf '0')

if [[ "$RPU_BYTES" -gt 0 ]]; then
  HAS_DV=1
  DOVI_JSON="$(dovi_json "$WORK_WIN/RPU.bin")"
  DV_PROFILE="$(jqf "$DOVI_JSON" '.dovi_profile // empty')"
  [[ -n "$DV_PROFILE" ]] || die "cannot read the DV profile out of the RPU"
  # vdr_rpu_profile 1 means the 8.1 variant, the cross compatible one.
  VDR_PROFILE="$(jqf "$DOVI_JSON" '.header.vdr_rpu_profile // empty')"
  note "Dolby Vision profile $DV_PROFILE, RPU $RPU_BYTES bytes"
else
  note "*** NO DOLBY VISION LAYER FOUND IN THIS FILE ***"
  note "*** the video stream will be copied unchanged into the MP4 ***"
fi

# ------------------------------------------------------------------ probe ----
# Answer "does this file have Dolby Vision" without converting anything. The
# agent needs this whenever the user questions the DV detection, and it is the
# only sanctioned way to do it: dovi_tool info expects an RPU file, not the
# container and not a raw HEVC stream, so calling dovi_tool by hand on the MKV
# produces a misleading "invalid RPU" error.

if [[ $PROBE -eq 1 ]]; then
  V_SIZE="$(jqf "$STREAM_JSON" '[ .streams[] | select(.codec_type=="video") ][0]
    | "\(.width // "?")x\(.height // "?")"' | head -1)"
  XFER_PROBE="$(video_xfer)"
  printf '\n'
  printf 'PROBE RESULT for %s\n' "$INPUT"
  printf '  video            %s %s\n' "$V_MODE" "${V_SIZE:-unknown}"
  if [[ "$HAS_DV" -eq 1 ]]; then
    printf '  Dolby Vision     YES\n'
    printf '  dvhe profile     %s\n' "$DV_PROFILE"
    printf '  vdr_rpu_profile  %s (%s)\n' "${VDR_PROFILE:-?}" \
      "$([[ "${VDR_PROFILE:-0}" == "1" ]] && echo '8.1, cross compatible' || echo '8.0 or single layer')"
    printf '  RPU size         %s bytes\n' "$RPU_BYTES"
    printf '  base layer       %s\n' "${XFER_PROBE:-unknown}"
    printf '  -> a full conversion WILL produce a Dolby Vision MP4\n'
  else
    printf '  Dolby Vision     NO\n'
    printf '  -> no RPU in the video stream, the video would be copied unchanged\n'
  fi
  printf '\n'
  exit 0
fi

# ------------------------------------------ resolve the GPAC dvp= value ------
# GPAC >= 2 renamed "dv-profile" to "dvp" and requires a compatibility ID for the
# cross-compatible profiles, e.g. :dvp=8.1.hdr10. Pick it from the base layer.
# Skipped when there is no DV layer: there is nothing to signal, so an unknown
# transfer function must not turn into a bogus compatibility ID.

if [[ "$HAS_DV" -eq 1 ]]; then
  XFER="$(video_xfer)"
  case "$XFER" in
    smpte2084)    COMPAT="hdr10" ;;   # PQ base layer
    arib-std-b67) COMPAT="hlg2100" ;; # HLG base layer
    bt709|smpte170m|bt470bg)
                  COMPAT="bt709" ;;    # SDR base layer
    "")
      # Never guess: an empty transfer function used to yield bt709 and produced
      # a file that looked valid but carried the wrong DV compatibility ID.
      die "could not read color_transfer from the video stream; pass --dvp to set the GPAC value manually"
      ;;
    *) die "unrecognised base layer transfer '$XFER'; pass --dvp to set the GPAC value manually" ;;
  esac

  if [[ -n "$DVP_OVERRIDE" ]]; then
    DVP="$DVP_OVERRIDE"
  else
    case "$DV_PROFILE" in
      4) DVP="4.$COMPAT" ;;
      5) DVP="5" ;;                    # dvhe.05 has no BL compatibility ID
      7) DVP="7.$COMPAT" ;;
      8) DVP="8.1.$COMPAT" ;;
      9) DVP="9.$COMPAT" ;;
      *) die "unsupported Dolby Vision profile $DV_PROFILE (expected 4, 5, 7, 8 or 9)" ;;
    esac
  fi
  note "GPAC dvp=$DVP, base layer transfer ${XFER:-unknown}"
fi

# The output name is only settled here, now that the presence of Dolby Vision
# is known: a passthrough gets a plain ".mp4" name, a real conversion keeps the
# ".DV-MP4" marker so it stays obvious in a media library.

if [[ "$OUTPUT_EXPLICIT" -eq 0 ]]; then
  if [[ "$HAS_DV" -eq 1 ]]; then OUTPUT="$OUTPUT_DIR/$base.DV-MP4.mp4"
  else                            OUTPUT="$OUTPUT_DIR/$base.mp4"
  fi
fi
# An explicit "-o ''" is not the default naming: it is an empty path and would
# run the whole conversion against "". Reject it before any work is done.
[[ -n "$OUTPUT" ]] || die "-o given as an empty path; pass a real output file"
[[ -e "$OUTPUT" ]] && die "output already exists: $OUTPUT"
OUT_WIN="$(winpath "$OUTPUT")"
OUT_BASE="$(basename "$OUTPUT" .mp4)"
# Sidecars belong next to the MP4, not next to the MKV. OUTPUT_DIR is the folder
# of the *input*, so with an explicit -o it would drop the .srt/.sup/.asm files
# into the source folder, where they are invisible to anyone browsing the
# library. Every sidecar path below uses OUT_DIR.
OUT_DIR="$(dirname "$OUTPUT")"
note "output   $OUTPUT"

# --------------------------------------------------------------- chapters ----

CHAPTERS_OPT=()
if mkvextract chapters -s "$SRC_WIN" > "$WORK/chapters.list" 2>/dev/null && [[ -s "$WORK/chapters.list" ]]; then
  # Count only the CHAPTERxx= time lines. "grep -c 'CHAPTER'" also counted the
  # CHAPTERxxNAME= lines, reporting twice as many chapters as MP4Box writes.
  CHAPTERS_OPT=(-chap "$WORK_WIN/chapters.list")
  note "chapters: $(grep -c '^CHAPTER[0-9]\{2\}=' "$WORK/chapters.list")"
fi

# ------------------------------------------------------------------ audio ----
# The plan section 3 ladder, replacing the old dv2mp4 AC-3 table. Because the
# ladder never encodes to AC-3, the dv2mp4 640 kbit/s cap machinery is retired;
# the verified E-AC-3 target stays at 1024 kbit/s.
#
# Every branch writes a raw intermediate file in the temp dir and records the
# extension of the file that was WRITTEN, never the source codec (pitfalls item
# 13: MP4Box must be pointed at a name that exists).

# Track ids for PGS export, filled lazily from `mkvmerge -i`.
TRACK_IDS=()

AUDIO_EXPORTS=()
for id in $AUDIO_IDS_AVAIL; do
  [[ "$WANT_AUDIO" == *" $id "* ]] || continue

  codec="$(smeta "$id" '.codec_name')"
  lang="$(valid_lang "$(smeta "$id" '.tags.language')")"
  title="$(sanitize_name "$(smeta "$id" '.tags.title')")"
  start="$(valid_int "$(smeta "$id" '.start_pts')")"; start="${start:-0}"
  channels="$(valid_int "$(smeta "$id" '.channels')")"
  [[ -n "$codec" ]] || continue

  if [[ "$LANGS" != "all" && ",$LANGS," != *",$lang,"* ]]; then
    note "audio $id ($lang) skipped by --langs"
    continue
  fi

  # An unknown channel count is treated as stereo, never as a copy-set track
  # wider than 6.
  CH="${channels:-2}"
  out_ext=""

  if [[ "$CH" -gt 6 ]]; then
    # Ladder rule 3 is universal and checked first, for every codec, the
    # copy-set ones included: more than 6 channels -> E-AC-3 5.1. Atmos
    # metadata is lost, that is logged.
    "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:a eac3 \
      -ac 6 -b:a 1024k -f eac3 "$WORK_WIN/$id.$lang.eac3" \
      || die "audio transcode failed for track $id"
    out_ext="eac3"
    note "audio $id ($codec, ${CH}ch): more than 6 channels -> E-AC-3 5.1 1024k; Atmos/immersive metadata is lost in the downmix"
  elif [[ "$codec" == "dts" ]]; then
    # Ladder rule 4: DTS/DTS-HD is not supported by the TV at all, so it is
    # never copied. Stereo -> PCM16, multichannel -> rule 3 (E-AC-3 5.1).
    if [[ "$CH" -le 2 ]]; then
      # PCM writes into MP4 fine (ffmpeg rc=0, plan section 8); the TV
      # support, not the container, is the reason for this branch.
      "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:a pcm_s16le \
        -ac 2 -f wav "$WORK_WIN/$id.$lang.wav" \
        || die "audio transcode failed for track $id"
      out_ext="wav"
      note "audio $id (DTS stereo) -> PCM16: DTS is never copied"
    else
      "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:a eac3 \
        -ac 6 -b:a 1024k -f eac3 "$WORK_WIN/$id.$lang.eac3" \
        || die "audio transcode failed for track $id"
      out_ext="eac3"
      note "audio $id (DTS/DTS-HD ${CH}ch) -> E-AC-3 5.1 1024k: DTS is never copied, downmixed"
    fi
  elif [[ "$codec" == "ac3" || "$codec" == "eac3" || "$codec" == "aac" || "$codec" == "mp3" || "$codec" == "vorbis" || "$codec" == "opus" || "$codec" == "pcm_s16le" || "$codec" == "flac" ]]; then
    # Copy-set at <=6 channels, DD+ Atmos (E-AC-3 JOC) with a 5.1 base
    # included: copy untouched.
    fmt="$codec"
    case "$codec" in
      aac)          fmt="adts" ;;
      vorbis|opus)  fmt="ogg" ;;
      # Raw pcm_s16le has no usable "-f pcm_s16le" muxer (the raw s16le muxer
      # is headerless and MP4Box cannot import it); the WAV container carries
      # the identical pcm_s16le payload, so extraction goes through wav.
      pcm_s16le)    fmt="wav" ;;
    esac
    ext="$codec"
    [[ "$codec" == "vorbis" || "$codec" == "opus" ]] && ext="ogg"
    [[ "$codec" == "pcm_s16le" ]] && ext="wav"
    "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:a copy \
      -f "$fmt" "$WORK_WIN/$id.$lang.$ext" \
      || die "audio extraction failed for track $id"
    out_ext="$ext"
    note "audio $id ($codec, ${CH}ch) copied"
  else
    # Ladder rule 5: codec outside the copy-set. Stereo -> PCM16, multichannel
    # up to 5.1 -> E-AC-3 with the same channel count.
    if [[ "$CH" -le 2 ]]; then
      "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:a pcm_s16le \
        -ac 2 -f wav "$WORK_WIN/$id.$lang.wav" \
        || die "audio transcode failed for track $id"
      out_ext="wav"
      note "audio $id ($codec, stereo) -> PCM16"
    else
      "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:a eac3 \
        -b:a 1024k -f eac3 "$WORK_WIN/$id.$lang.eac3" \
        || die "audio transcode failed for track $id"
      out_ext="eac3"
      note "audio $id ($codec, ${CH}ch) -> E-AC-3, same channel count, 1024k"
    fi
  fi
  AUDIO_EXPORTS+=("$id$SEP$lang$SEP$title$SEP$start$SEP$out_ext")
done
[[ ${#AUDIO_EXPORTS[@]} -gt 0 ]] || die "no audio tracks selected; nothing to mux"

# The sidecar export runs AFTER the MP4 mux and verification, below: a die() on
# mux or verification failure must leave no .srt/.ass/.sup files next to an
# output that does not exist. Sidecars are written only once the MP4 is verified.

# ------------------------------------------------------------- build MP4 -----
# ":name=" is deliberate: without it MP4Box copies the whole import string into
# the track handler name and media servers show "hevc:dvp=8.1.hdr10@GPAC..." as
# the title. When there is no Dolby Vision the dvp= option is left out so the
# track is imported as plain HEVC (or plain h264 for a passthrough).

if [[ "$HAS_DV" -eq 1 ]]; then
  VIDEO_ADD="$RAW_WIN:dvp=$DVP:name="
else
  VIDEO_ADD="$RAW_WIN:name="
fi

MUX=(MP4Box -add "$VIDEO_ADD")
TCOUNT=2
for rec in "${AUDIO_EXPORTS[@]}"; do
  IFS="$SEP" read -r id lang title start ext <<< "$rec"
  MUX+=(-add "$WORK_WIN/$id.$lang.$ext:sopt:gfreg=ffdmx"
        -lang "$TCOUNT=$lang"
        -name "$TCOUNT=$title"
        -delay "$TCOUNT=$start")
  TCOUNT=$((TCOUNT + 1))
done
[[ ${#CHAPTERS_OPT[@]} -gt 0 ]] && MUX+=("${CHAPTERS_OPT[@]}")
[[ -n "$MOVIE_TITLE" ]] && MUX+=(-itags "name=$MOVIE_TITLE")
MUX+=(-tmp "$WORK_WIN/mp4tmp" -brand mp42isom -ab dby1 "$OUT_WIN")

note "muxing"
printf '   %s\n' "${MUX[*]}"
"${MUX[@]}" > "$WORK/mp4box.log" 2>&1
MUX_RC=$?
if [[ $MUX_RC -ne 0 || ! -f "$OUTPUT" ]]; then
  tail -25 "$WORK/mp4box.log" >&2
  die "MP4Box failed with exit code $MUX_RC"
fi

# --------------------------------------------------------------- verify ------
# The DolbyVision box written by MP4Box is the authoritative check: it is
# container signalling that GPAC itself produced. mediainfo is only a hint,
# because on a remuxed file it can report plain HDR10+ while the RPU is still
# in the track (references/dv-pitfalls.md, "mediainfo lies about Dolby
# Vision"). Treating that hint as a hard failure deleted a perfectly good
# multi-GB file for no reason, so a disagreement is a warning, never a delete.

MP4INFO="$(MP4Box -info "$OUT_WIN" 2>&1 | tr -d '\r')"
MEDIAINFO=""
if command -v mediainfo >/dev/null 2>&1; then
  MEDIAINFO="$(mediainfo "$OUT_WIN" 2>/dev/null | tr -d '\r')"
fi

SRC_V_NAME="HEVC"
[[ "$V_MODE" == "h264" ]] && SRC_V_NAME="AVC"

if [[ "$HAS_DV" -eq 1 ]]; then
  DV_BOX="$(printf '%s' "$MP4INFO" | grep -m1 'DolbyVision version' || true)"
  if [[ -z "$DV_BOX" ]]; then
    printf '%s\n' "$MP4INFO" >&2
    rm -f "$OUTPUT"
    die "verification failed: no DolbyVision box in the output MP4 (output removed)"
  fi
  if [[ -n "$MEDIAINFO" ]] && ! printf '%s' "$MEDIAINFO" | grep -qi 'Dolby Vision'; then
    note "WARNING: the DolbyVision box is present, but mediainfo does not report Dolby Vision."
    note "         This is known mediainfo behaviour on remuxed files, the MP4 is kept."
    note "         Confirm on the player that it reports Dolby Vision and not plain HDR10."
  fi
  note "verified: $(printf '%s' "$DV_BOX" | sed 's/^[[:space:]]*//')"
  if [[ -n "$MEDIAINFO" ]]; then
    note "verified: $(printf '%s' "$MEDIAINFO" | grep -m1 -i 'HDR format' | sed 's/^[[:space:]]*//')"
  fi

  # For a Dolby Vision conversion, comparing the extracted RPU is the stronger
  # check, because the RPU is what carries the DV signalling. Pull the video
  # track back out of the MP4 and byte-compare the RPU against the source RPU.
  MP4Box -raw "1:$WORK_WIN/out_video.hevc" "$OUT_WIN" >/dev/null 2>&1 \
    || { rm -f "$OUTPUT"; die "verification failed: cannot extract the video track from the output MP4 (output removed)"; }
  dovi_tool extract-rpu -i "$WORK_WIN/out_video.hevc" -o "$WORK_WIN/RPU_out.bin" >/dev/null 2>&1 \
    || { rm -f "$OUTPUT"; die "verification failed: no RPU inside the output MP4 (output removed)"; }
  if ! cmp -s "$WORK/RPU.bin" "$WORK/RPU_out.bin"; then
    rm -f "$OUTPUT"
    die "verification failed: the RPU in the output differs byte for byte from the source RPU (output removed)"
  fi
  note "verified: RPU in the MP4 is byte-identical to the source RPU ($RPU_BYTES bytes)"
else
  if ! printf '%s' "$MP4INFO" | grep -qi "$SRC_V_NAME"; then
    printf '%s\n' "$MP4INFO" >&2
    rm -f "$OUTPUT"
    die "verification failed: the output does not contain an $SRC_V_NAME track (output removed)"
  fi
  if printf '%s' "$MP4INFO" | grep -q 'DolbyVision version'; then
    printf '%s\n' "$MP4INFO" >&2
    rm -f "$OUTPUT"
    die "verification failed: a DolbyVision box appeared although the source had no RPU (output removed)"
  fi
  note "verified: $SRC_V_NAME track present, no Dolby Vision signalled (as expected for this source)"
fi

# -------------------------------------------------- verify duration + frames ----
# Byte-for-byte comparison of the extracted elementary stream against the source
# fails, and that is expected: MP4Box moves the VPS/SPS/PPS into the sample
# description, so the first bytes differ. The meaningful check is the decoded
# picture, so both files are decoded with ffmpeg -f framemd5 on sampled windows
# (start, middle, end) and the md5 files must be identical.
#
# ffmpeg -ss on the input lands on the same keyframe in source and output
# (the video is stream-copied), so the same window decodes the same frames.

FMT_SRC_JSON="$("$FP" -v error -show_format -of json "$SRC_WIN" 2>/dev/null)"
FMT_OUT_JSON="$("$FP" -v error -show_format -of json "$OUT_WIN" 2>/dev/null)"
DUR_SRC="$(jqf "$FMT_SRC_JSON" '.format.duration // empty')"
DUR_OUT="$(jqf "$FMT_OUT_JSON" '.format.duration // empty')"

if [[ -n "$DUR_SRC" && -n "$DUR_OUT" ]]; then
  DIFF="$(awk -v a="$DUR_SRC" -v b="$DUR_OUT" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.3f", d }')"
  if awk -v d="$DIFF" 'BEGIN { exit !(d > 1) }'; then
    rm -f "$OUTPUT"
    die "verification failed: output duration $DUR_OUT s differs from source $DUR_SRC s by ${DIFF} s (>1 s) (output removed)"
  fi
  note "verified: duration $DUR_OUT s vs source $DUR_SRC s (diff ${DIFF} s)"
fi

if [[ -n "$DUR_SRC" ]]; then
  MID="$(awk -v d="$DUR_SRC" 'BEGIN { printf "%.3f", (d > 8 ? d / 2 : 0) }')"
  END="$(awk -v d="$DUR_SRC" 'BEGIN { printf "%.3f", (d > 12 ? d - 8 : 0) }')"
  for t in 0 "$MID" "$END"; do
    "$FF" -hide_banner -v error -y -ss "$t" -t 4 -i "$SRC_WIN" -map "0:$V_IDX" \
      -f framemd5 "$(winpath "$WORK/md5_src.md5")" || die "frame md5 extraction failed on the source at t=$t"
    "$FF" -hide_banner -v error -y -ss "$t" -t 4 -i "$OUT_WIN" -map 0:v:0 \
      -f framemd5 "$(winpath "$WORK/md5_out.md5")" || die "frame md5 extraction failed on the output at t=$t"
    # The "#tb" header line is the container timebase, which legitimately
    # changes between MKV (1/1000) and MP4 (96000). Frame hashes are the
    # pictures; compare only those lines.
    if ! cmp -s <(grep -v '^#tb' "$WORK/md5_src.md5") <(grep -v '^#tb' "$WORK/md5_out.md5"); then
      rm -f "$OUTPUT"
      die "verification failed: decoded pictures differ at t=${t}s (output removed)"
    fi
  done
  note "verified: decoded pictures identical (3 sampled windows of 4 s: start, middle, end)"
fi

# ------------------------------------------------------------- subtitles ----
# Sidecar files only, nothing is muxed into the MP4. This block runs AFTER the
# mux and verification: every die() between the mux and here must leave zero
# sidecar artifacts next to a failed output, so a broken conversion cannot drop
# orphan .srt/.ass/.sup files into the library.
#
# Styled ASS/SSA tracks are always exported next to the video, whether or not
# the user listed them in -s: they carry fonts, colours and positioning that
# cannot be reproduced in SRT, so the styled original has to travel with the
# file. Every other subtitle type still requires an explicit id in -s.

SUB_EXPORTS=()
for id in $SUB_IDS_AVAIL; do
  codec="$(smeta "$id" '.codec_name')"
  is_ass=0; [[ "$codec" == "ass" || "$codec" == "ssa" ]] && is_ass=1

  if [[ "$is_ass" -eq 1 ]]; then
    note "subtitle track $id is $codec, exporting automatically"
  elif [[ -z "$WANT_SUBS" || "$WANT_SUBS" != *" $id "* ]]; then
    continue
  fi

  lang="$(valid_lang "$(smeta "$id" '.tags.language')")"
  title="$(sanitize_name "$(smeta "$id" '.tags.title')")"

  slug="$(printf '%s' "$title" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')"
  [[ -n "$slug" ]] || slug="track"

  case "$codec" in
    subrip|srt)
      out_srt="$OUT_DIR/$OUT_BASE.$id.$lang.$slug.srt"
      "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:s copy \
        "$(winpath "$out_srt")" \
        || die "subtitle export failed for track $id"
      note "subs -> $(basename "$out_srt")"
      ;;
    ass|ssa)
      out_ass="$OUT_DIR/$OUT_BASE.$id.$lang.$slug.ass"
      out_srt="$OUT_DIR/$OUT_BASE.$id.$lang.$slug.srt"
      "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:s copy \
        "$(winpath "$out_ass")" \
        || die "subtitle export failed for track $id"
      "$FF" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:s srt \
        "$(winpath "$out_srt")" \
        || die "ASS to SRT conversion failed for track $id"
      note "subs -> $(basename "$out_ass") + $(basename "$out_srt")"
      ;;
    hdmv_pgs_subtitle)
      # ffmpeg cannot encode PGS and cannot write .sup (plan section 8); the
      # working export path is mkvextract. The MKV track id comes from
      # `mkvmerge -i`, never assumed to be index+1: mkvmerge lists tracks in file
      # order, so the nth listed Track ID is ffprobe stream index n-1.
      if [[ ${#TRACK_IDS[@]} -eq 0 ]]; then
        mapfile -t TRACK_IDS < <(mkvmerge -i "$SRC_WIN" 2>/dev/null \
          | sed -n 's/.* \([0-9]\{1,\}\): .*/\1/p')
      fi
      if [[ ${#TRACK_IDS[@]} -le id ]]; then
        die "mkvmerge -i does not list a track for stream index $id; cannot export PGS"
      fi
      tid="${TRACK_IDS[$id]}"
      out_sup="$OUT_DIR/$OUT_BASE.$id.$lang.$slug.sup"
      mkvextract tracks "$SRC_WIN" "$tid:$(winpath "$out_sup")" \
        || die "PGS export failed for track $id"
      # PG magic 50 47 = "PG", the exported file must start with it.
      magic="$(head -c 2 "$out_sup" | od -An -tx1 | tr -d ' \n')"
      [[ "$magic" == "5047" ]] || die "PGS export for track $id has no PG magic ($magic)"
      note "subs -> $(basename "$out_sup") (PGS via mkvextract, no OCR)"
      ;;
    *)
      note "subtitle track $id has unsupported codec '$codec', skipped"
      continue
      ;;
  esac
  SUB_EXPORTS+=("$id$SEP$lang$SEP$title$SEP$slug")
done

# ------------------------------------------------------------------- asm -----

if [[ $ASM -eq 1 ]]; then
  ASM_ARGS=(-hide_banner -v error -y -i "$SRC_WIN")
  for rec in "${AUDIO_EXPORTS[@]}"; do IFS="$SEP" read -r id _ _ _ _ <<< "$rec"; ASM_ARGS+=(-map "0:$id"); done
  for rec in "${SUB_EXPORTS[@]}"; do IFS="$SEP" read -r id _ _ _ <<< "$rec"; ASM_ARGS+=(-map "0:$id"); done
  ASM_ARGS+=(-c copy -f matroska "$(winpath "$OUT_DIR/$OUT_BASE.asm.mkv")")
  "$FF" "${ASM_ARGS[@]}" || die "asm creation failed"
  note "wrote $OUT_BASE.asm.mkv"
fi

# -------------------------------------------------------------- summary ------

[[ $REMOVE_SRC -eq 1 ]] && { rm -f "$INPUT" && note "source removed"; }

# Count the sidecar files that were actually written, not the number of export
# records: an ASS/SSA track produced two files (.ass + .srt) and the record
# count understated it. The file names follow the exact pattern used by the
# export block above, one per extension.
SIDECARS=0
for rec in "${SUB_EXPORTS[@]}"; do
  IFS="$SEP" read -r sid slanga _ sslug <<< "$rec"
  for sext in ass srt sup; do
    [[ -f "$OUT_DIR/$OUT_BASE.$sid.$slanga.$sslug.$sext" ]] && SIDECARS=$((SIDECARS + 1))
  done
done

printf '\n'
note "DONE: $OUTPUT"
if [[ "$HAS_DV" -eq 1 ]]; then
  printf '     DV     Dolby Vision profile %s\n' "$DV_PROFILE"
else
  printf '     DV     NONE - this source had no Dolby Vision layer,\n'
  printf '                 the video stream was copied unchanged\n'
fi
printf '     size   %s\n' "$(du -h "$OUTPUT" | cut -f1)"
printf '     audio  %s track(s)\n' "${#AUDIO_EXPORTS[@]}"
printf '     subs   %s sidecar file(s)\n' "$SIDECARS"
exit 0
