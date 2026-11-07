# ass-to-srt

An opencode skill that converts ASS/SSA subtitle files into SRT. One `.srt`
per `.ass`/`.ssa`; an archive in (`.zip` or `.7z`) gives an archive of the
same kind back, with the folder structure kept inside it.

The skill is what answers «переведи в srt» when a subtitle file is dropped
into the chat: it converts, checks the head and tail of the result, and
reports what was converted and what was dropped.

## What it does

- **Formatting is preserved.** Italic, bold, underline and colours from ASS
  inline tags become SRT markup (`<i>`, `<b>`, `<u>`, `<font color>`).
- **Cues are coloured by class.** An ordinary line of dialogue gets no tag
  and keeps the player's own colour; a line spoken over the picture is
  forced to `#FFFFFF`; a sign (titles, plates, on-screen text,
  typesetting) gets `#A9A9A9`. The class comes from the style name, the
  style alignment and the tags of the cue itself. An explicit colour
  written in the ASS text (`\1c`) always wins over the class colour.
- **Near-black colours are lifted.** Fansubs draw phone and note UIs as
  black text on a white background they also draw; an SRT has no
  background, so the black becomes unreadable on a TV. Colours below a
  brightness threshold are scaled up to a dark grey, keeping their hue.
- **Duplicate cues are fused.** A moving sign written as several legs of
  one path, and a shadowed sign written as two layers, collapse into one
  cue; the brighter rendering wins. The same words after a real pause stay
  separate.
- **Variants for players that strip markup.** `--variant plain` writes
  bare text with no tags at all; `--variant tags` writes formatting without
  the class colours; `--variant both` produces both files in one run. The
  default is `colors` (tags + class colours), verified on the author's
  LG OLED, where the tags render correctly.
- **No font size in SRT.** `<font size>` is not understood by TV players,
  so the script never writes it; size is a player setting.

Vector drawings (`\p1 … \p0`) are removed, karaoke keeps its full text
without per-syllable timing, and the encoding is detected
(`utf-8`, `utf-16`, `cp1251`, …) are visible in the `--json` report.

## Requirements

| Tool | Why | Notes |
|------|-----|-------|
| `python3` | the converter itself | standard library only, no pip packages |
| `7z` | only for `.7z` input | p7zip; `.zip` works on the standard library |

Nothing else. There is no preflight script: two tools to check by hand.
On cygwin the script prefers `/usr/bin/7z` over a Windows `7z.exe` found
on PATH, because the Windows build cannot parse `/cygdrive/...` paths.

## Installation

As a skill, it needs to be in an opencode skills directory.

```bash
git clone git@github.com:quangorn/agents.git
bash agents/ass-to-srt/install.sh
```

This copies the skill into `~/.config/opencode/skills/ass-to-srt` (on
Windows, under the native user profile, which is where opencode reads its
config). The skill is copied, not moved, so the repository keeps working
as a clone. If the target already exists, the script refuses and says so.

Or copy it by hand:

```bash
mkdir -p ~/.config/opencode/skills
cp -r agents/ass-to-srt/.opencode/skills/ass-to-srt ~/.config/opencode/skills/
```

Or just open `agents/ass-to-srt` in opencode and use it from the project
scope.

## Usage

Through opencode, drop the file into the chat and ask for SRT in plain
language:

> переведи этот ass в srt

The agent then follows the skill: convert, check the head and tail of the
result, name the output files, report the counts.

From the shell, the script works on its own. Run `scripts/convert.py` from
the directory of the skill:

```bash
# one .ass -> one .srt
python3 ~/.config/opencode/skills/ass-to-srt/scripts/convert.py \
  --input "movie.en.ass"

# several inputs, one run
python3 .../convert.py --input "a.ass" --input "b.ssa" --out-dir "out/"

# archive in, archive of the same kind out
python3 .../convert.py --input "subs.zip"
python3 .../convert.py --input "subs.7z"

# a player that strips markup: bare text, no tags
python3 .../convert.py --input "movie.ass" --variant plain

# both variants at once -> movie.colors.srt + movie.plain.srt
python3 .../convert.py --input "movie.ass" --variant both

# class colours tuned to your player
python3 .../convert.py --input "movie.ass" \
  --sign-color "#A9A9A9" --ontop-color "#FFFFFF"
```

### Options

| Option | Meaning |
|--------|---------|
| `--input FILE` | `.ass`, `.ssa`, `.zip` or `.7z`; repeatable |
| `--out-dir DIR` | where the result goes, default `./subtitle-output/<input name>/` |
| `--variant` | `colors` (default) \| `tags` \| `plain`; `both` = `colors,plain` |
| `--sign-color` / `--ontop-color` | class colours, `#RRGGBB`; `none` disables the tag |
| `--no-merge` | do not fuse duplicate cues |
| `--merge-tolerance MS` | gap that still counts as a duplicate, default 250 ms; `0` = exact touch only |
| `--min-brightness N` | lift colours darker than N to a dark grey, default 96; `0` disables |
| `--json` | structured report instead of human-readable lines |
| `--selftest` | run the built-in checks (74 of them) and exit |

Nothing outside `--out-dir` is written, so a file attached to a chat
message is treated as read-only.

### Return codes

| code | meaning |
|------|---------|
| 0 | everything converted |
| 1 | some files inside an archive were not converted (the report names them with `x`) |
| 2 | an input was not processed at all (no `7z`, no `.ass/.ssa` in the archive, file not found) |

### Cross-reference

The `video-convert` project calls this skill's `scripts/convert.py` to
make `.srt` sidecars from ASS subtitle streams, so the two stay in sync.

## Documentation

- `references/conversion-rules.md` is the full conversion reference: the
  tag table, the cue-class rules with the measured accuracy, the merge and
  brightness rules, name collisions, and a diagnostics section for the
  cases that look wrong.
- `SKILL.md` is the skill manifest and the workflow the agent follows.

## License

GPL-3.0, see [../../LICENSE](../../LICENSE) and [../../NOTICE.md](../../NOTICE.md).
