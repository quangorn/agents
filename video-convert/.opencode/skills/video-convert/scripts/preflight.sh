#!/usr/bin/env bash
# preflight.sh - checks everything the video-convert scripts need.
# Prints OK/MISSING/absent lines and a RESULT line; exits 1 when any required
# piece is missing. Style mirrors dv-mkv-to-mp4/preflight.sh.
set -uo pipefail

# Machine defaults, all overridable through the environment.
FFMPEG_BIN="${FFMPEG_BIN:-/cygdrive/c/Program Files/ffmpeg/bin/ffmpeg.exe}"
FFPROBE_BIN="${FFPROBE_BIN:-$(dirname "$FFMPEG_BIN")/ffprobe.exe}"
PLEX_URL="${PLEX_URL:-http://127.0.0.1:32400}"
PLEX_TOKEN_FILE="${PLEX_TOKEN_FILE:-${USERPROFILE:-$HOME}/AppData/Local/Plex Media Server/.LocalAdminToken}"
SCRATCH="${SCRATCH:-/cygdrive/d/tmp/cygwin/opencode}"
ASS2SRT="${ASS2SRT:-$HOME/.config/opencode/skills/ass-to-srt/scripts}"
PLEX_TRACKS="${PLEX_TRACKS:-$HOME/.config/opencode/skills/plex-tracks/scripts}"

# Optional layout resolution mode (plan §1, SKILL.md §1): --in-dir DIR --out-dir DIR
# makes preflight resolve the target folder by the layout rule. Without arguments
# preflight behaves exactly as before.
IN_DIR=""; OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-dir) IN_DIR="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

MISSING=()

# ffmpeg.exe, curl.exe, mkvextract.exe, MP4Box.exe are native Windows binaries:
# they do not understand /cygdrive/... paths. Every path handed to a native
# tool is normalized with cygpath -m, and the closing quote after
# "$(cygpath -m ...)" is mandatory. (references/traps.md)
winpath() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

# Windows jq.exe appends \r to every value; strip centrally so validation never
# sees "rus\r" (fails ^[a-z]{2,3}$) or "448000\r" (fails numeric checks).
# (references/traps.md, "Windows jq.exe gives CRLF")
jqf() { printf '%s' "$1" | jq -r "$2" 2>/dev/null | tr -d '\r'; }

check_tool() {
  local tool="$1" hint="$2"
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  OK      %-16s %s\n' "$tool" "$(command -v "$tool")"
  else
    printf '  MISSING %-16s %s\n' "$tool" "$hint"
    MISSING+=("$tool")
  fi
}

printf 'video-convert preflight\n\n'

# ffmpeg/ffprobe are checked at FFMPEG_BIN, not in PATH: the skill needs the
# NVENC build specifically.
if [[ -f "$FFMPEG_BIN" ]]; then
  printf '  OK      %-16s %s\n' ffmpeg "$("$FFMPEG_BIN" -version 2>&1 | head -1)"
else
  printf '  MISSING %-16s %s (set FFMPEG_BIN to an NVENC build)\n' ffmpeg "$FFMPEG_BIN"
  MISSING+=("ffmpeg")
fi
if [[ -f "$FFPROBE_BIN" ]]; then
  printf '  OK      %-16s %s\n' ffprobe "$FFPROBE_BIN"
else
  printf '  MISSING %-16s %s\n' ffprobe "FFPROBE_BIN=$FFPROBE_BIN"
  MISSING+=("ffprobe")
fi

check_tool jq       "winget install jqlang.jq"
check_tool cygpath  "ships with Cygwin"
check_tool mkvmerge "MKVToolNix: https://mkvtoolnix.download"
check_tool mkvextract "MKVToolNix, the PGS export path (traps.md)"
check_tool python3  "Cygwin python3, runs the ass-to-srt scripts"
check_tool curl     "native curl.exe, reaches Plex on 127.0.0.1"
check_tool mediainfo "https://mediaarea.net - bitrate cross-check in probe.sh"
check_tool dovi_tool "https://github.com/quietvoid/dovi_tool - DV detection"
check_tool MP4Box   "GPAC: https://gpac.io, DV mode writes MP4"

# ass-to-srt scripts are needed for the subtitle sidecar mode.
if [[ -f "$ASS2SRT/ass2srt.py" && -f "$ASS2SRT/convert.py" ]]; then
  printf '  OK      %-16s %s\n' ass2srt "$ASS2SRT"
else
  printf '  MISSING %-16s install the ass-to-srt skill; ASS2SRT=%s\n' ass2srt "$ASS2SRT"
  MISSING+=("ass2srt")
fi

# plex-tracks is an OPTIONAL dependency: it writes the real Plex player default
# (selected) after the conversion and the library refresh. A missing plex-tracks
# does NOT stop the conversion: the files are written with their container flags,
# and the final report says the Plex defaults were not applied. It is reported as
# OPTIONAL, never added to MISSING. (SKILL.md §7)
PT_SH="$PLEX_TRACKS/plex_tracks.py"
if [[ -f "$PT_SH" ]]; then
  printf '  OK      %-16s %s\n' plex-tracks "$PT_SH"
else
  printf '  OPTIONAL %-16s install the plex-tracks skill; PLEX_TRACKS=%s\n' plex-tracks "$PLEX_TRACKS"
fi

# Scratch directory: intermediates, NVENC tests, batch logs. Created here.
mkdir -p "$SCRATCH" 2>/dev/null
if [[ -d "$SCRATCH" && -w "$SCRATCH" ]]; then
  printf '  OK      %-16s %s\n' scratch "$SCRATCH"
else
  printf '  MISSING %-16s SCRATCH=%s is not writable\n' scratch "$SCRATCH"
  MISSING+=("scratch")
fi

# Plex token: 42 bytes, never printed.
TOK=""
if [[ -r "$PLEX_TOKEN_FILE" ]]; then
  TOK="$(head -c 42 "$PLEX_TOKEN_FILE" | tr -d '\r\n')"
  if [[ ${#TOK} -ge 40 ]]; then
    printf '  OK      %-16s %s (%s bytes)\n' "plex token" "$PLEX_TOKEN_FILE" "${#TOK}"
  else
    printf '  MISSING %-16s token file is %s bytes\n' "plex token" "${#TOK}"
    TOK=""
    MISSING+=("plex token")
  fi
else
  printf '  MISSING %-16s %s not readable\n' "plex token" "$PLEX_TOKEN_FILE"
  MISSING+=("plex token")
fi

# Plex HTTP: GET /library/sections?X-Plex-Token=. curl.exe is native, so the
# -o path goes through cygpath -m. The token is never printed.
if [[ -n "$TOK" ]]; then
  SECTIONS_WIN="$(winpath "$SCRATCH/preflight-sections.xml")"
  CODE="$(curl -s -o "$SECTIONS_WIN" -w '%{http_code}' "$PLEX_URL/library/sections?X-Plex-Token=$TOK")"
  if [[ "$CODE" == "200" ]] && grep -q 'MediaContainer' "$SECTIONS_WIN" 2>/dev/null; then
    printf '  OK      %-16s %s\n' "plex url" "$PLEX_URL"
  else
    printf '  MISSING %-16s %s -> http %s\n' "plex url" "$PLEX_URL" "$CODE"
    MISSING+=("plex url")
  fi
fi

# Layout resolution (plan §1, SKILL.md §1): optional --in-dir DIR --out-dir DIR.
# Without the two flags nothing is printed here and preflight behaves exactly as
# before. READ-ONLY GETs, no POST, the token is never printed. The section lookup
# is the same awk prefix-match as batch.sh: one section can carry several
# <Location path="D:\..."> children, every one of them is a collection root, Plex
# XML writes backslashes in paths, so normalize them and prefix-match the in-dir.
if [[ -n "$IN_DIR" && -n "$OUT_DIR" ]]; then
  IN_NAME="$(basename "$IN_DIR")"
  SEASON=""
  IS_SERIES=0
  if [[ "$IN_NAME" =~ ^Season\ ([0-9]+)$ ]]; then
    IS_SERIES=1
    SEASON="${BASH_REMATCH[1]}"
  fi
  TARGET="$OUT_DIR"
  LAYOUT="film (flat collection folder; a multi-part film gets a catalog directory)"
  if (( IS_SERIES )); then
    LAYOUT="series (serial_name/Season N/)"
    TARGET="$OUT_DIR/Season $SEASON"
  fi
  IN_DIR_WIN="$(winpath "$IN_DIR")"
  KEY=""; TITLE=""; SAMPLE="none (no indexed section covers this directory)"
  if [[ -n "$TOK" ]]; then
    SEC_WIN="$(winpath "$SCRATCH/preflight-layout-sections.xml")"
    curl -s -o "$SEC_WIN" "$PLEX_URL/library/sections?X-Plex-Token=$TOK"
    HIT="$(awk -v want="$IN_DIR_WIN" 'BEGIN { RS="<Directory " } NR > 1 {
      k = ""; t = ""
      if (match($0, /key="[^"]*"/)) { k = substr($0, RSTART + 5, RLENGTH - 6) }
      if (match($0, /title="[^"]*"/)) { t = substr($0, RSTART + 7, RLENGTH - 8) }
      s = $0
      while (match(s, /path="[^"]*"/)) {
        p = substr(s, RSTART + 6, RLENGTH - 7)
        gsub(/\\+/, "/", p)
        if (k != "" && index(want, p) == 1) { print k "\t" t; exit }
        s = substr(s, RSTART + RLENGTH)
      }
    }' "$SCRATCH/preflight-layout-sections.xml" 2>/dev/null)"
    KEY="${HIT%%$'\t'*}"
    TITLE="${HIT#*$'\t'}"
    [[ "$TITLE" == "$HIT" ]] && TITLE=""
    if [[ -n "$KEY" ]]; then
      ALL_WIN="$(winpath "$SCRATCH/preflight-layout-all.xml")"
      curl -s -o "$ALL_WIN" "$PLEX_URL/library/sections/$KEY/all?X-Plex-Token=$TOK"
      F="$(sed -n 's/.*file="\([^"]*\)".*/\1/p' "$SCRATCH/preflight-layout-all.xml" | head -1)"
      [[ -n "$F" ]] && SAMPLE="$(basename "$F")"
    fi
  fi
  printf '\nLayout resolution (plan §1)\n\n'
  printf '  in-dir   %s\n' "$IN_DIR"
  printf '  out-dir  %s\n' "$OUT_DIR"
  printf '  layout   %s\n' "$LAYOUT"
  if [[ -n "$KEY" ]]; then
    printf '  section  key=%s title=%s covers the in-dir (Location prefix match)\n' "$KEY" "${TITLE:-?}"
    printf '  naming sample of the section (the pattern to follow): %s\n' "$SAMPLE"
  else
    printf '  section  none covers %s\n' "$IN_DIR"
    printf '  layout rule: films go flat into --out-dir, a multi-part film gets a catalog directory; names follow an already indexed sample of the same section\n'
  fi
  if (( IS_SERIES )); then
    printf '  target folder = %s (rule: in-dir basename is "Season %s" -> OUT_DIR/Season %s)\n' "$TARGET" "$SEASON" "$SEASON"
  else
    printf '  target folder = %s (flat film collection folder)\n' "$TARGET"
  fi
  printf '  layout note: the target folder is resolved by the layout rule here, never guessed; the section lookup is read-only GETs, the token is never printed\n'
elif [[ -n "$IN_DIR" || -n "$OUT_DIR" ]]; then
  printf '\nLayout resolution (plan §1)\n\n  MISSING both --in-dir and --out-dir are required to resolve the target folder\n'
fi

# Live NVENC encode: the fixed flag set from SKILL.md §2 on a 2 s color test
# source. rc=0 is not proof; the file must decode. Never -rc vbr_hq (gives
# "Error opening output files: Invalid argument") and never -profile:v main in
# MKV. (references/traps.md)
NVENC_FLAGS=(-c:v hevc_nvenc -preset p4 -rc vbr -b:v 0 -cq 10 -maxrate 200M \
  -bufsize 100M -rc-lookahead 32 -spatial-aq 1 -temporal-aq 1 -aq-strength 12)

nvenc_test() {   # $1=label $2=lavfi source $3=expected pix_fmt (empty = any)
  local label="$1" src="$2" want="$3" rc json got outwin
  outwin="$(winpath "$SCRATCH/preflight-nvenc-$label.mkv")"
  "$FFMPEG_BIN" -hide_banner -v error -y -f lavfi -i "$src" "${NVENC_FLAGS[@]}" \
    -f matroska "$outwin" >/dev/null 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    printf '  MISSING %-16s encode rc=%s\n' "$label" "$rc"
    MISSING+=("$label")
    return
  fi
  # The proof is decoding, not the exit code.
  "$FFMPEG_BIN" -hide_banner -v error -i "$outwin" -f null - >/dev/null 2>&1
  rc=$?
  json="$("$FFPROBE_BIN" -v error -show_streams -of json "$outwin" 2>/dev/null)"
  got="$(jqf "$json" '.streams[0].pix_fmt // empty')"
  if [[ $rc -ne 0 ]]; then
    printf '  MISSING %-16s the file does not decode\n' "$label"
    MISSING+=("$label")
  elif [[ "$(jqf "$json" '.streams[0].codec_name // empty')" != "hevc" ]]; then
    printf '  MISSING %-16s codec is not hevc\n' "$label"
    MISSING+=("$label")
  elif [[ -n "$want" && "$got" != "$want" ]]; then
    printf '  MISSING %-16s pix_fmt %s, expected %s\n' "$label" "${got:-?}" "$want"
    MISSING+=("$label")
  else
    printf '  OK      %-16s hevc_nvenc %s\n' "$label" "$got"
  fi
  rm -f "$SCRATCH/preflight-nvenc-$label.mkv"
}

if [[ -d "$SCRATCH" && -w "$SCRATCH" ]]; then
  nvenc_test "nvenc-8bit" "testsrc=duration=2:size=640x360:rate=25" ""
  nvenc_test "nvenc-10bit" "testsrc2=duration=2:size=640x360:rate=25,format=yuv420p10le" "yuv420p10le"
else
  printf '  MISSING %-16s scratch not writable, NVENC tests skipped\n' "nvenc tests"
  MISSING+=("nvenc tests")
fi

printf '\nshell: %s\n' "${BASH_VERSION:-unknown}"

if [[ ${#MISSING[@]} -gt 0 ]]; then
  printf '\nRESULT: unusable, install -> %s\n' "${MISSING[*]}"
  exit 1
fi
printf '\nRESULT: usable\n'
