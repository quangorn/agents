# video-convert

An opencode skill that converts MKV / MP4 / TS sources into files that play on
Plex and on an LG OLED (webOS 6.5.3, Plex for LG 5.94.4) **without transcode**,
and puts them into the Plex library in the layout the scanner expects.

The source is only read. Output goes to the destination folder resolved by the
layout rules, and nothing in the source is ever deleted, renamed or overwritten.
One ffmpeg process runs at a time: GPU encodes are strictly sequential. There is
no VMAF, PSNR or SSIM here — quality is the fixed flag set that was measured on
this hardware, and verification is ffprobe plus the Plex logs.

On top of the raw transcode the skill:

- probes every file and shows you the track table, then lets **you** decide
  which tracks to copy and which to re-encode
- asks once per series (per film for a movie) which audio and subtitle Plex
  should play by default, **before anything is converted**, and writes that choice
  into the container flags; after the library scan the real Plex player default is
  written through the `plex-tracks` skill
- picks audio for TV playback by a fixed ladder, so DTS and TrueHD never end up
  in a file your TV cannot decode
- handles subtitles by one of three rules: ASS → SRT sidecar (via the
  `ass-to-srt` skill), burn-in with `-vf subtitles=`, or PGS kept inside the
  container
- converts Dolby Vision sources in the DV mode, where the output is an MP4
  muxed with `dovi_tool` and MP4Box, and the video bitstream is copied untouched
- takes the destination path and the file naming from the Plex library itself,
  so a rescan does not create duplicates

## Requirements

| Tool | Why | Notes |
|------|-----|-------|
| `ffmpeg` / `ffprobe` | probe, copy, encode | an NVENC build is required; preflight runs a live NVENC encode |
| `mediainfo` | source bitrate per stream | ffprobe does not report per-stream bitrate in Matroska |
| `mkvmerge` / `mkvextract` | container probing, track extraction | MKVToolNix |
| `jq` | parsing ffprobe output | Windows `jq.exe` emits CRLF, see `references/traps.md` |
| `python3` | driving the `ass-to-srt` conversion | standard library only |
| `dovi_tool` | Dolby Vision RPU detection and injection | [quietvoid/dovi_tool](https://github.com/quietvoid/dovi_tool) |
| `MP4Box` (GPAC) | the DV MP4 muxer | GPAC 2 or newer, for the `dvp=` option |

`bash scripts/preflight.sh` checks all of them and prints exactly what is
missing, so you never have to guess. If it reports anything missing, stop and
install it — do not improvise around a missing tool.

The ASS → SRT conversion is not implemented here. It is delegated to the separate
**ass-to-srt** skill, and the `ASS2SRT` variable points at its installed scripts
directory (`ass2srt.py`, `convert.py` inside). Install that skill first; preflight
reports it as missing when the path does not resolve.

Writing the Plex default tracks is delegated to the separate **plex-tracks** skill
(`PLEX_TRACKS` points at its scripts dir). It is an **optional** dependency: the
conversion runs without it, the files carry the container default flags, and the
final report says the Plex defaults were not applied. Preflight prints plex-tracks
as OPTIONAL, never as MISSING, so a missing plex-tracks never stops a run.

Plex does not index sidecar `.ogg` subtitles in a video collection — that is by
design, not a bug. Files with `.ogg` subtitles have to be checked on the TV by
hand.

## Installation

As a skill, it has to live in an opencode skills directory.

```bash
git clone git@github.com:quangorn/agents.git
bash agents/video-convert/install.sh
```

Or copy it by hand:

```bash
mkdir -p ~/.config/opencode/skills
cp -r agents/video-convert/.opencode/skills/video-convert ~/.config/opencode/skills/
```

Or open `agents/video-convert` in opencode and use the skill from the project
scope.

The scripts live inside the skill folder, so an installed copy is self-contained
at `~/.config/opencode/skills/video-convert/scripts/`.

## Usage

Through opencode, ask for it in plain language:

> конвертни сериал
>
> пересохраните сезон в HEVC
>
> сделай MKV из этой папки
>
> convert this season for Plex, keep the Russian audio
>
> включи японскую озвучку по умолчанию и русские субтитры для всего сезона

The agent then follows the skill: preflight, probe, show you the track table and
ask what to copy, ask which audio and subtitle Plex should play by default, ask
about the subtitle path, convert one file at a time, verify against the Plex logs,
refresh the library, write the Plex defaults through `plex-tracks`, and report.

From the shell, the scripts work on their own:

```bash
bash scripts/preflight.sh                       # every tool + a live NVENC encode
bash scripts/probe.sh "Season 1/episode 01.mkv" # markdown track table + DV flag + external-sub scan
bash scripts/tracks.sh --in-dir "Season 1"       # union of audio/subtitles per episode count,
                                                 # plus the files whose track set diverges

# one file: copy the video, encode the audio, subtitles as sidecar,
# the Plex defaults chosen by the user (language + keyword, never a stream id)
bash scripts/convert.sh --in "episode.mkv" --out "Out/episode.mkv" \
     --video copy --audio encode --sub-mode sidecar --lang ru \
     --default-audio ja --default-audio-keyword Crunchyroll --default-sub ru

# a whole season, sequentially, with the same default choice for every episode;
# --show / --season / --section run the plex-tracks step after the library refresh
bash scripts/batch.sh --in-dir "Season 1" --out-dir "Out/Season 2" \
     --video encode --audio encode --sub-mode sidecar --lang ru \
     --default-audio ja --default-audio-keyword Crunchyroll --default-sub ru \
     --show "Магическая битва" --season 2 --section Serials

# subtitles only
bash scripts/subs.sh --in "episode.mkv" --out-dir "Out" --lang ru \
     --mode sidecar --external "subs/Raws"

# Dolby Vision source
bash scripts/dv.sh -i "movie.mkv" --probe
bash scripts/dv.sh -i "movie.mkv" -o "movie.DV-MP4.mp4" -a 1,4 -s 6 -l rus,eng
```

Track ids passed to `--video-ids`, `--audio-ids`, `--sub-ids` (convert.sh) and `-a`/`-s` (dv.sh) are **absolute stream indexes**, the same ones
`ffmpeg -map 0:ID` expects, and the track table prints them. Never renumber them.

## What the skill does

1. **Preflight.** Tools, ffmpeg/ffprobe paths, `cygpath -m` normalization, the
   Plex token, the destination folder by the layout rule. Missing tools are
   reported as a list and the run stops.
2. **Probe.** ffprobe on every file: video codec / profile / bit depth /
   resolution / bitrate, audio codec / channels / bitrate, Atmos flag,
   subtitles (format, language, embedded or sidecar), Dolby Vision.
3. **The table and your choices.** The track table is reproduced to the user, and
   the `question` tool asks which tracks to copy, which to re-encode, which
   subtitle language, and which subtitle path. Video transcoded + subtitles
   present → the skill always asks: burn-in (`-vf subtitles=`) or ASS → SRT
   sidecar. Nothing is picked silently. The same `question` call also asks
   **which audio and which subtitle Plex should play by default** — one question
   per series (per film for a movie), answered once for the whole season, with
   "off" as an explicit subtitle answer because Plex keeps subtitles off.
   `tracks.sh` prints the union of tracks with the episode count, and lists the
   files whose set diverges: those get their own question and their own
   plex-tracks run with `--episode`.
4. **Convert.** One ffmpeg process at a time. Video: copy when its codec is in
   the copy-set, otherwise the fixed HEVC NVENC set. Audio: the ladder.
   Subtitles: the path you chose. Dolby Vision → DV mode, output MP4. The chosen
   default audio gets the container `default` flag, every other stream of that
   type has the flag cleared; subtitles never carry `default` unless you picked
   them.
5. **Verification.** ffprobe on the result (codec, channel count, duration
   matching, and the `default` disposition matching the choice) plus `Plex Media Server.log`: the streams are served as a file
   (`Content-Length of …`) and there is no `Job running` beyond subtitle
   segmentation.
6. **Library refresh.** `POST /library/sections/<key>/refresh`, then
   `/library/search?query=…` to confirm the new file got a `ratingKey`. The final
   summary lists the files converted, their sizes, and what was copied vs
   re-encoded.
7. **Plex defaults.** After the scan, through the `plex-tracks` skill: the real
   player default (`selected`) is written per episode, one episode first
   (`--limit 1`), then the season; every write is verified by reading the metadata
   back, and the `--json` report is saved for `--undo`. A sidecar subtitle can be
   selected only once Plex indexed it, so this step runs after the refresh.
   Without plex-tracks installed, the step is reported as skipped.

## Configuration

Machine-specific values are environment variables, not hardcoded paths. Every
default below is this machine; override them freely.

| Variable | Default | Meaning |
|----------|---------|---------|
| `FFMPEG_BIN` | `/cygdrive/c/Program Files/ffmpeg/bin/ffmpeg.exe` | the NVENC ffmpeg build |
| `PLEX_URL` | `http://127.0.0.1:32400` | the Plex Media Server on this machine |
| `PLEX_TOKEN_FILE` | `$USERPROFILE/AppData/Local/Plex Media Server/.LocalAdminToken` | the 42-byte local admin token |
| `SCRATCH` | `/cygdrive/d/tmp/cygwin/opencode` | intermediates and logs |
| `DV_TMP` | `$HOME/tmp` | temp directory for the DV mode |
| `ASS2SRT` | path to the installed `ass-to-srt` scripts dir | `ass2srt.py`, `convert.py` inside |
| `PLEX_TRACKS` | path to the installed `plex-tracks` scripts dir | `plex_tracks.py` inside, optional dependency |

## Dolby Vision profiles

DV is a mode inside this skill, not a separate skill. The output of DV mode is
**MP4**, the only exception to "the output is always MKV", because MP4 is the
container that carries Dolby Vision signalling to TV players.

| Profile | Brand | Base layer compatibility | Status |
|---------|-------|--------------------------|--------|
| 8 | `dvhe.08` | hdr10, bt709 or hlg2100 | verified on real hardware |
| 7 | `dvhe.07` | HDR10 | ported from dvmkv2mp4, not verified here |
| 5 | `dvhe.05` | none | ported from dvmkv2mp4, not verified here |
| 4 | `dvhe.04` | SDR or HDR | ported from dvmkv2mp4, not verified here |

The HEVC elementary stream is copied verbatim, `dovi_tool` detects and injects
the RPU, MP4Box writes the container. A source with no Dolby Vision layer is
remuxed with the video copied unchanged, and the summary says explicitly that
there was no DV.

## Documentation

- `references/plex-api.md` — the Plex API calls that resolve a destination and
  refresh the library.
- `references/traps.md` — the traps hit in real sessions, with the failing command
  and the fix for each. Read it before changing anything that looks like a small
  detail.
- `references/lg-oled-codecs.md` — the support matrix verified on the TV and in
  the Plex logs: the video copy-set, the audio ladder, the subtitle table.

The default audio and subtitle are written through the separate **plex-tracks**
skill (its `--limit 1` test run, `--json` report for `--undo`, `--episode` for the
episodes that differ). `ass-to-srt` makes the sidecar `.srt` files, `plex-tracks`
selects them.

## License

GPL-3.0, see [../../LICENSE](../../LICENSE) and [../../NOTICE.md](../../NOTICE.md).
