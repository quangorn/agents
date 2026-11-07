---
name: video-convert
description: Use when the user wants video files or a whole season of a series converted with ffmpeg for Plex and an LG OLED TV — «конвертни сериал», «пересохраните сезон в HEVC», «сделай MKV из этой папки», «конвертни фильм для Plex/TV», «сконвертируй сезон для телевизора», batch convert, remux a season. Fixed HEVC NVENC flag set (preset p4, cq 10, maxrate 200M/bufsize 100M), video copy-set (hevc Main/Main10 ≤10bit, h264 8-bit only, mpeg2/mpeg4, av1/vp8/vp9), audio ladder that copies ac3/eac3/aac/mp3/vorbis/opus/pcm/flac at ≤6 channels and downmixes anything over 6 channels to E-AC-3 5.1, DTS never copied; subtitles as ASS→SRT sidecar, burn-in with -vf subtitles=, or PGS kept embedded; Dolby Vision as a mode that outputs MP4 through dovi_tool; Plex library layout and refresh. Output is MKV (MP4 only for DV), sources are read-only, one ffmpeg process at a time.
---

# Video convert (batch)

Converts MKV / MP4 / TS sources into files that play on Plex and on an LG OLED
(webOS 6.5.3, Plex for LG 5.94.4) as **direct play**, laid out the way the Plex
scanner expects.

Everything is done by the scripts next to this file. Do not hand-write ffmpeg
command lines: the scripts encode every trap in `references/traps.md`.

Fixed decisions that are not up for renegotiation:

- the source is **read-only**: never delete, never overwrite, never rename
- **one ffmpeg process at a time**; GPU encodes are strictly sequential
- quality is the fixed flag set below, verbatim (`-b:v 0 -cq 10` at preset p4).
  There is no VMAF, PSNR or SSIM and no quality metric of any kind
- output is MKV. The single exception is Dolby Vision mode, which outputs MP4
- verification is ffprobe on the result plus the Plex Media Server log, not a
  quality metric

## Config

Machine-specific values come from the environment; the defaults are for this
machine and are overridable. All paths are Cygwin paths (`/cygdrive/...`); native
Windows binaries get `cygpath -m` versions inside the scripts.

| Variable | Default | Meaning |
|----------|---------|---------|
| `FFMPEG_BIN` | `/cygdrive/c/Program Files/ffmpeg/bin/ffmpeg.exe` | the NVENC ffmpeg build |
| `PLEX_URL` | `http://127.0.0.1:32400` | Plex Media Server on this machine |
| `PLEX_TOKEN_FILE` | `$USERPROFILE/AppData/Local/Plex Media Server/.LocalAdminToken` | 42-byte local admin token, works for `127.0.0.1:32400` |
| `SCRATCH` | `/cygdrive/d/tmp/cygwin/opencode` | intermediates and logs |
| `DV_TMP` | `$HOME/tmp` | temp directory, used only by `dv.sh` (DV mode) |
| `ASS2SRT` | installed `ass-to-srt` scripts dir | contains `ass2srt.py`, `convert.py` |

## Scripts

```
bash scripts/preflight.sh
bash scripts/probe.sh "<file.mkv>"          # markdown track table + DV flag + external-sub scan
bash scripts/convert.sh --in FILE --out OUT.mkv --video copy|encode --audio copy|encode \
                        --sub-mode none|burn|sidecar [--lang ru] [--video-ids IDS] [--audio-ids IDS] [--sub-ids IDS]
bash scripts/batch.sh --in-dir DIR --out-dir DIR --video copy|encode --audio copy|encode \
                      --sub-mode none|burn|sidecar [--lang ru] [--external DIR]
bash scripts/subs.sh --in FILE --out-dir DIR --lang ru --mode sidecar|burn [--external DIR|FILE] [--sub-ids IDS] [--export-sup]
bash scripts/dv.sh -i IN.mkv [-o OUT.mp4] [-a IDS] [-s IDS] [-l rus,eng] \
                   [--probe] [--title TEXT] [--tmp DIR]
```

Track ids passed to `--video-ids`, `--audio-ids`, `--sub-ids` (convert.sh) and `-a`/`-s` (dv.sh) are
**absolute stream indexes** — the ones `ffmpeg -map 0:ID` expects and the ones
`probe.sh` prints. Never renumber them. The output layout is per §1 of the plan:
serials in `serial_name/Season N/`, films flat, a multi-part film gets a catalog,
and file names follow the pattern of an already-indexed sample in the same
section so the scanner does not create duplicates.

## 1. Preflight

```bash
bash scripts/preflight.sh
```

Checks ffmpeg/ffprobe (the `FFMPEG_BIN` build, with a live NVENC encode),
mediainfo, mkvmerge, mkvextract, jq, python3, the ass-to-srt scripts, dovi_tool
and MP4Box, normalizes paths with `cygpath -m`, checks that the Plex token file
is readable and the Plex HTTP port answers, **and resolves the target folder by
the layout rule** when given `--in-dir` and `--out-dir`: an in-dir named
`Season N` maps to `OUT_DIR/Season N/` (films stay flat in the given `--out-dir`,
a multi-part film gets a catalog directory), film vs series and the collection
folder are matched through the Plex API, and preflight names the matching section
key, prints the naming sample of that section (an already indexed file of the same
section, so the scanner does not create duplicates) and the layout note. The
layout mode is read-only GETs, the token is never printed.

```bash
bash scripts/preflight.sh                                        # default checks
bash scripts/preflight.sh --in-dir "Season 1" --out-dir "<Out>" # + target folder
```

If preflight reports anything MISSING, show the user the list and stop. Do not
improvise around a missing tool.

## 2. Probe, show the table, ask

Run `probe.sh` on every file. It prints a markdown table of video / audio /
subtitle tracks: codec, profile, bit depth, resolution, bitrate, channels, Atmos
flag, language, embedded/sidecar, plus the Dolby Vision flag and a scan for
external subtitle files.

**Reproduce that table to the user and ask what to copy and what to re-encode.**
Use the `question` tool with the track ids as options. Never pick tracks
silently — the whole point of this step is that the user decides.

Defaults proposed to the user (verified matrix: `references/lg-oled-codecs.md`):

- video in the copy-set → copy; anything outside it → HEVC encode
- audio in the copy-set at ≤6 channels → copy; DTS, TrueHD, anything >6 channels →
  encode by the ladder
- source with Dolby Vision → DV mode, output MP4

**Input contract.** If the source was not given, ask (file, folder, series). If
the destination was not given, decide film vs series from context and resolve the
collection path through the Plex API (`references/plex-api.md`): sections list →
`/library/search?query=<title>` → `ratingKey` → `/library/metadata/<id>` →
`Part file="..."` → parent folder is the collection path. Never guess a
destination and never silently default to the source folder.

## 3. Subtitles (`.ass` is the common case)

- **Video is copied** (its codec is in the copy-set) → run the `ass-to-srt` skill
  (`ASS2SRT/convert.py`) and put the `.srt` next to the target video as a
  sidecar. This is the normal path.
- **Video is transcoded** → **ask the user, every time** (this is a closed
  decision):
  - **burn-in**: `-vf subtitles=`, fonts looked up next to the subtitle file,
    then in the system. Zero transcode on the TV, subtitles cannot be turned off.
    Costs 17.6x realtime on NVENC — effectively free.
  - **ASS → SRT sidecar**: subtitles stay switchable on the TV, the price is a
    subtitle-segmentation job in Plex.
- **PGS**: embedded only. ffmpeg cannot encode PGS and cannot write `.sup`; the
  export path is `mkvextract`. Sidecar `.sup` is not read by Plex.
- SRT: both embedded and sidecar are fine.
- The TV app's own "subtitle overlay" option **must not be used**: the client
  sends `subtitles=none`, the server logs `decision=ignore`, subtitles
  disappear. Do not offer it.
- `.ogg` sidecars are not indexed by Plex in a video collection — that is normal;
  check such files on the TV by hand.

## 4. Dolby Vision mode

Detection: `hevc` stream with DV metadata (`dv_playback` side data / RPU),
settled by `dv.sh --probe`, never by the file name and never by mediainfo.

- Output is **MP4, not MKV** — the only exception to "always MKV". ffmpeg copies
  the video and audio streams, `dovi_tool` handles the RPU, MP4Box writes the
  container.
- Audio follows the same ladder as everywhere else.
- Profiles 4, 5, 7 are ported and unverified on this hardware; profile 8 is
  verified. Say so when one of them looks wrong.
- A source with no DV layer is remuxed with the video copied unchanged, and the
  summary states explicitly that there was no Dolby Vision.
- Dolby Vision is a mode inside this skill; the `dv-mkv-to-mp4` skill is retired
  into it. Do not call that skill.

## 5. Convert

CLI contract, verbatim — this is the whole set of flags `batch.sh` accepts; the
copy/encode decisions come from the ladder, not from extra flags:

```bash
bash scripts/batch.sh --in-dir DIR --out-dir DIR --video copy|encode --audio copy|encode \
                      --sub-mode none|burn|sidecar [--lang ru] [--external DIR]
```

Example (a season folder):

```bash
bash scripts/batch.sh --in-dir "<Season 1>" --out-dir "<Out/Season 2>" \
     --video encode --audio encode --sub-mode sidecar --lang ru
```

One ffmpeg at a time. Video copy or the fixed HEVC set; audio by the ladder;
subtitles by the path chosen in §3. A source directory named `Season N` puts its
outputs in `OUT_DIR/Season N/`; films go flat into `--out-dir`. Batch resumes by
skipping files whose output already exists, and a failure leaves no partial file.

## 6. Verify, then refresh the library

1. `ffprobe` the result: codec, channel count and duration must match the plan.
2. Read `Plex Media Server.log` for the playback session: streams must go as a
   file (`Content-Length of ...`), and there must be no `Job running` beyond
   subtitle segmentation. A session that transcodes means the file is wrong.
3. `POST /library/sections/<key>/refresh` (key from the sections list), then
   confirm with `/library/search?query=…` that the new file has a `ratingKey`.
4. Report: where the files are, sizes, what was copied and what was re-encoded,
   and anything skipped (PGS, unsupported codec, missing font).

## Video: the fixed set

Copy-set: `hevc` (Main/Main10, ≤10 bits, ≤3840x2160), `h264` (**8-bit only**;
High10 never plays on the TV, verified), `mpeg2video`, `mpeg4`, `av1`, `vp8`,
`vp9`. Anything outside it → HEVC. WMV2 never played at
all (36 retries) → always re-encode.

Encode flags, verbatim. Do not change the numbers:

```
-c:v hevc_nvenc -preset p4 -rc vbr -b:v 0 -cq 10 -maxrate 200M -bufsize 100M -rc-lookahead 32 -spatial-aq 1 -temporal-aq 1 -aq-strength 12
```

Measured on this machine: p3 = 22.6x realtime at 28.51 Mbps, **p4 = 18.8x at
11.64 Mbps**, p5 = 15.9x at 16.31 Mbps, p6 = 8.32x at 16.05 Mbps. p5 buys
nothing measurable over p4; p3 pays 2–3x in bytes; p6 is the size of p5 at half
the speed. Lookahead costs ~0 speed; AQ at `cq=10` costs neither size nor speed;
the ceiling never engages at `cq=10`. Burn-in (`-vf subtitles=`) costs 17.6x
realtime, i.e. almost nothing.

The set above is the whole quality policy: `cq=10` at preset p4 is the target,
the size falls out of the encode, and no source-derived bitrate is added. Never
add `-profile:v main` and never `-f mkv` (use `matroska`).

## Audio ladder

1. **Copy-set at ≤6 channels**: `ac3`, `eac3`, `aac`, `mp3`, `vorbis`, `opus`,
   `pcm_s16le`, `flac` — all verified on the TV as direct play (stereo 11–16;
   ac3/eac3 also in 5.1).
2. **DD+ Atmos (E-AC-3 JOC) with a 5.1 base** → **copy** (file 32: sound present,
   channels correct as 5.1).
3. **Any codec with more than 6 channels** (`truehd`, `dts`, `eac3` 8ch, `aac`,
   `flac`, `pcm`, `vorbis`, `opus`…) → downmix to **E-AC-3 5.1**:
   `-c:a eac3 -ac 6 -b:a <bitrate>`. This rule is universal, not Atmos-specific;
   Atmos metadata is lost. DD+ Atmos 7.1 (file 26) and TrueHD + Atmos (file 25,
   no sound at all on the TV) both go through rule 3.
4. **`dts` / `DTS-HD` are not supported at all** → always re-encode: multichannel
   → rule 3, stereo → `-c:a pcm_s16le -ac 2`.
5. Codec outside the copy-set: stereo → **PCM16** (`-c:a pcm_s16le -ac 2`),
   multichannel up to 5.1 → E-AC-3 with the same channel count.

`-c:a truehd` and `-c:a dca` are experimental: they need `-strict -2`, and
without it ffmpeg returns rc=127 and leaves an empty file. Never produce them.

## Output layout

- series: every file goes into its directory in the form `serial_name/Season N/`
- films: flat into the film collection directory
- a film split into several parts/episodes → make a catalog directory for them
- file name: take the name of an already-indexed file in the same section as the
  sample, so the scanner does not create duplicates
- sidecar subtitles are named `<video filename>.<lang>.srt` next to the video

## Rules that must not be broken

- never write outside the session working directory and the resolved target
  folder without confirmation; scratch goes to `$SCRATCH`
- sources are read-only
- Dolby Vision → DV mode (MP4), not a HEVC re-encode
- the TV app's subtitle-overlay option is never used
- the Plex token is never printed into chat

## Reference

- `references/lg-oled-codecs.md` — the verified support matrix: video copy-set,
  audio ladder, subtitle table, Plex-log evidence.
- `references/plex-api.md` — token, sections, search, metadata, refresh, layout.
- `references/traps.md` — every trap found in real sessions. Read before touching
  any flag.
