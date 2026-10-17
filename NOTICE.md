# Notices

## Third party components

### dvmkv2mp4

The conversion workflow in `dv-mkv-to-mp4` follows the approach introduced by
[gacopl/dvmkv2mp4](https://github.com/gacopl/dvmkv2mp4): extract the HEVC
elementary stream from the Matroska container, keep the Dolby Vision RPU inside
it, and mux the result with GPAC's MP4Box while signalling the Dolby Vision
profile.

That project states in its README that it is released under the GPLv3. The
scripts in this repository were written from scratch, but they reuse the same
idea and the same container level techniques, so this repository is licensed
under the GPL-3.0 as well and credits the original author.

### dovi_tool

Dolby Vision RPU extraction and inspection is done with
[dovi_tool](https://github.com/quietvoid/dovi_tool) by quietvoid. `dovi_tool` is
not included in this repository and is not modified by it.

### GPAC, FFmpeg, MKVToolNix, MediaInfo

Used as external command line tools at runtime. None of them are included in
this repository and none of them are modified by it.

## Dolby Vision and Dolby trademarks

Dolby Vision, Dolby Digital, Dolby Digital Plus, AC-3, E-AC-3, TrueHD, DTS,
FLAC and HDR10 are trademarks or registered trademarks of their respective
owners. This repository is not affiliated with, endorsed by or sponsored by
any of them. The names are used only to describe the formats the tooling
handles.
