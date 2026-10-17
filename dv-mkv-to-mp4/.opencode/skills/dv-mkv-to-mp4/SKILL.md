---
name: Dolby Vision MKV to MP4
description: Convert Dolby Vision MKV (profiles 4, 5, 7, 8) to a Dolby Vision MP4 that plays on LG OLED, Nvidia Shield and other DV capable players, using ffmpeg, MP4Box and dovi_tool. Shows a table of audio and subtitle tracks and asks which ones to keep, and asks where to put the result. Flac and DTS are re-encoded to AC-3 for TV playback. A source without Dolby Vision is still remuxed with the video copied unchanged. Use when the user asks to convert a Dolby Vision / DV / HDR10+ mkv to mp4, make a DV mp4, remux a DV mkv, or when a DV mkv does not play on their TV. Also triggers on Russian requests such as "конвертни mkv в mp4 с Dolby Vision", "сделай DV mp4", "переделай видео в mp4".
---

# Dolby Vision MKV to MP4

Converts a Dolby Vision MKV into a Dolby Vision MP4 without touching the video
bitstream: the HEVC elementary stream is copied verbatim and the Dolby Vision RPU
stays inside it, so the result is bit exact and fast.

When the source has no Dolby Vision layer the video is still copied unchanged
into an MP4, no DV signalling is written, and the user is told there was no DV.

## When to use this skill

- The user has an MKV with Dolby Vision and wants an MP4 for a TV or media player.
- An MKV with DV does not play on their device, or plays as plain HDR10.
- The user wants to trim the track list of a DV MKV.

## Workflow

Do not improvise the ffmpeg/MP4Box commands yourself. Run the scripts, they
encode every trap listed in `references/pitfalls.md`.

All paths below are relative to this skill directory.

### 1. Preflight

```bash
bash scripts/preflight.sh
```

If it reports missing tools, show the user the list of what is missing and what to
install, and stop. Do not try to work around a missing tool.

### 2. Show the tracks and let the user choose

```bash
bash scripts/list-tracks.sh "<path to the mkv>"
```
It prints a markdown table of audio and subtitle tracks. **Reproduce that table
to the user and ask which track ids to keep.** Use the `question` tool with the
audio ids as options. Never pick the tracks silently, the whole point of this
step is that the user decides.

Note for the agent:

- Ids in that table are **absolute stream indexes** and are passed straight to
  `-a` and `-s`. Never renumber them.
- Audio: default to all, or let the user pick. Common choice is one 5.1 track
  per language.
- Subtitles: the user usually wants them all exported as sidecar `.srt` files.
  Pass the ids to `-s`.
- `-l rus,eng` filters by language and is an alternative to explicit ids.

### 2b. Check for Dolby Vision, when the user asks

If the user doubts whether the file has Dolby Vision, or asks why the video is
being copied rather than re-encoded, use the probe. It reads only the head of
the video stream, so it answers in well under a minute even for a 22 GB source:

```bash
bash scripts/dv2mp4.sh -i "<path to the mkv>" --probe
```

It prints `Dolby Vision YES` with the profile, or `Dolby Vision NO`, and it
removes its temp files on the way out.

**Never call `dovi_tool` yourself to check this.** `dovi_tool info` expects an
RPU file, not the MKV and not a raw HEVC stream. Pointing it at either of those
produces a misleading `Found invalid RPU` error that looks like the file has no
Dolby Vision, when in fact the RPU is right there. The script does the correct
chain, `extract-rpu` into `RPU.bin` and then `info` on that file.

Also remember that a file can be **both** Dolby Vision and HDR10+ at the same
time, which is what the `Hybrid DV HDR10+` releases are. The Dolby Vision RPU
lives in SEI payload type 137 and the HDR10+ metadata in payload type 4; both
are present in a hybrid release. The probe is the authority, not the file name
and not a hand written NAL parser.

### 3. Ask where the output should go

**If the user has not said where to put the result, ask explicitly before
converting.** Do not assume, do not silently default to the source folder. A
typical 4K Dolby Vision MKV is 20 to 60 GB, so the destination matters.

Offer sensible options with the `question` tool, for example the folder of the
source, an existing media or download folder, or a fresh folder. Only skip this
question when the user already named a destination.

### 4. Convert

```bash
bash scripts/dv2mp4.sh -i "<input.mkv>" -o "<output.mp4>" -a 1,4,5 -s 6,7,8
```

- Prefer passing `-o` explicitly, it is the destination the user just confirmed.
- Without `-o` the name is derived from the source: `DV`/`HDR10+` markers are
  stripped, a file with Dolby Vision becomes `<base>.DV-MP4.mp4` and a file
  without Dolby Vision becomes `<base>.mp4`.
- The script prints its own progress and a final summary, relay that summary.
- **Never pass `--remove-source` without explicit confirmation from the user.**
- The script deletes every intermediate file itself. Nothing is left in the
  folder, and the temp working directory under `~/tmp` is removed on exit, also
  when it fails.

### 5. Report the result

The script verifies its own output and fails loudly if a DV conversion did not
actually produce Dolby Vision, so a zero exit code means the MP4 carries a
`DolbyVision` box. Report the output path, size, the audio and subtitle counts,
and the `verified:` lines.

**If the summary says `DV NONE`, say so explicitly to the user**: the source had
no Dolby Vision layer, the video was copied unchanged, and the MP4 is a plain
HEVC file. Do not describe it as a Dolby Vision conversion.

When Dolby Vision is present, tell the user that the only check left is playing
it on their TV or player, and that they should look for a **Dolby Vision**
indicator and not plain **HDR10**.

## Options worth knowing

| Option | Meaning |
|--------|---------|
| `-a IDS` | audio track ids to keep, default all |
| `-s IDS` | subtitle ids to export as sidecars, default none. ASS/SSA is always exported regardless |
| `-l LIST` | language filter, e.g. `rus,eng` |
| `--probe` | only report whether the file has Dolby Vision, then exit |
| `--asm` | also write an `.asm.mkv` holding audio and subtitles, no video |
| `--keep` | keep the temp dir for debugging |
| `--title TEXT` | write a title into the MP4 |
| `--dvp VALUE` | force the GPAC Dolby Vision value, e.g. `8.1.hdr10` |
| `--tmp DIR` | where the temp dir goes, default `~/tmp` |

`bash scripts/dv2mp4.sh --help` lists them all.

## Behaviour the user should know about

- **Audio is chosen for TV playback.** Their set does not decode every format:

  | Source | Result |
  |--------|--------|
  | `ac3`, `eac3`, `aac`, `mp3` | copied untouched, native in MP4 and on TVs |
  | `flac` | re-encoded to **AC-3 640 kbit/s**, the AC-3 maximum, stereo stays stereo |
  | `dts` | re-encoded to **AC-3** at the source bitrate when it is under 640 kbit/s, otherwise at the 640 kbit/s maximum with a warning in the log |
  | `truehd`, anything else | re-encoded to E-AC-3 1024 kbit/s |

  AC-3 cannot exceed 640 kbit/s, so a DTS-HD MA source at 1509 kbit/s is capped.
  The script warns when that happens instead of pretending the loss is small.
- **Subtitles are never inside the MP4.** They are always written next to it as
  sidecar files, which is the most compatible option for TVs and media servers.
  `subrip` becomes `.srt`, PGS is exported as `.sup` with no OCR.
- **ASS/SSA tracks are always exported**, even when the user did not list them in
  `-s`, as both `.ass` and a derived `.srt`. The styled original carries fonts,
  colours and positioning that SRT cannot express, so it has to travel with the
  file. Say this to the user if it adds files they did not ask for.
- **Chapters** are carried over when the source has them.
- **Profile 8** is the only profile verified on real hardware here. Profiles 4,
  5 and 7 are ported from dvmkv2mp4 and are not verified. If a conversion of one
  of those profiles looks wrong, say so instead of claiming success.

## Reading the log

| Line | Meaning |
|------|---------|
| `Dolby Vision profile N` | detected from the RPU with dovi_tool |
| `reading the video stream` | the long step, a heartbeat prints the elapsed time every 20 s |
| `GPAC dvp=...` | the value handed to MP4Box, compatibility picked from the base layer |
| `audio N (FLAC ...) -> AC-3 640k` | an audio track was re-encoded for TV compatibility |
| `NO DOLBY VISION LAYER FOUND` | the source has no DV, the video is copied unchanged |
| `verified: DolbyVision version ...` | the `DolbyVision` box exists in the output |
| `verified: HEVC track present, no Dolby Vision` | a passthrough, as expected for a non-DV source |
| `ERROR: ...` | the conversion failed, the output was removed, nothing partial is left |

## Reference

`references/pitfalls.md` documents the environment specific traps: the GPAC
`dvp=` rename, mediainfo lying about DV, Windows paths for native tools, CRLF
from Windows `jq`, absolute vs relative stream indexes, and delimiter collisions
with `|` in track titles.
