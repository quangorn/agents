#!/usr/bin/env bash
# preflight.sh - check that everything dv2mp4.sh needs is available.
# Prints an install list for anything missing. Exits non-zero when unusable.
set -uo pipefail

MISSING=(); OPTIONAL=()

check_required() {
  local tool="$1" hint="$2"
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  OK      %-16s %s\n' "$tool" "$($tool --version 2>&1 | head -1)"
  else
    printf '  MISSING %-16s %s\n' "$tool" "$hint"
    MISSING+=("$tool")
  fi
}

printf 'dv2mp4 preflight\n\n'

check_required ffmpeg     "https://ffmpeg.org/download.html"
check_required ffprobe    "ships with ffmpeg"
check_required MP4Box     "GPAC: https://gpac.io - needs GPAC >= 2 for the dvp= option"
check_required dovi_tool  "https://github.com/quietvoid/dovi_tool/releases"
check_required mkvextract "MKVToolNix: https://mkvtoolnix.download"
check_required mkvmerge   "MKVToolNix: https://mkvtoolnix.download"
check_required mediainfo  "https://mediaarea.net/en/MediaInfo/Download"

printf '\noptional (only needed for features this script does not use):\n'
if command -v hdr10plus_tool >/dev/null 2>&1; then
  printf '  OK      %-16s %s\n' hdr10plus_tool "$(hdr10plus_tool --version 2>&1 | head -1)"
else
  printf '  absent  %-16s %s\n' hdr10plus_tool "only for HDR10+ (non-DV) sources"
  OPTIONAL+=("hdr10plus_tool")
fi
if command -v bc >/dev/null 2>&1; then
  printf '  OK      %-16s\n' bc
else
  printf '  absent  %-16s %s\n' bc "only for the HDR10+ metadata percentage check"
  OPTIONAL+=("bc")
fi

printf '\ntemp directory:\n'
TMPROOT="${DV2MP4_TMP:-$HOME/tmp}"
if mkdir -p "$TMPROOT" 2>/dev/null && [[ -w "$TMPROOT" ]]; then
  printf '  OK      %-16s %s\n' "~/tmp" "$(cd "$TMPROOT" && df -h . | tail -1 | awk '{print $2, "free:", $4}')"
else
  printf '  MISSING %-16s cannot create $TMPROOT\n' "~/tmp"
  MISSING+=("tmpdir")
fi

printf '\nshell: %s\n' "${BASH_VERSION:-unknown}"
printf 'cygpath: %s\n' "$(command -v cygpath || echo 'absent (needed to pass Windows paths to native tools)')"

if [[ ${#MISSING[@]} -gt 0 ]]; then
  printf '\nRESULT: unusable, install -> %s\n' "${MISSING[*]}"
  exit 1
fi
if [[ ${#OPTIONAL[@]} -gt 0 ]]; then
  printf '\nRESULT: usable (optional absent: %s)\n' "${OPTIONAL[*]}"
else
  printf '\nRESULT: usable\n'
fi
