#!/usr/bin/env bash
# probe.sh "<file.mkv|file.mp4>" - markdown track table for the user:
# absolute stream index, codec, profile, bit depth, resolution, fps, channels,
# language, title, bitrate, Atmos core flag, Dolby Vision flag, external
# subtitle scan, layout note. The ids in the table are ABSOLUTE stream indexes.
set -uo pipefail

FFMPEG_BIN="${FFMPEG_BIN:-/cygdrive/c/Program Files/ffmpeg/bin/ffmpeg.exe}"
FFPROBE_BIN="${FFPROBE_BIN:-$(dirname "$FFMPEG_BIN")/ffprobe.exe}"
SCRATCH="${SCRATCH:-/cygdrive/d/tmp/cygwin/opencode}"
DOVI_TOOL="${DOVI_TOOL:-dovi_tool}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Native binaries need Windows paths; the closing quote after "$(cygpath -m ...)"
# is mandatory. (references/traps.md)
winpath() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

# Windows jq.exe emits CRLF on every value: "rus\r" fails ^[a-z]{2,3}$ and the
# language shows as "und", "448000\r" fails numeric checks and the bitrate shows
# as unknown. Strip \r in one central place. (references/traps.md)
jqf() { printf '%s' "$1" | jq -r "$2" 2>/dev/null | tr -d '\r'; }

[[ $# -eq 1 && -f "$1" ]] || { printf 'usage: probe.sh <file.mkv|file.mp4>\n' >&2; exit 1; }
SRC="$1"
SRC_WIN="$(winpath "$SRC")"

# Plain -show_streams and plain -show_format, NO -show_entries combinations: on
# ffmpeg 4.4 the combination silently drops fields (the language disappeared and
# the subtitle table became useless). Filter with jq. (references/traps.md #7)
STREAM_JSON="$("$FFPROBE_BIN" -v error -show_streams -of json "$SRC_WIN" 2>/dev/null)"
FORMAT_JSON="$("$FFPROBE_BIN" -v error -show_format -of json "$SRC_WIN" 2>/dev/null)"
[[ -n "$STREAM_JSON" ]] || die "ffprobe cannot read $SRC"

# Lookup by absolute index: select(.index==N). "-select_streams a:N" is relative
# to the stream type and silently returns the wrong track when indexes diverge;
# it is never used for metadata. (references/traps.md, the most dangerous trap)
smeta() {
  local idx="$1" expr="$2" out
  out="$(jqf "$STREAM_JSON" ".streams[] | select(.index==$idx) | ($expr) // empty")"
  printf '%s' "$out" | tr -d '\r' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//'
}

CONT_BR="$(jqf "$FORMAT_JSON" '.format.bit_rate // empty')"
DUR="$(jqf "$FORMAT_JSON" '.format.duration // empty')"
SIZE="$(jqf "$FORMAT_JSON" '.format.size // empty')"
AUDIO_SUM="$(jqf "$STREAM_JSON" '[ .streams[] | select(.codec_type=="audio")
  | (.bit_rate | tonumber? // 0) ] | add // 0')"

# The MKV container does not store a per-stream bitrate, so the video source
# bitrate is the container bitrate minus the sum of audio bitrates. mediainfo
# is used as a cross-check when present.
VIDEO_SRC_BR="$(awk -v c="${CONT_BR:-0}" -v a="${AUDIO_SUM:-0}" 'BEGIN { printf "%d", c - a }')"
MEDIAINFO_BR=""
if command -v mediainfo >/dev/null 2>&1; then
  # mediainfo JSON has NO ".Video": every track lives in .media.track[] and is
  # typed by its "@type" key, so the video bitrate is read with
  # select(."@type"=="Video"). The old .Video path never printed anything.
  MEDIAINFO_BR="$(mediainfo --Output=JSON "$SRC_WIN" 2>/dev/null | jq -r '
    .media.track[] | select(."@type"=="Video") | .BitRate // empty' 2>/dev/null | tr -d '\r' | head -1)"
fi

# Dolby Vision detection: ffprobe side data (dv_playback / Dolby Vision entry)
# first, then dovi_tool extract-rpu + info on a 20 s head slice. dovi_tool info
# expects an RPU file, NEVER the container: calling it on the MKV produces a
# misleading "invalid RPU". Only output-side -t cuts a slice; -ss/-t on the
# input do not cut streams. (references/traps.md, dv2mp4 probe note)
# Every exit path removes probe-slice-*/probe-rpu-*: a probe run must leave no
# temp files in SCRATCH, including the ones that return early.
dv_probe() {
  local vidx="$1" sd slice prof rpu
  # the temp names are fixed up front so every exit path, early ones included,
  # can remove them
  local slice_cyg="$SCRATCH/probe-slice-$vidx.hevc"
  local rpu_cyg="$SCRATCH/probe-rpu-$vidx.bin"
  sd="$(jqf "$STREAM_JSON" '.streams[] | select(.index=='"$vidx"') | [ .side_data_list[]?.side_data_type ] | join(" ")')"
  if printf '%s' "$sd" | grep -qi 'dolby vision'; then
    rm -f "$slice_cyg" "$rpu_cyg"
    printf 'yes (ffprobe side data)'
    return
  fi
  [[ "$(smeta "$vidx" '.codec_name')" == "hevc" ]] \
    || { rm -f "$slice_cyg" "$rpu_cyg"; printf 'no (no HEVC video stream)'; return; }
  mkdir -p "$SCRATCH" 2>/dev/null
  slice="$(winpath "$slice_cyg")"
  "$FFMPEG_BIN" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$vidx" -c:v copy \
    -bsf:v hevc_mp4toannexb -t 20 -f hevc "$slice" >/dev/null 2>&1
  [[ -s "$slice_cyg" ]] \
    || { rm -f "$slice_cyg" "$rpu_cyg"; printf 'unknown (slice extraction failed)'; return; }
  rpu="$rpu_cyg"
  "$DOVI_TOOL" extract-rpu -i "$slice" -o "$(winpath "$rpu")" >/dev/null 2>&1
  prof="$("$DOVI_TOOL" info -i "$(winpath "$rpu")" -f 0 2>/dev/null \
    | tr -d '\r' | sed -n '/^{/,$p' | jq -r '.dovi_profile // empty')"
  if [[ $(stat -c%s "$rpu" 2>/dev/null || printf '0') -gt 0 ]]; then
    if [[ -n "$prof" ]]; then printf 'yes (RPU, profile %s)' "$prof"
    else printf 'yes (RPU present)'; fi
  else
    printf 'no (no RPU in the first 20 s)'
  fi
  rm -f "$slice_cyg" "$rpu_cyg"
}

# Atmos/core-id for E-AC-3: ffprobe puts the JOC marker into the profile string.
# In jq, the number 0 is truthy (only false and null are falsy), so every check
# here compares explicitly, never a bare truthiness test. (references/traps.md)
atmos_flag() {
  local codec="$1" prof="$2" ch="$3"
  if [[ "$codec" == "eac3" ]] && printf '%s' "$prof" | grep -qi 'atmos'; then
    printf 'Atmos, core %s ch' "${ch:-?}"
  else
    printf '-'
  fi
}

FIRST_HEVC="$(jqf "$STREAM_JSON" '[ .streams[] | select(.codec_type=="video" and .codec_name=="hevc") ] | .[0].index // empty')"
DV_LINE='no (no HEVC video stream)'
[[ -n "$FIRST_HEVC" ]] && DV_LINE="$(dv_probe "$FIRST_HEVC")"

printf '## Probe: `%s`\n\n' "$SRC"
printf '| # | type | codec | profile | bits | W x H | fps | ch | lang | title | kbps | flags |\n'
printf '|---|-----|-------|---------|------|-------|-----|----|------|-------|------|-------|\n'

for idx in $(jqf "$STREAM_JSON" '.streams[] | .index'); do
  ctype="$(smeta "$idx" '.codec_type')"
  codec="$(smeta "$idx" '.codec_name')"
  prof="$(smeta "$idx" '.profile')"
  pix="$(smeta "$idx" '.pix_fmt')"
  bps="$(smeta "$idx" '.bits_per_raw_sample')"
  w="$(smeta "$idx" '.width')"
  h="$(smeta "$idx" '.height')"
  lang="$(smeta "$idx" '.tags.language')"
  title="$(smeta "$idx" '.tags.title')"
  br="$(smeta "$idx" '.bit_rate')"
  ch="$(smeta "$idx" '.channels')"

  bits="-"; wh="-"; fps_out="-"; ch_out="-"; kbps="-"; flags="-"
  [[ -n "$title" ]] || title="-"
  # Titles legitimately contain "|"; escape it so the markdown table columns
  # cannot shift. Records inside the scripts use US (0x1f), never "|".
  # (references/traps.md)
  title="${title//|/\|}"
  [[ -n "$lang" ]] || lang="und"

  if [[ "$ctype" == "video" ]]; then
    bits="8"
    if [[ "$bps" =~ ^[0-9]+$ && "$bps" -gt 8 ]]; then bits="$bps"
    elif printf '%s' "$pix" | grep -q '10[lb]e'; then bits="10"
    fi
    wh="${w}x${h}"
    fps_out="$(smeta "$idx" '.avg_frame_rate')"
    [[ "$fps_out" == "0/0" || -z "$fps_out" ]] && fps_out="$(smeta "$idx" '.r_frame_rate')"
    if [[ "$fps_out" == */* ]]; then
      fps_out="$(awk -v f="$fps_out" 'BEGIN { split(f, p, "/"); if (p[2]+0 > 0) printf "%.3f", p[1]/p[2]; else print "?" }')"
    fi
    if [[ -n "$br" ]]; then kbps="$(awk -v b="$br" 'BEGIN { printf "%.0f", b/1000 }')"
    else kbps="$(awk -v b="$VIDEO_SRC_BR" 'BEGIN { printf "%.0f", b/1000 }')"
    fi
    [[ "$idx" == "$FIRST_HEVC" ]] && flags="DV: $DV_LINE"
  elif [[ "$ctype" == "audio" ]]; then
    ch_out="${ch:-?}"
    if [[ -n "$br" ]]; then kbps="$(awk -v b="$br" 'BEGIN { printf "%.0f", b/1000 }')"
    fi
    flags="$(atmos_flag "$codec" "$prof" "$ch")"
  fi

  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$idx" "$ctype" "${codec:-?}" "${prof:--}" "$bits" "$wh" "$fps_out" "$ch_out" "$lang" "$title" "$kbps" "$flags"
done

printf '\n'
printf 'file: %s bytes, duration %s s, container bitrate %s bit/s\n' \
  "${SIZE:-?}" "${DUR:-?}" "${CONT_BR:-?}"
if [[ -n "$MEDIAINFO_BR" ]]; then
  printf 'mediainfo cross-check: video bitrate %s\n' "$MEDIAINFO_BR"
fi
# The DV verdict prints for every file, not only on the HEVC row: an h264 source
# is "no", a HEVC source carries the side-data/slice/RPU verdict.
printf 'Dolby Vision: %s\n' "$DV_LINE"

# External subtitle scan: Plex reads sidecars "<video name>.<lang>.<ext>" next to
# the video. .ogg sidecars are not indexed in a video collection (checked on the
# TV by hand). SRT as sidecar is the norm; PGS never goes sidecar.
IN_DIR="$(dirname "$SRC")"
IN_BASE="$(basename "$SRC")"
IN_BASE="${IN_BASE%.*}"
EXT_FOUND=0
printf '\nExternal subtitles (Plex sidecar, .srt/.ass/.ssa/.sub/.vtt):\n'
for f in "$IN_DIR"/"$IN_BASE".*; do
  case "$f" in *.srt|*.ass|*.ssa|*.sub|*.vtt) ;; *) continue ;; esac
  [[ -f "$f" ]] || continue
  name="$(basename "$f")"
  rel="${name#"$IN_BASE."}"; rel="${rel%.*}"
  # Plex sidecar names are "<base>.<lang>.<ext>": the extension is a 3-letter
  # token too, so "movie.srt" was read as lang=srt. Strip the extension, skip
  # the subtitle extensions, accept only 2-3 lowercase letters. (same rule as
  # convert.sh / batch.sh / subs.sh sidecar_lang)
  lang="und"
  for tok in $(printf '%s' "$rel" | tr '.' ' '); do
    case "$tok" in srt|ass|ssa|sub|vtt) continue ;; esac
    [[ "$tok" =~ ^[a-z]{2,3}$ ]] && lang="$tok"
  done
  printf '  %s  lang=%s\n' "$name" "$lang"
  EXT_FOUND=1
done
[[ $EXT_FOUND -eq 0 ]] && printf '  none next to this file\n'

# Layout note (plan section 1): the target layout is decided by the path shape.
printf '\nLayout note (plan section 1):\n'
if [[ "$SRC" == *"/Season "* ]]; then
  printf '  series: this file lives in a Season folder. Target layout serial_name/Season N/.\n'
else
  printf '  film: flat collection folder; a film split into parts/episodes gets its own catalog directory.\n'
fi
printf '  File names follow the pattern of an already-indexed sample of the same\n'
printf '  Plex section (batch.sh reads it through the Plex API), so the scanner\n'
printf '  does not create duplicates. Sidecar subs: <out name>.<lang>.srt next to the video.\n'
