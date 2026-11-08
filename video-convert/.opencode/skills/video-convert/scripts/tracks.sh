#!/usr/bin/env bash
# tracks.sh - the season-level view of audio and subtitle tracks, used to ask the
# user which tracks Plex must play by default BEFORE any conversion happens.
#
# It runs probe.sh --quiet on every media file of --in-dir (no markdown, no Dolby
# Vision slice), merges the machine-readable dumps with jq, and prints:
#   - the union of audio tracks with the number of episodes carrying each
#   - the union of subtitle tracks, same
#   - the files whose track set differs from the base signature (the most common
#     one) with what is extra and what is missing in them
# The merged JSON is written to --out-json; the language tag and title printed in
# the tables are what plex-tracks matches on (--audio ru --audio-keyword AniFilm),
# never an absolute stream index. (references/traps.md, plex-tracks rule)
set -uo pipefail

SCRATCH="${SCRATCH:-/cygdrive/d/tmp/cygwin/opencode}"
PROBE_SH="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/probe.sh"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Windows jq.exe appends \r to every value; strip it centrally. (references/traps.md)
# Native binaries need the cygpath -m form of every path they open: jq.exe cannot
# read /cygdrive/..., so the JSON files are opened through qj with OUT_JSON_WIN.
winpath() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
qj() { jq -r "$1" "$OUT_JSON_WIN" 2>/dev/null | tr -d '\r'; }

usage() {
  cat <<'USAGE'
Usage: tracks.sh --in-dir DIR [--out-json FILE]

Prints the audio and subtitle track union of every media file in DIR, with the
episode count per track, and the files whose track set diverges from the most
common one. The merged JSON goes to --out-json (default
$SCRATCH/tracks-<in-dir name>.json). Use it to ask the user the default-track
question before converting: one question for a series, its answer applies to every
episode; a film is asked per film.
USAGE
}

IN_DIR=""; OUT_JSON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-dir) IN_DIR="${2:-}"; shift 2 ;;
    --out-json) OUT_JSON="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n "$IN_DIR" && -d "$IN_DIR" ]] || { usage >&2; die "--in-dir DIR is required"; }
[[ -f "$PROBE_SH" ]] || die "probe.sh not found next to tracks.sh: $PROBE_SH"

IN_NAME="$(basename "$IN_DIR")"
[[ -n "$OUT_JSON" ]] || OUT_JSON="$SCRATCH/tracks-$IN_NAME.json"
mkdir -p "$(dirname "$OUT_JSON")" 2>/dev/null || die "cannot create the out-json directory"
WORK="$SCRATCH/tracks-work-$$"
mkdir -p "$WORK" 2>/dev/null || die "cannot create scratch work dir $WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FILES=()
while IFS= read -r f; do
  case "$f" in *.mkv|*.mp4|*.ts|*.m4v|*.mov) FILES+=("$f") ;; esac
done < <(ls -1 "$IN_DIR" 2>/dev/null | sed "s|^|$IN_DIR/|" | sort)
[[ ${#FILES[@]} -gt 0 ]] || die "no media files in $IN_DIR"

# One quiet probe per file: no markdown, no DV slice, just the track dump.
# The dump paths are collected in an array, NOT by globbing "$WORK"/*.json later:
# an unquoted glob expands "ep 01.json" into two words, and jq then opens a
# nonexistent "ep" plus "01.json" in the current directory. (file names with
# spaces are the normal case for series folders)
FAILED=()
DUMPS=()
for src in "${FILES[@]}"; do
  # Full basename, NOT the stem with the extension stripped: "ep 01.mkv" and
  # "ep 01.mp4" in one folder collide on "ep 01.json" and one dump overwrites
  # the other. (references/traps.md)
  base="$(basename "$src")"
  if ! bash "$PROBE_SH" "$src" --quiet --tracks-json "$WORK/$base.json" \
       > "$WORK/$base.probe.log" 2>&1; then
    FAILED+=("$src")
    printf 'tracks: probe FAILED for %s\n' "$src" >&2
    tail -3 "$WORK/$base.probe.log" >&2
  else
    [[ -s "$WORK/$base.json" ]] || { FAILED+=("$src"); printf 'tracks: empty track dump for %s\n' "$src" >&2; }
    DUMPS+=("$WORK/$base.json")
  fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  # A file that cannot be probed must not silently shrink the season: the union
  # would miss its tracks and the divergent list would be wrong.
  die "probe failed for ${#FAILED[@]} file(s) of $IN_DIR, see the lines above"
fi

# Merge: base signature = the most common track set; options are tracks grouped by
# language + title + codec + channels with the number of distinct files carrying
# them; divergent files are listed against the first file that has the base set.
JQ_PROG='
# key escapes "|" inside lang and title: a title like "Dub | AniFilm" must not be
# able to fake a field boundary, otherwise two different track sets can share one
# signature. gsub pattern is [|], never "|": a bare | in the regex matches the
# empty string. (references/traps.md)
def key: "\(.kind)|\((.lang // "und") | gsub("[|]"; "\\|"))|\((.title // "") | gsub("[|]"; "\\|"))";
def sig: (.tracks | map(key) | unique | join(" && "));
[ .[] | . + {sig: sig} ] as $files
| [ $files[] as $f | $f.tracks[] | . + {file: $f.file} ] as $all
# group_by(.sig) returns the file objects of each group, so the base signature is
# .sig of the biggest group and $ref is a file of that group. Taking .[0] of
# group_by(.) gave an ARRAY of signatures, $ref then matched nothing and jq said
# "Cannot iterate over null".
| ($files | group_by(.sig) | sort_by(-length) | .[0]) as $base_group
| ($base_group[0].sig) as $base
| $base_group[0] as $ref
| def opts($kind):
    [ $all[] | select(.kind == $kind) ]
    | group_by([(.lang // "und"), (.title // ""), (.codec // "?"), (.ch | tostring)])
    | map({lang: (.[0].lang // "und"), title: (.[0].title // ""), codec: (.[0].codec // "?"),
           ch: (.[0].ch // null), count: ([.[].file] | unique | length)})
    | sort_by(-(.count))
  ;
{ files: ($files | length),
  base_signature: $base,
  audio_options: opts("audio"),
  subtitle_options: opts("subtitle"),
  divergent: [ $files[] | select(.sig != $base) | {
      file: .file,
      extra:   ([ .tracks[] | key ] - [ $ref.tracks[] | key ]),
      missing: ([ $ref.tracks[] | key ] - [ .tracks[] | key ]) } ] }
'
# Windows jq.exe is a native binary: it cannot open /cygdrive/... paths, so every
# path handed to jq is the cygpath -m form. The bash redirect that writes
# $OUT_JSON stays a cygwin path, which is correct for bash. (references/traps.md)
WIN_DUMPS=()
for d in "${DUMPS[@]}"; do WIN_DUMPS+=("$(winpath "$d")"); done
jq -s "$JQ_PROG" "${WIN_DUMPS[@]}" > "$OUT_JSON" || die "jq merge failed, $OUT_JSON not written"
OUT_JSON_WIN="$(winpath "$OUT_JSON")"

N="$(qj '.files')"
NA="$(qj '[.audio_options[] | select(.count > 0)] | length')"
NS="$(qj '[.subtitle_options[] | select(.count > 0)] | length')"
ND="$(qj '.divergent | length')"

printf '## Tracks of `%s` — %s file(s)\n\n' "$IN_NAME" "${N:-0}"
printf '| kind | lang | title | codec | ch | episodes |\n'
printf '|------|------|-------|-------|----|----------|\n'
# Titles legitimately contain "|" ("Dub | AniFilm"), so the markdown columns are
# escaped: gsub writes \|, and \r is stripped because jq.exe prints CRLF.
qj '.audio_options[] | "| audio | \(.lang) | \(.title | gsub("[|]";"\\|")) | \(.codec) | \(.ch // "-") | \(.count) |"'
qj '.subtitle_options[] | "| sub | \(.lang) | \(.title | gsub("[|]";"\\|")) | \(.codec) | - | \(.count) |"'

printf '\nBase track set (the most common one): `%s`\n' "$(qj '.base_signature')"

if (( ND > 0 )); then
  printf '\nDivergent files (%s of %s) — re-ask the default question for exactly these,\n' "$ND" "${N:-0}"
  printf 'they get their own plex-tracks run with --episode:\n\n'
  printf '| file | extra tracks | missing tracks |\n'
  printf '|------|--------------|----------------|\n'
  qj '.divergent[] | "| \(.file) | \(.extra | join(", ") | gsub("[|]";"\\|")) | \(.missing | join(", ") | gsub("[|]";"\\|")) |"'
fi

printf '\nDefault-track decision (ask before converting, in one question call):\n'
if (( NA > 1 )); then
  printf '  audio: %s distinct tracks -> the user must pick the default audio\n' "$NA"
else
  printf '  audio: 1 track -> nothing to ask, the default is that track\n'
fi
if (( NS > 1 )); then
  printf '  subtitles: %s distinct tracks -> Plex has SUBTITLES OFF by default, so the\n' "$NS"
  printf '  question must offer "off" as an explicit option, not just the languages\n'
elif (( NS == 1 )); then
  printf '  subtitles: 1 track -> ask once: keep the Plex default (off) or make it the default\n'
else
  printf '  subtitles: none in the files -> nothing to ask\n'
fi
printf '  a subtitle exported as a sidecar (.ass -> .srt) loses its title tag, so a\n'
printf '  keyword match is unavailable for it: the default is picked by language only\n'
printf '  (plex-tracks --subtitle ru --subtitle-external).\n'
printf 'out-json: %s\n' "$OUT_JSON"
exit 0
