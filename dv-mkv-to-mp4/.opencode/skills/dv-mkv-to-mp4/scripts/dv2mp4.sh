#!/usr/bin/env bash
# dv2mp4.sh - convert Dolby Vision MKV to Dolby Vision MP4.
# Requires: ffmpeg, ffprobe, jq, MP4Box (GPAC >= 2), dovi_tool, mkvextract.
# Every intermediate file lives in a temp dir under ~/tmp and is removed on exit.
set -uo pipefail

# ---------------------------------------------------------------- helpers ----

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'dv2mp4: %s\n' "$*"; }

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
  local start=$SECONDS rc=0
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
KEEP_TMP=0; ASM=0; PROBE=0; REMOVE_SRC=0; DVP_OVERRIDE=""; MOVIE_TITLE=""; TMP_PARENT=""

usage() {
  cat <<'USAGE'
Usage: dv2mp4.sh -i INPUT.mkv [-o OUTPUT.mp4] [options]

Required:
  -i, --input FILE      source MKV with Dolby Vision

Output:
  -o, --output FILE     output MP4. Optional: by default a source with Dolby
                        Vision becomes <base>.DV-MP4.mp4 and a source without
                        becomes <base>.mp4, next to the source file

Track selection (ids are absolute stream indexes):
  -a, --audio IDS       comma separated audio ids to keep (default: all)
  -s, --subs IDS        comma separated subtitle ids to export as sidecars
                        (default: none). subrip -> .srt, hdmv_pgs -> .sup.
                        ASS/SSA tracks are always exported, with or without -s.
  -l, --langs LIST      comma separated language filter, e.g. rus,eng

Behaviour:
      --probe            only report whether the file has Dolby Vision and which
                        profile, then exit. Reads just the head of the video
                        stream, so it is fast even on a huge source
      --asm             also write "<out>.asm.mkv" with audio+subs, no video
      --remove-source   delete the source MKV after a successful conversion
      --keep            keep the temp working directory (debugging)
      --title TEXT      title written into the MP4
      --dvp VALUE       force the GPAC dvp= value, e.g. 8.1.hdr10
      --tmp DIR         parent dir for the temp working dir (default: ~/tmp)
  -h, --help            this help

Audio handling, chosen for TV playback:
  ac3, eac3, aac, mp3  copied untouched, TVs and MP4 handle them natively
  flac                 -> AC-3 640 kbit/s (max for AC-3), 5.1 if wider
  dts                  -> AC-3, source bitrate when it is under 640 kbit/s,
                          otherwise the 640 kbit/s maximum, with a warning
  truehd and others    -> E-AC-3 1024 kbit/s

Subtitles are never muxed into the MP4, they are always sidecar files next to
it. ASS/SSA tracks are exported automatically as both .ass and .srt because the
styled original cannot be represented in SRT.

Notes:
  * Dolby Vision is detected with dovi_tool. mediainfo is not trusted for this:
    it stops reporting "Dolby Vision" on remuxed MKVs even when the RPU is fine.
  * A source with no Dolby Vision RPU is still converted: the video stream is
    copied unchanged into the MP4, no DV signalling is written, and the summary
    states that the file has no Dolby Vision.
  * Dolby Vision profile 8 is the only profile verified on real hardware here.
    Profiles 4, 5 and 7 are ported from dvmkv2mp4 and remain unverified.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)      INPUT="${2:-}";  shift 2 ;;
    -o|--output)     OUTPUT="${2:-}"; shift 2 ;;
    -a|--audio)      AUDIO_IDS="${2:-}"; shift 2 ;;
    -s|--subs)       SUB_IDS="${2:-}";  shift 2 ;;
    -l|--langs)      LANGS="${2:-all}"; shift 2 ;;
    --asm)           ASM=1; shift ;;
    --probe)         PROBE=1; shift ;;
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
need_tool ffmpeg; need_tool ffprobe; need_tool jq
need_tool MP4Box; need_tool dovi_tool; need_tool mkvextract

SRC_WIN="$(winpath "$INPUT")"

# --------------------------------------------------------- temp workspace ----
# ~/tmp is a cygwin path, but ffmpeg, MP4Box and dovi_tool are native Windows
# binaries and cannot write to "/cygdrive/<drive>/tmp/...". Every native tool is
# therefore given WORK_WIN, while bash itself keeps using WORK.

TMP_PARENT="${TMP_PARENT:-$HOME/tmp}"
mkdir -p "$TMP_PARENT" 2>/dev/null || die "cannot create temp parent: $TMP_PARENT"
WORK="$(mktemp -d "$TMP_PARENT/dv2mp4.XXXXXXXX")" || die "cannot create work dir"
WORK_WIN="$(winpath "$WORK")"
mkdir -p "$WORK_WIN" 2>/dev/null

cleanup() {
  local rc=$?
  if [[ $KEEP_TMP -eq 1 ]]; then
    note "temp kept at $WORK"
  else
    rm -rf "$WORK"
  fi
  return $rc
}
trap cleanup EXIT

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

# --------------------------------------------------------------- probing ----

STREAM_JSON="$(ffprobe -v error -show_streams -of json "$SRC_WIN" 2>/dev/null)"
[[ -n "$STREAM_JSON" ]] || die "ffprobe could not read $INPUT"

VCOUNT="$(jqf "$STREAM_JSON" '[ .streams[]
  | select(.codec_type=="video" and .codec_name=="hevc") ] | length')"
[[ "${VCOUNT:-0}" -ge 1 ]] \
  || die "no HEVC video stream found; this script handles HEVC/Dolby Vision only"

AUDIO_IDS_AVAIL="$(jqf "$STREAM_JSON" '.streams[]
  | select(.codec_type=="audio") | .index' | tr '\n' ' ')"
SUB_IDS_AVAIL="$(jqf "$STREAM_JSON" '.streams[]
  | select(.codec_type=="subtitle") | .index' | tr '\n' ' ')"

if [[ -n "$AUDIO_IDS" ]]; then WANT_AUDIO=" ${AUDIO_IDS//,/ } "; else WANT_AUDIO=" $AUDIO_IDS_AVAIL "; fi
if [[ -n "$SUB_IDS" ]]; then WANT_SUBS=" ${SUB_IDS//,/ } "; else WANT_SUBS=""; fi

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

if [[ "$VCOUNT" -ge 2 ]]; then
  note "dual layer video detected, using the profile 7 path"
  run_with_heartbeat "extracting the base layer" \
    ffmpeg -hide_banner -v error -y -i "$SRC_WIN" -map 0:v:0 -c:v copy \
    -bsf:v hevc_mp4toannexb "${EXTRACT_ARGS[@]}" -f hevc "$WORK_WIN/BL.hevc" \
    || die "BL extraction failed"
  run_with_heartbeat "extracting the enhancement layer" \
    ffmpeg -hide_banner -v error -y -i "$SRC_WIN" -map 0:v:1 -c:v copy \
    -bsf:v hevc_mp4toannexb "${EXTRACT_ARGS[@]}" -f hevc "$WORK_WIN/EL.hevc" \
    || die "EL extraction failed"
  dovi_tool extract-rpu -i "$WORK_WIN/EL.hevc" -o "$WORK_WIN/RPU_EL.bin" >/dev/null 2>&1 \
    || die "no RPU in the enhancement layer; not a profile 7 source after all"
  dovi_tool inject-rpu -i "$WORK_WIN/BL.hevc" --rpu-in "$WORK_WIN/RPU_EL.bin" \
    -o "$WORK_WIN/BL_RPU.hevc" >/dev/null 2>&1 || die "inject-rpu failed"
else
  run_with_heartbeat "extracting the video stream" \
    ffmpeg -hide_banner -v error -y -i "$SRC_WIN" -map 0:v:0 -c:v copy \
    -bsf:v hevc_mp4toannexb "${EXTRACT_ARGS[@]}" -f hevc "$WORK_WIN/BL_RPU.hevc" \
    || die "video extraction failed"
fi

# ----------------------------------------------- detect DV via dovi_tool -----
# A source without a Dolby Vision RPU is not an error: the user asked for the
# video stream to be copied unchanged and to be told there is no DV layer. In
# that case the HEVC is muxed as plain HEVC and the dvp= option is omitted
# entirely, so nothing Dolby specific is written into the container.

HAS_DV=0
DVP=""

dovi_tool extract-rpu -i "$WORK_WIN/BL_RPU.hevc" -o "$WORK_WIN/RPU.bin" >/dev/null 2>&1
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
  V_SIZE="$(jqf "$STREAM_JSON" '[ .streams[]
    | select(.codec_type=="video" and .codec_name=="hevc") ][0]
    | "\(.width // "?")x\(.height // "?")"' | head -1)"
  XFER_PROBE="$(video_xfer)"
  printf '\n'
  printf 'PROBE RESULT for %s\n' "$INPUT"
  printf '  video            HEVC %s\n' "${V_SIZE:-unknown}"
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
[[ -e "$OUTPUT" ]] && die "output already exists: $OUTPUT"
OUT_WIN="$(winpath "$OUTPUT")"
OUT_BASE="$(basename "$OUTPUT" .mp4)"
note "output   $OUTPUT"

# --------------------------------------------------------------- chapters ----

CHAPTERS_OPT=""
if mkvextract chapters -s "$SRC_WIN" > "$WORK/chapters.list" 2>/dev/null && [[ -s "$WORK/chapters.list" ]]; then
  CHAPTERS_OPT="-chap $WORK_WIN/chapters.list"
  note "chapters: $(grep -c 'CHAPTER' "$WORK/chapters.list")"
fi

# ------------------------------------------------------------------ audio ----

AUDIO_EXPORTS=()
for id in $AUDIO_IDS_AVAIL; do
  [[ "$WANT_AUDIO" == *" $id "* ]] || continue

  codec="$(smeta "$id" '.codec_name')"
  lang="$(valid_lang "$(smeta "$id" '.tags.language')")"
  title="$(sanitize_name "$(smeta "$id" '.tags.title')")"
  start="$(valid_int "$(smeta "$id" '.start_pts')")"; start="${start:-0}"
  src_br="$(valid_int "$(smeta "$id" '.bit_rate')")"
  channels="$(valid_int "$(smeta "$id" '.channels')")"
  [[ -n "$codec" ]] || continue

  if [[ "$LANGS" != "all" && ",$LANGS," != *",$lang,"* ]]; then
    note "audio $id ($lang) skipped by --langs"
    continue
  fi

  out_ext="$codec"

  case "$codec" in
    ac3|eac3|aac|mp3)
      # Already understood by TVs and by MP4, so never re-encode these.
      fmt="$codec"; [[ "$codec" == "aac" ]] && fmt="adts"
      ffmpeg -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:a copy \
        -f "$fmt" "$WORK_WIN/$id.$lang.$codec" || die "audio extraction failed for track $id"
      ;;
    flac)
      # Most TVs cannot decode FLAC at all, so it must be re-encoded.
      # AC-3 is used because the user asked for it, at its maximum bitrate.
      FLAC_OPTS=(-b:a 640k)
      if [[ -n "$channels" && "$channels" -gt 6 ]]; then
        # AC-3 tops out at 5.1, anything wider has to be downmixed.
        FLAC_OPTS+=(-ac 6)
      fi
      ffmpeg -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:a ac3 "${FLAC_OPTS[@]}" \
        -f ac3 "$WORK_WIN/$id.$lang.ac3" || die "audio transcode failed for track $id"
      out_ext="ac3"
      note "audio $id (FLAC ${channels:-?}ch) -> AC-3 640k$([[ -n "$channels" && "$channels" -gt 6 ]] && echo " (downmixed to 5.1)")"
      ;;
    dts)
      # AC-3 is limited to 640 kbit/s, so the target is the source bitrate when
      # it fits under that cap and the cap itself otherwise.
      DTS_BR=640
      src_br_k=0
      if [[ -n "$src_br" ]]; then
        src_br_k=$((src_br / 1000))
        if [[ "$src_br_k" -lt 640 ]]; then DTS_BR="$src_br_k"; fi
        if [[ "$src_br_k" -gt 640 ]]; then
          note "audio $id: DTS source is ${src_br_k} kbit/s, AC-3 cannot exceed 640 kbit/s, using 640"
        fi
      else
        note "audio $id: DTS bitrate unknown in the container, assuming the AC-3 maximum 640 kbit/s"
      fi
      DTS_OPTS=(-b:a "${DTS_BR}k")
      if [[ -n "$channels" && "$channels" -gt 6 ]]; then DTS_OPTS+=(-ac 6); fi
      ffmpeg -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:a ac3 "${DTS_OPTS[@]}" \
        -f ac3 "$WORK_WIN/$id.$lang.ac3" || die "audio transcode failed for track $id"
      out_ext="ac3"
      note "audio $id (DTS ${src_br_k}kbit/s, ${channels:-?}ch) -> AC-3 ${DTS_BR}k"
      ;;
    *)
      ffmpeg -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:a eac3 -b:a 1024k \
        -f eac3 "$WORK_WIN/$id.$lang.eac3" || die "audio transcode failed for track $id"
      # The file on disk is E-AC-3, so out_ext must follow the file, not the
      # source codec, otherwise MP4Box is pointed at a name that does not exist.
      out_ext="eac3"
      note "audio $id ($codec) transcoded to E-AC-3 1024k"
      ;;
  esac
  AUDIO_EXPORTS+=("$id$SEP$lang$SEP$title$SEP$start$SEP$out_ext")
done
[[ ${#AUDIO_EXPORTS[@]} -gt 0 ]] || die "no audio tracks selected; nothing to mux"

# ------------------------------------------------------------- subtitles ----
# Sidecar files only, nothing is muxed into the MP4.
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
      out_srt="$OUTPUT_DIR/$OUT_BASE.$id.$lang.$slug.srt"
      ffmpeg -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:s copy "$out_srt" \
        || die "subtitle export failed for track $id"
      note "subs -> $(basename "$out_srt")"
      ;;
    ass|ssa)
      out_ass="$OUTPUT_DIR/$OUT_BASE.$id.$lang.$slug.ass"
      out_srt="$OUTPUT_DIR/$OUT_BASE.$id.$lang.$slug.srt"
      ffmpeg -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:s copy "$out_ass" \
        || die "subtitle export failed for track $id"
      ffmpeg -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:s srt "$out_srt" \
        || die "ASS to SRT conversion failed for track $id"
      note "subs -> $(basename "$out_ass") + $(basename "$out_srt")"
      ;;
    hdmv_pgs_subtitle)
      out_sup="$OUTPUT_DIR/$OUT_BASE.$id.$lang.$slug.sup"
      ffmpeg -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:s copy "$out_sup" \
        || die "subtitle export failed for track $id"
      note "subs -> $(basename "$out_sup") (PGS kept as .sup, no OCR)"
      ;;
    *)
      note "subtitle track $id has unsupported codec '$codec', skipped"
      continue
      ;;
  esac
  SUB_EXPORTS+=("$id$SEP$lang$SEP$title$SEP$slug")
done

# ------------------------------------------------------------- build MP4 -----
# ":name=" is deliberate: without it MP4Box copies the whole import string into
# the track handler name and media servers show "hevc:dvp=8.1.hdr10@GPAC..." as
# the title. When there is no Dolby Vision the dvp= option is left out so the
# track is imported as plain HEVC.

if [[ "$HAS_DV" -eq 1 ]]; then
  VIDEO_ADD="$WORK_WIN/BL_RPU.hevc:dvp=$DVP:name="
else
  VIDEO_ADD="$WORK_WIN/BL_RPU.hevc:name="
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
[[ -n "$CHAPTERS_OPT" ]] && MUX+=("$CHAPTERS_OPT")
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
# A silent failure here means the file is not really Dolby Vision, so these are
# hard failures rather than warnings. When the source had no Dolby Vision there
# is nothing to assert, so only the video track is checked.

MP4INFO="$(MP4Box -info "$OUT_WIN" 2>&1 | tr -d '\r')"
MEDIAINFO="$(mediainfo "$OUT_WIN" 2>/dev/null | tr -d '\r')"

if [[ "$HAS_DV" -eq 1 ]]; then
  DV_BOX="$(printf '%s' "$MP4INFO" | grep -m1 'DolbyVision version' || true)"
  if [[ -z "$DV_BOX" ]]; then
    printf '%s\n' "$MP4INFO" >&2
    rm -f "$OUTPUT"
    die "verification failed: no DolbyVision box in the output MP4 (output removed)"
  fi
  if [[ -n "$MEDIAINFO" ]] && ! printf '%s' "$MEDIAINFO" | grep -qi 'Dolby Vision'; then
    printf '%s\n' "$MEDIAINFO" >&2
    rm -f "$OUTPUT"
    die "verification failed: mediainfo does not see Dolby Vision in the output (output removed)"
  fi
  note "verified: $(printf '%s' "$DV_BOX" | sed 's/^[[:space:]]*//')"
  note "verified: $(printf '%s' "$MEDIAINFO" | grep -m1 -i 'HDR format' | sed 's/^[[:space:]]*//')"
else
  if ! printf '%s' "$MP4INFO" | grep -q 'HEVC'; then
    printf '%s\n' "$MP4INFO" >&2
    rm -f "$OUTPUT"
    die "verification failed: the output does not contain an HEVC track (output removed)"
  fi
  if printf '%s' "$MP4INFO" | grep -q 'DolbyVision version'; then
    printf '%s\n' "$MP4INFO" >&2
    rm -f "$OUTPUT"
    die "verification failed: a DolbyVision box appeared although the source had no RPU (output removed)"
  fi
  note "verified: HEVC track present, no Dolby Vision signalled (as expected for this source)"
fi

# ------------------------------------------------------------------- asm -----

if [[ $ASM -eq 1 ]]; then
  ASM_ARGS=(-hide_banner -v error -y -i "$SRC_WIN")
  for rec in "${AUDIO_EXPORTS[@]}"; do IFS="$SEP" read -r id _ _ _ _ <<< "$rec"; ASM_ARGS+=(-map "0:$id"); done
  for rec in "${SUB_EXPORTS[@]}"; do IFS="$SEP" read -r id _ _ _ <<< "$rec"; ASM_ARGS+=(-map "0:$id"); done
  ASM_ARGS+=(-c copy -f matroska "$OUTPUT_DIR/$OUT_BASE.asm.mkv")
  ffmpeg "${ASM_ARGS[@]}" || die "asm creation failed"
  note "wrote $OUT_BASE.asm.mkv"
fi

# -------------------------------------------------------------- summary ------

[[ $REMOVE_SRC -eq 1 ]] && { rm -f "$INPUT" && note "source removed"; }

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
printf '     subs   %s sidecar file(s)\n' "${#SUB_EXPORTS[@]}"
exit 0
