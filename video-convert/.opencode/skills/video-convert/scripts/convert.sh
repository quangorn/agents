#!/usr/bin/env bash
# convert.sh - one ffmpeg invocation for one file. Output is always MKV.
# Video: copy when the codec is in the copy-set, encode with the fixed HEVC
# flag set; audio by the full ladder; subtitles none | burn | sidecar.
# After the run ffprobe verifies codec / channel count / duration; on failure
# the partial output is deleted and the script exits 1.
# One ffmpeg process at a time (GPU rule), everything sequential.
set -uo pipefail

FFMPEG_BIN="${FFMPEG_BIN:-/cygdrive/c/Program Files/ffmpeg/bin/ffmpeg.exe}"
FFPROBE_BIN="${FFPROBE_BIN:-$(dirname "$FFMPEG_BIN")/ffprobe.exe}"
SCRATCH="${SCRATCH:-/cygdrive/d/tmp/cygwin/opencode}"
ASS2SRT="${ASS2SRT:-$HOME/.config/opencode/skills/ass-to-srt/scripts}"
WINFONTS="${WINFONTS:-C:/Windows/Fonts}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf 'convert: %s\n' "$*"; }

# Native binaries do not understand /cygdrive/... paths; the closing quote after
# "$(cygpath -m ...)" is mandatory. (references/traps.md)
winpath() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

# Windows jq.exe emits CRLF on every value; strip \r centrally so language,
# bitrate and codec validation never see "rus\r" / "448000\r". (traps.md)
jqf() { printf '%s' "$1" | jq -r "$2" 2>/dev/null | tr -d '\r'; }

# The subtitles filter needs ':' in a Windows path escaped. Plain bash
# substitution, no sed: the sed delimiter collides with the colon escape.
fesc() {
  # ffmpeg filter parsing is two levels: the graph level eats one backslash,
  # so a Windows 'D:' inside a filter value needs \: escaped once at argument
  # level and the whole value wrapped in single quotes. Quoting alone and
  # escaping alone both failed to parse in this ffmpeg build.
  local s="$1"
  s=$(printf '%s' "$s" | sed 's/:/\\:/g')
  printf "%s" "'$s'"
}

usage() {
  cat <<'USAGE'
Usage: convert.sh --in FILE --out OUT.mkv --video copy|encode --audio copy|encode
                  --sub-mode none|burn|sidecar [--lang ru]
                  [--video-ids IDS] [--audio-ids IDS] [--sub-ids IDS]

Track ids are ABSOLUTE stream indexes (what probe.sh prints and "ffmpeg -map
0:ID" expects), comma separated. Output must be .mkv. One ffmpeg at a time.
USAGE
}

IN=""; OUT=""; VMODE=""; AMODE=""; SUBMODE=""; SUBLANG=""; VIDS=""; AIDS=""; SIDS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) IN="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --video) VMODE="${2:-}"; shift 2 ;;
    --audio) AMODE="${2:-}"; shift 2 ;;
    --sub-mode) SUBMODE="${2:-}"; shift 2 ;;
    --lang) SUBLANG="${2:-}"; shift 2 ;;
    --video-ids) VIDS="${2:-}"; shift 2 ;;
    --audio-ids) AIDS="${2:-}"; shift 2 ;;
    --sub-ids) SIDS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "$IN" && -f "$IN" ]] || { usage >&2; die "--in FILE is required"; }
[[ -n "$OUT" ]] || { usage >&2; die "--out is required"; }
# Output must be .mkv. "-f mkv" is not a valid ffmpeg format name; matroska is.
case "$OUT" in *.mkv) ;; *) die "output must be .mkv (matroska): $OUT" ;; esac
case "$VMODE" in copy|encode) ;; *) die "--video must be copy|encode" ;; esac
case "$AMODE" in copy|encode) ;; *) die "--audio must be copy|encode" ;; esac
case "$SUBMODE" in none|burn|sidecar) ;; *) die "--sub-mode must be none|burn|sidecar" ;; esac
[[ -e "$OUT" ]] && die "output already exists: $OUT"

# Burn-in consumes the video decode, so it forces the video encode.
if [[ "$SUBMODE" == "burn" && "$VMODE" == "copy" ]]; then
  log "sub-mode burn forces --video encode"
  VMODE="encode"
fi

SRC_WIN="$(winpath "$IN")"
OUT_WIN="$(winpath "$OUT")"
OUT_DIR="$(dirname "$OUT")"
OUT_BASE="$(basename "$OUT" .mkv)"
IN_DIR="$(dirname "$IN")"
IN_BASE="$(basename "$IN")"
IN_BASE="${IN_BASE%.*}"
mkdir -p "$OUT_DIR" 2>/dev/null || die "cannot create $OUT_DIR"

WORK="$SCRATCH/convert-$$"
mkdir -p "$WORK" 2>/dev/null || die "cannot create scratch work dir $WORK"

cleanup() {
  local rc=$?
  rm -rf "$WORK"
  return "$rc"
}
trap cleanup EXIT

# Plain -show_streams, NO -show_entries combination: ffmpeg 4.4 silently drops
# fields when they are combined. (references/traps.md #7)
STREAM_JSON="$("$FFPROBE_BIN" -v error -show_streams -of json "$SRC_WIN" 2>/dev/null)"
FORMAT_JSON="$("$FFPROBE_BIN" -v error -show_format -of json "$SRC_WIN" 2>/dev/null)"
[[ -n "$STREAM_JSON" ]] || die "ffprobe cannot read $IN"

# Lookup by absolute index. "-select_streams a:N" is relative to the stream type
# and is never used for metadata. (references/traps.md, the most dangerous trap)
smeta() {
  local idx="$1" expr="$2" out
  out="$(jqf "$STREAM_JSON" ".streams[] | select(.index==$idx) | ($expr) // empty")"
  printf '%s' "$out" | tr -d '\r' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//'
}

# Language: strip \r first; accept ru <-> rus (a 3-letter tag starting with the
# wanted 2-letter code matches).
lang_match() {
  local want="$1" tag="$2" t
  [[ -z "$want" ]] && return 0
  t="$(printf '%s' "$tag" | tr -d '\r[:space:]')"
  [[ "$t" == "$want" || "$t" == "${want}"* ]]
}

# Name token written into the sidecar file name, copied from subs.sh name_lang()
# and adapted to the single --lang token of convert.sh: when --lang matched, the
# 2-letter code is the name ("ru", the plan section 9.6 pattern ".ru.srt"). The
# raw 3-letter stream tag "rus" is NEVER a sidecar name: it is a name the scanner
# has never seen, and it duplicates the external pack "movie.ru.srt" in the same
# collection folder.
name_lang() {
  local tag="$1" want="${SUBLANG:-}" t
  [[ -z "$want" ]] && { printf '%s' "$tag"; return; }
  t="$(printf '%s' "$tag" | tr -d '\r[:space:]')"
  [[ "$t" == "$want" ]] && { printf '%s' "$want"; return; }
  [[ "$t" == "${want}"* ]] && { printf '%s' "$want"; return; }
  printf '%s' "$tag"
}

VIDS_AVAIL="$(jqf "$STREAM_JSON" '.streams[] | select(.codec_type=="video") | .index' | tr '\n' ' ')"
AIDS_AVAIL="$(jqf "$STREAM_JSON" '.streams[] | select(.codec_type=="audio") | .index' | tr '\n' ' ')"
SIDS_AVAIL="$(jqf "$STREAM_JSON" '.streams[] | select(.codec_type=="subtitle") | .index' | tr '\n' ' ')"
if [[ -n "$VIDS" ]]; then WANT_V=" ${VIDS//,/ } "; else WANT_V=" $VIDS_AVAIL "; fi
if [[ -n "$AIDS" ]]; then WANT_A=" ${AIDS//,/ } "; else WANT_A=" $AIDS_AVAIL "; fi
if [[ -n "$SIDS" ]]; then WANT_S=" ${SIDS//,/ } "; else WANT_S=" $SIDS_AVAIL "; fi

# Video copy-set (SKILL.md §3): hevc Main/Main10 at <=10 bits and <=3840x2160,
# h264 at 8 bits only, mpeg2video, mpeg4, av1, vp8, vp9. WMV2 and everything
# else is re-encoded. LG OLED does not decode 10-bit H.264 (High 10 profile),
# so a 10-bit h264 stream must be re-encoded, never copied (TV-verified).
video_in_copyset() {
  local codec="$1" prof="$2" pix="$3" w="${4:-0}" h="${5:-0}" bps="${6:-0}" bits=8
  case "$codec" in
    h264)
      printf '%s' "$pix" | grep -q '10[lb]e' && return 1
      return 0 ;;
    mpeg2video|mpeg4|av1|vp8|vp9) return 0 ;;
    hevc)
      case "$prof" in Main|"Main 10"|"Main 10 Pro"|Main10*) ;; *) return 1 ;; esac
      [[ "$bps" =~ ^[0-9]+$ ]] && bits="$bps"
      printf '%s' "$pix" | grep -q '10[lb]e' && bits=10
      (( bits <= 10 )) || return 1
      # width and height have their own limits: 3840 wide, 2160 tall.
      (( w <= 3840 && h <= 2160 )) || return 1
      return 0
      ;;
    *) return 1 ;;   # outside the copy-set, always encode
  esac
}

# Video encode flags, verbatim from SKILL.md §2. Do not change the numbers.
# No -profile:v main, no -f mkv. No bitrate-from-source rule and no content
# presets: the target is "-b:v 0 -cq 10", the ceiling never engages at cq=10.
VENC=(hevc_nvenc -preset p4 -rc vbr -b:v 0 -cq 10 -maxrate 200M -bufsize 100M \
      -rc-lookahead 32 -spatial-aq 1 -temporal-aq 1 -aq-strength 12)

# Audio ladder (SKILL.md §3), returns "act|codec|ac|bitrate":
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

# Records are joined with US (0x1f), never "|": titles legitimately contain "|"
# ("Dublaj | Some Studio") and the fields would silently shift. (traps.md)
SEP=$'\x1f'
EXP_V=(); EXP_A=()
EXP_SUBS=0

FF=("$FFMPEG_BIN" -hide_banner -v info -y -i "$SRC_WIN")
log "in    $IN"
log "out   $OUT (matroska)"
log "mode  video=$VMODE audio=$AMODE sub-mode=$SUBMODE lang=${SUBLANG:-all}"

# POSV counts the mapped VIDEO streams and indexes -c:v:POSV. An unindexed -c:v
# applies to every video stream, so the last -c:v on the line wins and an encode
# decision silently overwrites a copy decision. One -c:v per stream, always.
POSV=0
for id in $WANT_V; do
  codec="$(smeta "$id" '.codec_name')"
  prof="$(smeta "$id" '.profile')"
  pix="$(smeta "$id" '.pix_fmt')"
  w="$(smeta "$id" '.width')"
  h="$(smeta "$id" '.height')"
  bps="$(smeta "$id" '.bits_per_raw_sample')"
  [[ -n "$codec" ]] || continue
  act=copy
  if [[ "$VMODE" == "encode" ]]; then act=encode
  elif ! video_in_copyset "$codec" "$prof" "$pix" "$w" "$h" "$bps"; then act=encode
  fi
  FF+=(-map "0:$id")
  if [[ "$act" == "copy" ]]; then
    FF+=(-c:v:"$POSV" copy)
    EXP_V+=("copy$SEP$codec")
    log "video $id: $codec ${prof:-?} ${w}x${h} -> copy (in copy-set)"
  else
    FF+=(-c:v:"$POSV" "${VENC[@]}")
    EXP_V+=("encode${SEP}hevc")
    log "video $id: $codec ${prof:-?} ${w}x${h} -> hevc_nvenc fixed set (p4, cq 10)"
  fi
  POSV=$((POSV+1))
done

# Stream-index rule: -c:a:N and -b:a:N address the N-th AUDIO stream of the
# output (media index = POSA), while -ac:N is the ABSOLUTE output-stream index in
# -map order (POSALL: every -map, video or audio, advances the counter). POSALL
# is seeded with POSV when the video loop closes, and both counters advance once
# per mapped audio stream; the copy arm advances POSALL too, because its -map
# consumes an absolute index.
POSALL="$POSV"
POSA=0
for id in $WANT_A; do
  codec="$(smeta "$id" '.codec_name')"
  ch="$(smeta "$id" '.channels')"; ch="${ch:-0}"
  prof="$(smeta "$id" '.profile')"
  [[ -n "$codec" ]] || continue
  plan="$(audio_plan "$codec" "$ch")"
  IFS='|' read -r act pcodec pac pbr <<< "$plan"
  FF+=(-map "0:$id")
  if [[ "$act" == "copy" ]]; then
    FF+=(-c:a:"$POSA" copy)
    EXP_A+=("copy$SEP$codec$SEP$ch")
    extra=""
    [[ "$codec" == "eac3" ]] && printf '%s' "$prof" | grep -qi atmos && extra=" (DD+ Atmos, 5.1 base copied)"
    log "audio $id: $codec ${ch}ch -> copy${extra}"
  else
    # -ac is indexed by the ABSOLUTE output-stream index, -c:a/-b:a by the audio
    # media index (see the rule above the loop).
    FF+=(-c:a:"$POSA" "$pcodec" -ac:"$POSALL" "$pac")
    [[ "$pbr" != "-" ]] && FF+=(-b:a:"$POSA" "$pbr")
    EXP_A+=("encode$SEP$pcodec$SEP$pac")
    log "audio $id: $codec ${ch}ch -> $pcodec ${pac}ch${pbr:+ $pbr}"
  fi
  POSA=$((POSA+1))
  POSALL=$((POSALL+1))
done

# "<base>.<lang>.srt" next to the output is the plan section 9.6 pattern; a second
# track with the same language cannot share one name, so it gets its disambiguator
# in the name (the same rule as subs.sh sidecar_path). The tag is the stream id for
# embedded streams and "ext<N>" for files from an external pack.
sidecar_out() {   # 2-letter lang, disambiguator tag
  local nl="$1" tag="$2" p
  p="$OUT_DIR/$OUT_BASE.$nl.srt"
  [[ -e "$p" ]] && p="$OUT_DIR/$OUT_BASE.$tag.$nl.srt"
  printf '%s' "$p"
}

# Sidecar export through ass-to-srt: convert.py writes "<stem>.srt" from the stem
# of its input, so the scratch .ass is named after the final sidecar stem and the
# result is exactly "<out name>.<2-letter lang>.srt" next to the output video. The
# EXTRACTION file carries the stream id, so two ASS streams of the same language
# never overwrite each other in scratch; the sidecar stem gains the id only when
# the plain "<base>.ru.srt" is already taken by an earlier stream. The function
# returns the status so the caller never logs a sidecar that was not written.
export_ass() {   # extracted .ass, disambiguator tag, stream language tag
  local src="$1" tag="$2" lang="$3" nl p ass
  nl="$(name_lang "$lang")"
  p="$(sidecar_out "$nl" "$tag")"
  ass="$WORK/$(basename "${p%.*}").ass"
  [[ "$src" == "$ass" ]] || cp "$src" "$ass"
  if python3 "$ASS2SRT/convert.py" --input "$ass" --out-dir "$OUT_DIR" > "$WORK/ass2srt.log" 2>&1; then
    log "ass-to-srt: wrote $p"
    return 0
  fi
  log "ass-to-srt FAILED for $src, sidecar NOT written"
  tail -5 "$WORK/ass2srt.log" >&2
  return 1
}

# Parse the language token from a Plex sidecar name "<base>.<lang>.<ext>".
# The extension itself is a 3-letter token, and counting it as a language made
# "movie.srt" come out as lang=srt. Strip the extension, then skip the known
# subtitle extensions among the remaining tokens, and accept only 2-3 lowercase
# letters as a language. (subs.sh sidecar_lang uses the same rule.)
sidecar_lang() {
  local name="$1" rel lang="und" tok
  rel="${name#"$IN_BASE."}"; rel="${rel%.*}"
  for tok in $(printf '%s' "$rel" | tr '.' ' '); do
    case "$tok" in srt|ass|ssa|sub|vtt) continue ;; esac
    [[ "$tok" =~ ^[a-z]{2,3}$ ]] && lang="$tok"
  done
  printf '%s' "$lang"
}

POSS=0
if [[ "$SUBMODE" == "none" ]]; then
  log "sub-mode none: all subtitle streams dropped"

elif [[ "$SUBMODE" == "sidecar" ]]; then
  # PGS is copied embedded only: ffmpeg cannot encode PGS and cannot write .sup,
  # and an external .sup is not picked up by Plex. Sidecar PGS is not a path.
  # (references/traps.md; SKILL.md §3)
  for id in $WANT_S; do
    codec="$(smeta "$id" '.codec_name')"
    lang="$(smeta "$id" '.tags.language')"; lang="${lang:-und}"
    [[ -n "$codec" ]] || continue
    case "$codec" in
      hdmv_pgs_subtitle)
        FF+=(-map "0:$id")
        POSS=$((POSS+1)); EXP_SUBS=$((EXP_SUBS+1))
        log "sub $id ($lang): PGS copied embedded only, never sidecar"
        ;;
      ass|ssa)
        lang_match "$SUBLANG" "$lang" || { log "sub $id ($lang) skipped by --lang"; continue; }
        FF+=(-map "0:$id")
        POSS=$((POSS+1)); EXP_SUBS=$((EXP_SUBS+1))
        ASS_OUT="$WORK/$OUT_BASE.$id.$lang.ass"
        # ffmpeg is a native Windows binary: the extraction output MUST be the
        # cygpath -m form, otherwise it writes to an unreadable /cygdrive path
        # and the sidecar is silently lost. (references/traps.md)
        # The stream id is in the extraction name: two ASS streams of the same
        # language share one scratch name without it, and the second extraction
        # overwrites the first.
        if "$FFMPEG_BIN" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" -c:s copy \
             "$(winpath "$ASS_OUT")" > "$WORK/ass-extract.log" 2>&1; then
          if export_ass "$ASS_OUT" "$id" "$lang"; then
            log "sub $id ($lang): $codec copied embedded + sidecar .srt via ass-to-srt"
          else
            log "sub $id ($lang): $codec copied embedded, sidecar NOT written"
          fi
        else
          log "sub $id ($lang): ASS extraction failed, sidecar NOT written"
          tail -5 "$WORK/ass-extract.log" >&2
        fi
        ;;
      subrip)
        lang_match "$SUBLANG" "$lang" || { log "sub $id ($lang) skipped by --lang"; continue; }
        FF+=(-map "0:$id")
        POSS=$((POSS+1)); EXP_SUBS=$((EXP_SUBS+1))
        log "sub $id ($lang): srt copied embedded"
        ;;
      *)
        log "sub $id ($lang): codec '$codec' unsupported, skipped"
        ;;
    esac
  done
  # External sidecars next to the source move next to the output. The name is
  # always the 2-letter code: an external pack "movie.ru.ass" must land as
  # "movie.ru.srt", not as a raw stream tag.
  EXT_TAG=0
  for f in "$IN_DIR"/"$IN_BASE".*; do
    case "$f" in *.srt|*.ass|*.ssa) ;; *) continue ;; esac
    [[ -f "$f" ]] || continue
    lang="$(sidecar_lang "$(basename "$f")")"
    lang_match "$SUBLANG" "$lang" || continue
    nl="$(name_lang "$lang")"
    tag="ext$EXT_TAG"
    EXT_TAG=$((EXT_TAG + 1))
    case "$f" in
      *.srt)
        p="$(sidecar_out "$nl" "$tag")"
        if cp "$f" "$p"; then
          log "sidecar: $p"
        else
          log "sidecar copy FAILED for $f, sidecar NOT written"
        fi
        ;;
      *.ass|*.ssa)
        export_ass "$f" "$tag" "$lang"
        ;;
    esac
  done
  # Subtitle streams copied as streams, not re-encoded: ffmpeg has no PGS
  # encoder, the stream is passed through.
  (( POSS > 0 )) && FF+=(-c:s copy)

else
  # burn: the subtitle stream is NOT in the output at all; the file is burned
  # into the video with -vf subtitles=. Zero transcode on the TV. Pick an
  # external sidecar first, then an embedded stream; fonts are looked up in the
  # subtitle's folder first, then in the system fonts.
  BURN_SUB=""; BURN_LANG="und"
  for f in "$IN_DIR"/"$IN_BASE".*; do
    case "$f" in *.srt|*.ass|*.ssa) ;; *) continue ;; esac
    [[ -f "$f" ]] || continue
    lang="$(sidecar_lang "$(basename "$f")")"
    lang_match "$SUBLANG" "$lang" || continue
    BURN_SUB="$f"; BURN_LANG="$lang"
    break
  done
  if [[ -z "$BURN_SUB" ]]; then
    for id in $WANT_S; do
      codec="$(smeta "$id" '.codec_name')"
      lang="$(smeta "$id" '.tags.language')"; lang="${lang:-und}"
      lang_match "$SUBLANG" "$lang" || continue
      case "$codec" in
        subrip) ext=srt ;;
        ass|ssa) ext=ass ;;
        hdmv_pgs_subtitle)
          log "sub $id ($lang): PGS cannot be burned (ffmpeg encodes no PGS), skipped"
          continue
          ;;
        *) continue ;;
      esac
      out="$WORK/$OUT_BASE.$lang.$ext"
      # Native ffmpeg needs the Windows form of the extraction output.
      "$FFMPEG_BIN" -hide_banner -v error -y -i "$SRC_WIN" -map "0:$id" \
        -c:s "$ext" "$(winpath "$out")" > "$WORK/burn-extract.log" 2>&1 \
        && { BURN_SUB="$out"; BURN_LANG="$lang"; break; } \
        || log "sub $id extraction for burn failed"
    done
  fi
  if [[ -n "$BURN_SUB" ]]; then
    BURN_WIN="$(winpath "$BURN_SUB")"
    SUBDIR="$(dirname "$BURN_SUB")"
    fonts=0
    for f in "$SUBDIR"/*.ttf "$SUBDIR"/*.otf "$SUBDIR"/*.ttc; do
      [[ -f "$f" ]] && fonts=1
    done
    fontdir="$SUBDIR"
    [[ $fonts -eq 1 ]] || fontdir="$WINFONTS"
    fontdir_win="$(winpath "$fontdir")"
    FF+=(-vf "subtitles=$(fesc "$BURN_WIN"):fontsdir=$(fesc "$fontdir_win")")
    log "burn-in: $(basename "$BURN_SUB") lang=$BURN_LANG, fonts dir: $fontdir"
    EXP_SUBS=0
  else
    log "sub-mode burn: no burnable subtitle found for lang=${SUBLANG:-any}"
  fi
fi

# One ffmpeg invocation, matroska, -avoid_negative_ts make_zero: 'make_window'
# is not a valid constant and the output file fails to open. (traps.md #1)
FF+=(-f matroska -avoid_negative_ts make_zero "$OUT_WIN")
FFLOG="$WORK/ffmpeg.log"

# A long encode prints a heartbeat every 20 s, otherwise the log looks frozen
# and a session reports a "stuck" script for a running ffmpeg. (traps.md)
run_logged() {
  local label="$1"; shift
  local start=$SECONDS rc=0 pid
  { "$@" > "$FFLOG" 2>&1; } &
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

log "running the single ffmpeg invocation"
run_logged "encode" "${FF[@]}"
RC=$?
if [[ $RC -ne 0 ]]; then
  tail -25 "$FFLOG" >&2
  rm -f "$OUT"
  die "ffmpeg failed rc=$RC, partial output deleted"
fi

# Verification by ffprobe: codecs and channel counts must match the ladder,
# duration within 1 s of the source. On failure delete the partial output.
OUT_JSON="$("$FFPROBE_BIN" -v error -show_streams -of json "$OUT_WIN" 2>/dev/null)"
OUT_FORMAT="$("$FFPROBE_BIN" -v error -show_format -of json "$OUT_WIN" 2>/dev/null)"
[[ -n "$OUT_JSON" ]] || { rm -f "$OUT"; die "output cannot be probed, deleted"; }
FAIL=""

D1="$(jqf "$FORMAT_JSON" '.format.duration // empty')"
D2="$(jqf "$OUT_FORMAT" '.format.duration // empty')"
if [[ -n "$D1" && -n "$D2" ]] && ! awk -v a="$D1" -v b="$D2" 'BEGIN { d=a-b; if (d<0) d=-d; exit (d>1) }'; then
  FAIL="duration ${D2}s vs source ${D1}s"
fi

VSEL='[.streams[] | select(.codec_type=="video")]'
i=0
for rec in "${EXP_V[@]}"; do
  IFS="$SEP" read -r act want <<< "$rec"
  got="$(jqf "$OUT_JSON" "$VSEL | .[$i].codec_name // empty")"
  if [[ "$got" != "$want" ]]; then
    FAIL="$FAIL video stream $i codec '$got' expected '$want'"
  fi
  i=$((i+1))
done

ASEL='[.streams[] | select(.codec_type=="audio")]'
i=0
for rec in "${EXP_A[@]}"; do
  IFS="$SEP" read -r act wantcodec wantch <<< "$rec"
  got="$(jqf "$OUT_JSON" "$ASEL | .[$i].codec_name // empty")"
  gotch="$(jqf "$OUT_JSON" "$ASEL | .[$i].channels // empty")"
  # In jq the number 0 is truthy: compare explicitly, never by truthiness.
  if [[ "$got" != "$wantcodec" ]]; then
    FAIL="$FAIL audio stream $i codec '$got' expected '$wantcodec'"
  fi
  if [[ -n "$wantch" && "$wantch" != "-" && "$gotch" != "$wantch" ]]; then
    FAIL="$FAIL audio stream $i channels '$gotch' expected '$wantch'"
  fi
  i=$((i+1))
done

SUBOUT="$(jqf "$OUT_JSON" '[.streams[] | select(.codec_type=="subtitle")] | length')"
if [[ "$SUBOUT" != "$EXP_SUBS" ]]; then
  FAIL="$FAIL subtitle streams $SUBOUT expected $EXP_SUBS"
fi

if [[ -n "$FAIL" ]]; then
  rm -f "$OUT"
  printf 'convert: VERIFY FAILED:%s\n' "$FAIL" >&2
  printf 'convert: partial output deleted\n' >&2
  exit 1
fi

SPEED="$(grep -o 'speed=[0-9.]*x' "$FFLOG" | tail -1)"
SIZE="$(stat -c%s "$OUT" 2>/dev/null || printf '0')"
V0="$(jqf "$OUT_JSON" "$VSEL | .[0].codec_name // empty")"
A0="$(jqf "$OUT_JSON" "$ASEL | .[0].codec_name // empty")"
log "verified: video ${V0:-none} ${#EXP_V[@]} stream(s), audio ${A0:-none} ${#EXP_A[@]} stream(s), subs $SUBOUT, duration ${D2:-?}s (source ${D1:-?}s)"
log "output: $OUT, $SIZE bytes, ${SPEED:-encode time not reported}"
printf 'convert: DONE %s\n' "$OUT"
exit 0
