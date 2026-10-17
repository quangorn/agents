# dv-mkv-to-mp4

An opencode skill that converts a Dolby Vision MKV into a Dolby Vision MP4 that
plays on LG OLED, Nvidia Shield and other Dolby Vision capable players.

The video is **never re-encoded**. The HEVC elementary stream is copied out of
the Matroska container verbatim, the Dolby Vision RPU stays inside it, and
GPAC's MP4Box muxes it back with the Dolby Vision signalling intact. The result
is bit exact, and a 4K source converts in roughly the time it takes to copy it.

On top of that the skill handles the parts that usually make a converted file
unpleasant to watch on a TV:

- it shows the audio and subtitle tracks and lets you pick which ones to keep
- it re-encodes FLAC and DTS to AC-3, because many TVs cannot decode them
- it exports subtitles as sidecar files next to the video, never inside it
- it copies the video unchanged and says so when the source has no Dolby Vision
  layer at all, instead of pretending it did a Dolby Vision conversion

## Requirements

| Tool | Why | Notes |
|------|-----|-------|
| `ffmpeg` / `ffprobe` | stream extraction and muxing | 4.4 or newer |
| `MP4Box` (GPAC) | the actual MP4 muxer | GPAC 2 or newer, see the note below |
| `dovi_tool` | Dolby Vision RPU detection | [quietvoid/dovi_tool](https://github.com/quietvoid/dovi_tool) |
| `mkvextract` | chapter extraction | MKVToolNix |
| `mediainfo` | output verification | MediaArea |
| `jq` | parsing ffprobe output | |

`bash scripts/preflight.sh` checks all of them and prints exactly what is
missing, so you never have to guess.

`hdr10plus_tool`, `bc`, `dotnet` and `PgsToSrt` are **not** needed. They belong
to the HDR10+ and PGS OCR workflows, which this skill does not implement.

### A note on MP4Box versions

The original project this workflow comes from pins MP4Box 1.0.1, because GPAC
changed the Dolby Vision option in version 2. The old `:dv-profile=8` syntax now
fails:

```
DV profile 8 must indicate a compatibility mode `hdr10`, `bt709` or `hlg2100`
Failure while setting DV profile: Bad Parameter
```

The current syntax is `:dvp=8.1.hdr10`, where the part after the dot is the base
layer compatibility ID. This skill derives that ID from the base layer transfer
characteristics, so it works with a current GPAC. MP4Box 1.0.1 is not required.

## Installation

As a skill, it needs to be in an opencode skills directory.

```bash
git clone git@github.com:quangorn/agents.git
bash agents/dv-mkv-to-mp4/install.sh
```

Or copy it by hand:

```bash
mkdir -p ~/.config/opencode/skills
cp -r agents/dv-mkv-to-mp4/.opencode/skills/dv-mkv-to-mp4 ~/.config/opencode/skills/
```

Or just open `agents/dv-mkv-to-mp4` in opencode and use it from the project
scope.

## Usage

Through opencode, ask for it in plain language:

> convert this mkv to a Dolby Vision mp4

The agent then follows the skill: preflight, show the track table, ask which
tracks to keep, ask where to put the result, convert, verify.

From the shell, the scripts work on their own:

```bash
# what is in the file, and does it have Dolby Vision?
bash scripts/list-tracks.sh "movie.mkv"
bash scripts/dv2mp4.sh -i "movie.mkv" --probe

# convert
bash scripts/dv2mp4.sh -i "movie.mkv" -o "movie.DV-MP4.mp4" -a 1,4,5 -s 6,7,8
```

### Options

| Option | Meaning |
|--------|---------|
| `-i, --input FILE` | source MKV, required |
| `-o, --output FILE` | output MP4. Optional: `<base>.DV-MP4.mp4` for a Dolby Vision source, `<base>.mp4` otherwise |
| `-a, --audio IDS` | audio track ids to keep, default all |
| `-s, --subs IDS` | subtitle ids to export as sidecars, default none. ASS is always exported |
| `-l, --langs LIST` | language filter, for example `rus,eng` |
| `--probe` | report whether the file has Dolby Vision, then exit |
| `--asm` | also write an `.asm.mkv` with the audio and subtitles, no video |
| `--remove-source` | delete the source after a successful conversion |
| `--keep` | keep the temp working directory |
| `--title TEXT` | title written into the MP4 |
| `--dvp VALUE` | force the GPAC Dolby Vision value, for example `8.1.hdr10` |
| `--tmp DIR` | where the temp directory goes, default `~/tmp` |

Track ids are **absolute stream indexes**, the same ones `ffmpeg -map 0:ID`
expects. The track table prints them.

## What the script does

1. **Preflight.** Checks that every tool is present.
2. **Extracts the video** as an annexb HEVC stream into a temp directory. The
   Dolby Vision RPU is already inside it for single layer profiles 4, 5 and 8.
   For profile 7 the enhancement layer is extracted as well and the RPU is
   injected into the base layer with `dovi_tool`.
3. **Detects Dolby Vision** with `dovi_tool extract-rpu` followed by
   `dovi_tool info`. mediainfo is deliberately not used for this, it stops
   reporting "Dolby Vision" on remuxed MKVs even when the RPU is intact.
4. **Converts the audio.** `ac3`, `eac3`, `aac` and `mp3` are copied untouched.
   `flac` becomes AC-3 at 640 kbit/s, the AC-3 maximum. `dts` becomes AC-3 at
   the source bitrate when that is under 640 kbit/s, otherwise at the 640 kbit/s
   maximum with a warning. `truehd` and the rest become E-AC-3 at 1024 kbit/s.
5. **Exports the subtitles** as sidecar files next to the video. `subrip`
   becomes `.srt`, ASS becomes `.ass` plus a derived `.srt`, PGS is exported as
   `.sup` with no OCR.
6. **Muxes the MP4** with the Dolby Vision profile and the `dby1` brand.
7. **Verifies the result.** The output must carry a `DolbyVision` box, or the
   script deletes it and fails. For a source without Dolby Vision the check is
   inverted: there must be no `DolbyVision` box.
8. **Cleans up.** Every intermediate file lives in a temp directory under
   `~/tmp` and is removed on exit, including when the script fails.

## Dolby Vision profiles

| Profile | Brand | Base layer compatibility | Status |
|---------|-------|--------------------------|--------|
| 8 | `dvhe.08` | hdr10, bt709 or hlg2100 | verified on real hardware |
| 7 | `dvhe.07` | HDR10 | ported from dvmkv2mp4, not verified here |
| 5 | `dvhe.05` | none | ported from dvmkv2mp4, not verified here |
| 4 | `dvhe.04` | SDR or HDR | ported from dvmkv2mp4, not verified here |

Pure HDR10+ without Dolby Vision is not converted into Dolby Vision here. A
source with no Dolby Vision layer is still remuxed, with the video copied
unchanged, and the summary says so.

## Documentation

- `references/pitfalls.md` documents the traps found while building this, with
  the wrong behaviour and the fix for each. Read it before changing anything
  that looks like a small detail.
- `SKILL.md` is the skill manifest and the workflow the agent follows.

## License

GPL-3.0, see [../../LICENSE](../../LICENSE) and [../../NOTICE.md](../../NOTICE.md).
