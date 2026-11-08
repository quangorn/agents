# plex-tracks

An opencode skill that makes Plex play the track you want by default: it sets
the default audio and subtitle for episodes, a season, or a whole show through
the Plex Media Server API. A run without `--apply` is a plan with no writes,
every write is verified by reading the metadata back, and a saved JSON report
can be rolled back with `--undo`.

The skill is what answers «поменяй аудиодорожку» or «субтитры по умолчанию»:
it lists every track of every episode, picks the one you asked for, applies it,
verifies it, and reports what changed.

## What it does

- **Real player defaults.** Plex has two ideas of "default": `default="1"`
  comes from the file's own MKV flags, `selected="1"` is the choice of the
  account. The player obeys `selected`, so the script writes exactly that,
  through `POST /library/parts/{partId}?audioStreamID=…&allParts=1`.
- **Plan first, write later.** Without `--apply` nothing is written; the run
  prints what would be chosen and what is already correct (`unchanged`), so a
  season can be inspected before anything is touched.
- **Verified writes only.** An invalid stream id returns HTTP 200 and changes
  nothing, so the script never trusts the response. After every write it
  re-reads `/library/metadata/{ratingKey}` and reports `applied` only when the
  target track really is selected, `FAILED` when Plex did not confirm.
- **Matching by language, codec or title.** `--audio ja`, `--audio-codec flac`,
  `--audio-keyword AniFilm`, `--audio-exclude dub`; the same set for subtitles,
  plus `--subtitle none` to switch subtitles off and `--subtitle-external` to
  take only sidecar `.srt/.ass` files.
- **Rollback.** A `--json` report records the `before` stream id of every
  episode; `--undo report.json` restores them.
- **Safe to re-run.** Episodes that are already right are reported as
  `unchanged` and are not written again.

There is no show-level or season-level default in Plex: the script loops over
episodes. `selected` is stored per user, so the effect is for the account whose
token is used.

## Requirements

| Tool | Why | Notes |
|------|-----|-------|
| `python3` | the script itself | Python 3.8+, standard library only, no pip packages |
| a Plex Media Server on the network | the API is the whole job | the token must belong to an account with library write access |

Nothing else: no ffmpeg, no third-party Python packages, no preflight script.

## Configuration

The server and token come from the environment, or from a config file:

| Source | Value |
|--------|-------|
| `PLEX_URL` | PMS url, e.g. `http://192.168.1.50:32400`. The script default `http://10.0.2.2:32400` only makes sense inside a VM, so set this on a real machine |
| `PLEX_TOKEN` | the Plex token |
| `PLEX_CONFIG` | path of the config file, checked first |
| `~/.config/opencode/plex.yaml` | `url:` and `token:` lines, the usual place |

A token can be read from Plex Web: any item → Get Info → View XML, the
`X-Plex-Token=` in the URLs. Never paste a token into chat, logs or reports.

## Installation

As a skill, it needs to be in an opencode skills directory.

```bash
git clone git@github.com:quangorn/agents.git
bash agents/plex-tracks/install.sh
```

This copies the skill into `~/.config/opencode/skills/plex-tracks` (on Windows,
under the native user profile, which is where opencode reads its config). The
skill is copied, not moved, so the repository keeps working as a clone. If the
target already exists, the script refuses and says so.

Or copy it by hand:

```bash
mkdir -p ~/.config/opencode/skills
cp -r agents/plex-tracks/.opencode/skills/plex-tracks ~/.config/opencode/skills/
```

Or just open `agents/plex-tracks` in opencode and use it from the project scope.

## Usage

Through opencode, ask in plain language:

> включи японскую озвучку и русские субтитры для первого сезона

The agent then follows the skill: inspect with `--show`, name the track it
picked, apply, verify, and report the summary.

From the shell, `scripts/plex_tracks.py` works on its own:

```bash
# inspect: every episode, every audio and subtitle stream, ВЫБРАНО marks the current default
python3 ~/.config/opencode/skills/plex-tracks/scripts/plex_tracks.py \
  --show "Магическая битва" --season 1

# plan a season change (no writes)
python3 .../plex_tracks.py --show "Магическая битва" --season 1 \
  --audio ja --subtitle ru --subtitle-external

# apply and keep the report for rollback
python3 .../plex_tracks.py --show "Магическая битва" --season 1 \
  --audio ja --subtitle ru --subtitle-external --apply --json > plex-s1.json

# roll back to what the report recorded
python3 .../plex_tracks.py --undo plex-s1.json

# test one episode before touching a whole season
python3 .../plex_tracks.py --show "Магическая битва" --season 1 \
  --audio ja --limit 1 --apply
```

### Options

| Option | Meaning |
|--------|---------|
| `--show TITLE` | show or movie title; not needed with `--undo` |
| `--season N` | season index (shows only); omitted = every season |
| `--section NAME` | limit the search to one library section; required when a title matches several entries |
| `--audio LANG` | audio language: ISO code (`ja`, `ru`, `en`), Plex code (`jpn`) or a name («японский», `日本語`) |
| `--audio-codec CODEC` | prefer a codec: `flac`, `aac`, `ac3`, `eac3`, `dts`, `mp3` |
| `--audio-keyword TEXT` | pick by track title, e.g. a translation studio |
| `--audio-exclude TEXT` | reject tracks whose title contains this |
| `--subtitle LANG` | subtitle language, or `none` / `off` to disable subtitles |
| `--subtitle-keyword TEXT` | pick a specific subtitle translation |
| `--subtitle-external` | only sidecar `.srt/.ass` files next to the media |
| `--allow-forced` | allow forced subtitle tracks (avoided by default) |
| `--limit N` | process only the first N episodes |
| `--apply` | write the changes; without it the run is a plan |
| `--json` | machine-readable report, the format `--undo` reads |
| `--undo REPORT.json` | restore the `before` ids recorded in a report |
| `--server URL` / `--token TOKEN` | override the configuration for one run |

Report statuses: `unchanged`, `change`, `applied`, `FAILED (write returned N)`,
`no match` (with the list of available tracks), `no tracks of this kind`,
`no media part`. When several tracks match, the script prefers already-selected,
then the file `default`, then file order, and lists every candidate as
`audio-ambiguous` / `subtitle-ambiguous`.

Exit codes: `0` on success; `1` when the title is not found, a title matches
several shows, the season does not exist, there is no token, or a Plex request
fails.

### External subtitles

Sidecar files Plex has already found (`.ru.srt` next to the media) are
selectable: they have a `file` attribute and no `index` in the XML. Placing a
new file into the media folder is outside this skill — name the target
`<media filename>.ru.srt` and use `ass-to-srt` to convert an ASS file.

## Documentation

- `references/plex-track-semantics.md` is the Plex reference: `default` vs
  `selected` vs `forced`, the endpoints, stream types, language codes, external
  subtitle tracks, and what Plex cannot do.
- `SKILL.md` is the skill manifest and the workflow the agent follows.

## Cross-reference

`ass-to-srt` produces the `.srt` sidecars this skill can select, and
`video-convert` lays out files so that Plex finds those sidecars.

## License

GPL-3.0, see [../../LICENSE](../../LICENSE) and [../../NOTICE.md](../../NOTICE.md).
