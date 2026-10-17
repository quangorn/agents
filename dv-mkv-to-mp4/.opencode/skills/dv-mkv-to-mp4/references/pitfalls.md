# Pitfalls

Every item here was hit for real while building this skill on this machine
(Windows + Cygwin bash, ffmpeg 4.4, GPAC 26.03-DEV, dovi_tool 2.0.3,
MKVToolNix 74, mediainfo 22.12). Do not "simplify" any of them away.

## 1. GPAC renamed `dv-profile` to `dvp` and now demands a compatibility ID

The upstream dvmkv2mp4 script uses:

```
MP4Box -add BL_RPU.hevc:dv-profile=8
```

On GPAC 26 that prints `Deprecated option name, use :dvp= instead` and then
fails hard:

```
DV profile 8 must indicate a compatibility mode `hdr10`, `bt709` or `hlg2100`
Failure while setting DV profile: Bad Parameter
```

The fix is the `dvp` option with the compatibility ID appended after a dot:

```
MP4Box -add BL_RPU.hevc:dvp=8.1.hdr10:name=
```

The upstream README pins **MP4Box 1.0.1** for this reason. It turns out a modern
GPAC works fine, but only with the new syntax. Compatibility ID mapping:

| Base layer `color_transfer` | Compatibility ID |
|------------------------------|------------------|
| `smpte2084` (PQ)             | `hdr10` |
| `arib-std-b67` (HLG)         | `hlg2100` |
| `bt709`, `smpte170m`, `bt470bg` | `bt709` |

Profile 5 (`dvhe.05`) has no base layer compatibility ID at all and takes a bare
`dvp=5`.

**Never default an unreadable transfer value to `bt709`.** That exact mistake was
made here: a missing helper function left `color_transfer` empty, `bt709` was
chosen, and the script produced a plausible looking file with the wrong Dolby
Vision signalling. The script now dies instead.

## 2. mediainfo lies about Dolby Vision on remuxed files

On the original mkvmerge produced MKV, mediainfo correctly reports:

```
HDR format : Dolby Vision / SMPTE ST 2094 App 4, dvhe.08, BL+RPU, HDR10 compatible
```

After cutting the same file with `ffmpeg -c copy`, the RPU is still there but
mediainfo reports only:

```
HDR format : SMPTE ST 2094 App 4, Version 1, HDR10+ Profile B compatible
```

It also starts reporting the *original* full length `FrameCount 199980` and
`StreamSize 20340744317` on a 6 minute file, because it picks up the mkvmerge
`_STATISTICS_*` tags that `ffmpeg -map_metadata` copied. Re-muxing with mkvmerge
does not help, so it is the cut itself, not the muxer.

dovi_tool is authoritative and does not have this problem:

```bash
dovi_tool extract-rpu -i BL_RPU.hevc -o RPU.bin
dovi_tool info -i RPU.bin -f 0     # -> "dovi_profile": 8
```

Upstream dvmkv2mp4 decides whether to convert by grepping mediainfo for
`HDR format.*Dolby Vision`. That check is unreliable. Use dovi_tool.

## 3. `:name=` is needed or the track title becomes garbage

Without `:name=` in the `-add` argument, MP4Box writes the whole import string
into the track `hdlr` Name:

```
Title : hevc:dvp=8.1.hdr10@GPAC26.03-DEV-rev105-g8f39a1eb-master
```

Media servers such as Jellyfin and Emby show exactly that as the title.
`-itags trackID=1:Name=` does **not** clear it afterwards, the value has to be
suppressed at import time with `:name=` (or set to a real title).

## 4. Native Windows tools cannot use Cygwin paths

`ffmpeg.exe`, `MP4Box.exe`, `dovi_tool.exe`, `mkvextract.exe` are Windows
binaries. Given a Cygwin path they fail with `No such file or directory`:

```
ffmpeg ... -f hevc ~/tmp/dv2mp4.XXXX/BL_RPU.hevc
```

Use `cygpath -m` (`~/tmp/x` -> `D:/tmp/x`) for every argument passed to
a native tool. Bash builtins keep the Cygwin path. This applies to temp dirs too:
`mktemp -d` returns a Cygwin path that ffmpeg cannot write to.

## 5. Windows `jq.exe` emits CRLF

Every value read from jq arrives with a trailing `\r`. This silently corrupts
validation rather than erroring out:

```
"rus\r"        fails ^[a-z]{2,3}$      -> language shown as "und"
"448000\r"     fails ^[0-9]+$          -> bitrate shown as "unknown"
"subrip\r"     misses the case arms    -> exported as "unsupported"
```

Always pipe jq output through `tr -d '\r'`. The scripts centralise this in
`jqf()`.

## 6. In jq, the number `0` is truthy

```jq
if .disposition.forced then "1" else "0" end     # wrong: every track is "1"
if .disposition.forced == 1 then "1" else "0" end # right
```

Only `false` and `null` are falsy in jq.

## 7. `-show_entries` together with `-show_streams` drops fields

On ffmpeg 4.4, combining both makes ffprobe silently omit tags and some stream
fields, so `language` vanished and the subtitle table became useless. Use plain
`-show_streams -of json` and filter with jq.

## 8. `ffprobe -select_streams a:N` is NOT an absolute index

This is the most dangerous one, because it fails silently:

- `ffprobe -select_streams a -show_entries stream=index` prints **absolute**
  stream indexes (`1,2,3,4,5`).
- `ffprobe -select_streams a:1` is **relative to the audio type**.

Mixing them shifts every field by the number of preceding streams: audio track
`1` showed up as track `2`'s data, and one track read as empty. `ffmpeg -map 0:N`
*is* absolute, so extraction was right while metadata was wrong.

Fix used: read all stream metadata once into a JSON blob and look it up with
`select(.index==$idx)`. Never use `-select_streams a:ID` for metadata lookups.

## 9. `|` in track titles breaks `|`-delimited records

Titles such as `Дубляж | Some Studio` are extremely common in Russian
releases. Building records as `"$id|$lang|$title|$start|$codec"` splits the
title across fields, which produced a filename `1.rus.86|ac3` and this:

```
delay must be a signed integer (got  Some Studio), using 0
```

Use US (`0x1f`) as the delimiter. It is safe because `sanitize_name` already
strips `\000-\037`.

## 10. Output name derivation must respect token boundaries

Stripping `DV` naively turns `Some.Show.DVDRip` into `Some.Show.DRip`, and
turns `...Hybrid.DV.HDR10+ SomeGroup` into `...HybridSomeGroup`. The marker has to
sit on a separator boundary, and the substitution has to run twice because two
markers can be adjacent. See the `base=` block in `dv2mp4.sh`.

## 11. Tab separated parsing is unsafe for these tables

`while IFS=$'\t' read -r a b c` collapses runs of tabs, so empty fields (missing
title, missing language) shift everything to the right. Use JSON lines instead.

## 12. Verified working combination

For a Dolby Vision profile 8 single layer source on this machine:

```bash
ffmpeg -i in.mkv -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc BL_RPU.hevc
MP4Box -add "BL_RPU.hevc:dvp=8.1.hdr10:name=" -tmp ./tmp \
       -brand mp42isom -ab dby1 out.mp4
```

Result: `Major Brand mp42 - compatible brands: iso4 dby1 mp42`,
`vide:hvc1`, `DolbyVision version 1.0 profile 8 level 6 (RPU: 1, BL: 1, EL: 0,
Compatibility: 1)`, and the RPU extracted back out of the MP4 compares byte for
byte identical with the source. Playback confirmed on the user's TV showing
Dolby Vision rather than an HDR10 fallback.

Dolby's own `mp4muxer.exe` is installed at `C:\Program Files\mp4muxer\mp4muxer.exe`
and was kept as a fallback, but GPAC handled everything and the fallback never
had to be used.

## 13. The output file extension must follow the file that was written

The audio record carried the *source* codec, and the mux step used it to build
the file name:

```
-add D:/tmp/dv2mp4.XXXX/4.kor.truehd:sopt:gfreg=ffdmx
```

The TrueHD branch writes `4.kor.eac3` on disk, so MP4Box was pointed at a name
that does not exist:

```
[Importer] Cannot load filter for input file "D:/tmp/dv2mp4.XXXX/4.kor.truehd"
Error importing ...: Requested URL is not valid or cannot be found
```

The record must carry the *output* extension, not the source codec. This applies
to every re-encoding branch: flac and dts write `.ac3`, truehd and the rest
write `.eac3`.

## 14. AC-3 is capped at 640 kbit/s

AC-3 cannot carry more than 640 kbit/s, so "convert DTS to AC-3 at no less than
the DTS bitrate" is only satisfiable up to that cap. The rule implemented:

| Source DTS bitrate | AC-3 target |
|--------------------|-------------|
| unknown in the container | 640 kbit/s, with a note |
| below 640 kbit/s | the source bitrate, so nothing is lost |
| above 640 kbit/s | 640 kbit/s, with a warning that the source was higher |

A DTS-HD MA track at 1509 kbit/s therefore ends up at 640 kbit/s. The warning
matters: without it the result looks like a faithful conversion.

## 15. Verifying "the video was copied unchanged"

Comparing the extracted HEVC byte for byte against the source **fails**, and that
is expected. MP4Box moves the VPS/SPS/PPS into the sample description instead of
repeating them in band, so the first bytes differ:

```
a.hevc  00 00 00 01 40 01 0c 01 ...   (VPS in band)
b.hevc  00 00 00 01 4e 01 05 ...       (VPS only in the sample description)
```

The meaningful check is the decoded picture:

```bash
ffmpeg -i source.mkv -map 0:v:0 -f framemd5 a.md5
ffmpeg -i out.mp4   -map 0:v:0 -f framemd5 b.md5
diff a.md5 b.md5        # identical -> the video really is unchanged
```

For a Dolby Vision conversion, comparing the extracted RPU is the stronger
check, because the RPU is what carries the DV signalling.

## 16. `dovi_tool info` wants an RPU file, not a container and not a bitstream

This is the trap that produced a completely wrong conclusion in a real session:
the file was declared to have no Dolby Vision, while it actually had DV 8.1.

The calls that fail:

```bash
dovi_tool info -i "movie.mkv"      # Error: Input file probably too large
dovi_tool info -i "movie.hevc"     # Error: Found invalid RPU: ... Invalid RPU length: 7
```

`dovi_tool info` parses an **RPU file** (`RPU.bin`), the output of
`dovi_tool extract-rpu`. Pointing it at the MKV or at the raw HEVC elementary
stream makes it try to parse the whole bitstream as RPU data, and it reports a
misleading "invalid RPU" error. The correct chain:

```bash
dovi_tool extract-rpu -i BL_RPU.hevc -o RPU.bin
dovi_tool info -i RPU.bin -f 0      # -> "dovi_profile": 8
```

A third trap in the same tool: `dovi_tool info` prints `Parsing RPU file...` on
**stdout**, before the JSON. Feeding the raw output to jq gives
`jq: parse error: Invalid numeric literal at line 1, column 8`. Cut the output at
the first brace first, see `dovi_json()` in `dv2mp4.sh`.

Use `dv2mp4.sh --probe` instead of any hand rolled check. It does the correct
chain and reports the profile in about 20 seconds on a 22 GB source, because it
only reads the head of the video stream.

## 17. A hybrid release carries Dolby Vision and HDR10+ at the same time

`Hybrid DV HDR10+` in a release name means the HEVC stream carries both:

- the Dolby Vision RPU in SEI payload type **137**
- the HDR10+ dynamic metadata in SEI payload type **4**

A hand written NAL parser in the same session found the 137 payload with 24
bytes of RPU data and still concluded there was no Dolby Vision, because it had
decided that 137 was "picture tier" and that the 04 01 application identifier
belonged to HDR10+ only. Both signals are present in a hybrid release, the
Dolby Vision one does not replace the HDR10+ one.

The file name is not evidence either way, and neither is mediainfo. Only
`dovi_tool extract-rpu` plus `dovi_tool info` on the resulting RPU file, or
`dv2mp4.sh --probe`, settle it.

## 18. A long extraction must show progress

Reading the video of a 22 GB source takes minutes, during which the script
printed only two lines. That looked like a hang, and the session concluded the
script was "stuck on dovi_tool over 21 GB", which sent the whole investigation
down the wrong path.

`run_with_heartbeat()` in `dv2mp4.sh` now prints the elapsed time every 20
seconds while the video stream is being read:

```
dv2mp4: reading the video stream
dv2mp4: extracting the video stream, 20s elapsed
dv2mp4: extracting the video stream, 40s elapsed
```

## 19. Not needed on this machine

`hdr10plus_tool`, `bc`, `ionice`, `dotnet` and `PgsToSrt` are upstream
requirements. Only the HDR10+ (non DV) path and the PGS OCR path use them, so
none of them is required here. `preflight.sh` reports them as optional rather
than missing.
