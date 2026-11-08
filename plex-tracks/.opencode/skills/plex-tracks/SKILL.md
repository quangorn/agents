---
name: plex-tracks
description: Use when the user wants Plex to play a specific audio track or subtitle by default — «поменяй аудиодорожку», «субтитры по умолчанию», «включай японскую озвучку», «set default audio in Plex», «default subtitle for season 1». Lists tracks, applies changes per episode/season/show, verifies the write, and can roll back.
---

# Plex default audio & subtitle tracks

Everything is done by `scripts/plex_tracks.py` from the folder this file lives in.
Below, `<skill-dir>` is that folder and the script is `<skill-dir>/scripts/plex_tracks.py`.
Stdlib only, Python 3.8+, no third-party dependencies.

After the skill is installed the full path is
`~/.config/opencode/skills/plex-tracks/scripts/plex_tracks.py`, and on Windows the same
path is `%USERPROFILE%\.config\opencode\skills\plex-tracks\scripts\plex_tracks.py`.

## Config

Server/token come from `PLEX_URL`/`PLEX_TOKEN`, else `~/.config/opencode/plex.yaml` (`url:`, `token:`).
Ask the user for the token; never invent it or paste it back into chat.

- `PLEX_URL` must point at the PMS from this machine, e.g. `http://192.168.1.x:32400`
  (the script default `http://10.0.2.2:32400` only makes sense inside a VM).
- If the user has no token yet, tell them where to get it (Plex Web → any item → Get Info → View XML,
  `X-Plex-Token=`) and offer to store it in `~/.config/opencode/plex.yaml`.

## 1. Inspect first

```bash
python3 "<skill-dir>/scripts/plex_tracks.py" --show "Магическая битва" --season 1
```

Working example with the installed path:

```bash
python3 ~/.config/opencode/skills/plex-tracks/scripts/plex_tracks.py \
  --show "Магическая битва" --season 1
```

Prints every episode and all audio/subtitle streams; `ВЫБРАНО` marks the current default. Ambiguous title matches abort and ask for `--section`.

A film is one item: `--show "<movie title>"` with no `--season`. `--episode` is
ignored for a film (the warning says so) and applies only to shows.

## 2. Apply

Without `--apply` the run is a plan only (no writes). Save the JSON report so you can roll back:

```bash
python3 "<skill-dir>/scripts/plex_tracks.py" \
  --show "Магическая битва" --season 1 --audio ja --subtitle ru --subtitle-external \
  --apply --json > plex-jjk-s1.json
python3 "<skill-dir>/scripts/plex_tracks.py" --undo plex-jjk-s1.json
```

| flag | meaning |
|---|---|
| `--audio ja` | language: ISO code (`ja`, `ru`, `en`), Plex code (`jpn`) or a name («японский», `日本語`) |
| `--audio-codec flac` | prefer codec (flac/aac/ac3/eac3/dts/mp3) |
| `--audio-keyword AniFilm` | pick by track title (translation studio etc.) |
| `--audio-exclude dub` | drop tracks containing this in the title |
| `--subtitle ru` / `--subtitle none` | subtitle language, or disable subtitles |
| `--subtitle-external` | only sidecar `.srt/.ass` files next to the media |
| `--subtitle-keyword Crunchyroll` | pick a specific translation |
| `--allow-forced` | allow forced subtitle tracks (avoided by default) |
| `--episode 5,7` | only these episode numbers, `5-9` is a range (shows only) |
| `--limit N` | only the first N episodes — test before a bulk change |
| `--json` | machine-readable report |
| `--undo report.json` | restore the `before` ids recorded in a report |

## 3. Plex semantics (what to trust)

```
POST /library/parts/{partId}?audioStreamID={streamId}&allParts=1
```

- `streamType`: 1 video, 2 audio, 3 subtitles. `streamId` is the `<Stream id=...>`, not `index`.
- The write sets `selected="1"` **for the account owning the token** — that is the real player default. `default="1"` comes from the file's MKV flags and is untouched.
- There is no show- or season-level default: the script loops over episodes.
- An invalid `streamId` changes nothing: PMS 2025.x answers HTTP 400, an older PMS answered 200. A response code is never proof, so every write is re-read from `/library/metadata/{ratingKey}`. Report status `applied` = verified, `FAILED` = Plex did not confirm.
- Re-running is safe: episodes already correct show `unchanged`.

After `--apply`, report the summary: episodes changed, which track was chosen, any `FAILED` or ambiguous picks.

## 4. Ambiguity

When several tracks match (e.g. five Russian ASS subs), the script prefers: already-selected → file `default` → first in file order, and lists the candidates. Say which one was picked and offer `--audio-keyword` / `--subtitle-keyword` for an exact choice.

## 5. External .srt

The script can select sidecar subtitles Plex already found (they have `file` and no `index`). Placing a new file in the host media folder is out of scope here: tell the user the exact target name (`<media filename>.ru.srt`) and offer `ass-to-srt` for conversion. Details: `references/plex-track-semantics.md`.

## Rules that must not be broken

- Run `--show` before any change: never guess a stream id.
- A bulk change starts with `--limit 1`; only then the whole season.
- A per-episode override is `--episode 5,7`. `--limit N` is the first N episodes, never an episode selector.
- Save the `--json` report of every `--apply`, it is the only thing `--undo` can work from.
- Verify a write by reading the metadata back; a response code alone is not proof (PMS 2025.x answers 400 for an unknown stream id).
- The token never goes into chat, logs or reports.
