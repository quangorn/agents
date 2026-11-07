#!/usr/bin/env python3
"""ASS/SSA -> SRT converter built on the Python standard library only.

Four text variants are supported:
  tags         - ASS inline styles become SRT HTML tags (<i>, <b>, <u>, <font color>)
  plain        - every override block is removed and only the readable text survives
  colors       - tags, plus a colour per cue class: a line of dialogue keeps the
                 player's own colour, a line spoken over the picture is forced
                 white, a sign is grey; an explicit ASS colour always wins

"colors" is the default: it is the "tags" rendering plus the class colours.

Public API:
    convert_bytes(data, variant="colors") -> Conversion
    convert_file(src, dst, variant="colors") -> Conversion
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

VARIANTS = ("tags", "plain", "colors")
CLASS_VARIANTS = ("colors",)
CLASS_DIALOGUE = "dialogue"
CLASS_ONTOP = "ontop"
CLASS_SIGN = "sign"

DEFAULT_FORMAT = (
    "layer", "start", "end", "style", "name",
    "marginl", "marginr", "marginv", "effect", "text",
)

NAMED_COLORS = {
    "white": "#FFFFFF", "black": "#000000", "red": "#FF0000", "green": "#00FF00",
    "blue": "#0000FF", "yellow": "#FFFF00", "cyan": "#00FFFF", "magenta": "#FF00FF",
    "gray": "#808080", "grey": "#808080", "silver": "#C0C0C0", "maroon": "#800000",
    "olive": "#808000", "lime": "#00FF00", "aqua": "#00FFFF", "teal": "#008080",
    "navy": "#000080", "fuchsia": "#FF00FF", "purple": "#800080", "orange": "#FFA500",
}

SECTION_RE = re.compile(r"^\s*\[([^\]]*)\]")
KEY_RE = re.compile(r"^\s*([A-Za-z]+)\s*:(.*)$")
TIME_RE = re.compile(r"^\s*(\d+):(\d{1,2}):(\d{1,2})(?:[.,:](\d{1,3}))?\s*$")
TAG_RE = re.compile(r"\{([^{}]*)\}")
DRAW_END_RE = re.compile(r"\\(?:p0|pe)\b")
DRAW_BLOCK_RE = re.compile(r"\{[^{}]*\\p[1-9][^{}]*\}[\s\S]*?(?=\{[^{}]*\\(?:p0|pe)\b|\Z)")
STRAY_TOGGLE_RE = re.compile(r"\\(?:[ibu][01]|r)")
SRT_TAG_RE = re.compile(r"</?[A-Za-z][^>]*>")
INDEX_COLOR_RE = re.compile(r"^(\d?c)(\d*)(.*)$", re.IGNORECASE)
TAG_NAME_RE = re.compile(r"^([A-Za-z]+)(\d*)(.*)$")

# Cue classes. A style name is the strongest hint, so a fansub can always be
# fixed by naming its styles; the fallbacks below cover the anonymous ones.
SIGN_STYLE_RE = re.compile(
    r"sign|typeset|telop|title|eyecatch|credit|karaoke|lyric|insert|notice|"
    r"caption|banner|preview|world-?line|fatima|reading|decor|onscreen|"
    r"on\s*screen|\bos\b|\bsong\b|\bnotes?\b"
)
ONTOP_STYLE_RE = re.compile(r"\btop\b|scroll|overlay")
SPEECH_STYLE_RE = re.compile(
    r"default|main|italic|flashback|dialog|speech|thought|whisper|shout|"
    r"narrat|talk|voice|subtitle"
)
POSITIONAL_RE = re.compile(r"\\(?:pos|move|org|fad|clip|t)\(|\\p[1-9]")
DRAW_START_RE = re.compile(r"\\p[1-9]")
TOP_ALIGN_RE = re.compile(r"\\an[789]")
POSITION_RE = re.compile(r"\\pos\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)")


# --------------------------------------------------------------------------- #
# data
# --------------------------------------------------------------------------- #

@dataclass
class Stats:
    dialogue: int = 0      # Dialogue lines seen
    converted: int = 0     # cues written
    empty: int = 0         # cues dropped because no readable text remained
    drawings: int = 0      # \p1 ... \p0 vector blocks removed
    karaoke: int = 0       # cues carrying \k/\kf/\ko/\kt timings
    malformed: int = 0     # unparsable time, short row, or empty text
    comments: int = 0      # Comment: lines ignored
    merged: int = 0        # cues fused into an earlier identical one
    floored: int = 0       # colours lifted out of near-black
    cues_dialogue: int = 0  # cues classified as plain dialogue
    cues_ontop: int = 0     # cues classified as speech over the picture
    cues_sign: int = 0      # cues classified as signs


@dataclass
class Conversion:
    srt: str
    stats: Stats
    encoding: str


@dataclass
class Style:
    name: str
    alignment: str = ""
    margin_v: str = ""
    primary: str = ""


@dataclass
class Document:
    rows: list[tuple[int, int, str, str]]   # start_ms, end_ms, text, style name
    styles: dict[str, Style]
    play_res: tuple[int, int] | None
    stats: Stats


@dataclass
class Palette:
    """Cue colours by class; None leaves the colour to the player.

    A sign has to read as clearly different from the player's white, so the grey
    sits about a third below it — #D3D3D3 looked like plain white on a TV.
    """
    ontop: str | None = "#FFFFFF"
    sign: str | None = "#A9A9A9"


# --------------------------------------------------------------------------- #
# decoding
# --------------------------------------------------------------------------- #

def decode_bytes(data: bytes) -> tuple[str, str]:
    """Decode subtitle bytes, returning (text, encoding label)."""
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8", "replace"), "utf-8-sig"
    if data.startswith(b"\xff\xfe") or data.startswith(b"\xfe\xff"):
        return data.decode("utf-16", "replace"), "utf-16"
    try:
        return data.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        pass
    guesses: list[str] = []
    try:
        import chardet  # optional, present on most Linux images
        detected = chardet.detect(data).get("encoding")
        if detected:
            guesses.append(detected)
    except Exception:
        pass
    for encoding in (*guesses, "cp1251", "cp1252", "latin-1"):
        try:
            return data.decode(encoding), encoding
        except (UnicodeDecodeError, LookupError):
            continue
    return data.decode("utf-8", "replace"), "utf-8-replace"


# --------------------------------------------------------------------------- #
# time
# --------------------------------------------------------------------------- #

def parse_time(value: str) -> int | None:
    """Parse an ASS timestamp into milliseconds, or None when unparsable."""
    match = TIME_RE.match(value)
    if match is None:
        return None
    hours, minutes, seconds = int(match.group(1)), int(match.group(2)), int(match.group(3))
    fraction = (match.group(4) or "").ljust(3, "0")
    return ((hours * 60 + minutes) * 60 + seconds) * 1000 + int(fraction)


def format_time(milliseconds: int) -> str:
    """Render milliseconds as an SRT timestamp."""
    milliseconds = max(0, milliseconds)
    hours, rest = divmod(milliseconds, 3_600_000)
    minutes, rest = divmod(rest, 60_000)
    seconds, millis = divmod(rest, 1000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{millis:03d}"


# --------------------------------------------------------------------------- #
# parsing
# --------------------------------------------------------------------------- #

def _parse_int(value: str, fallback: int = 0) -> int:
    try:
        return int(float(value.strip()))
    except (TypeError, ValueError):
        return fallback


def parse_document(text: str) -> Document:
    """Read PlayRes, [V4+ Styles] and the [Events] rows in one pass."""
    stats = Stats()
    styles: dict[str, Style] = {}
    play_res: tuple[int, int] | None = None
    rows: list[tuple[int, int, str, str]] = []
    columns: list[str] | None = None
    style_columns: list[str] | None = None
    section = ""
    for line in text.splitlines():
        if not line.strip():
            continue
        heading = SECTION_RE.match(line)
        if heading is not None:
            section = heading.group(1).strip().lower()
            continue
        entry = KEY_RE.match(line)
        if entry is None:
            continue
        key, value = entry.group(1).lower(), entry.group(2)

        if section == "script info":
            if key == "playresx":
                play_res = (_parse_int(value), play_res[1] if play_res else 0)
            elif key == "playresy":
                play_res = (play_res[0] if play_res else 0, _parse_int(value))
            continue

        if section in ("v4+ styles", "v4 styles"):
            if key == "format":
                style_columns = [column.strip().lower() for column in value.split(",")]
            elif key == "style" and style_columns:
                parts = value.split(",", len(style_columns) - 1)
                row = dict(zip(style_columns, (part.strip() for part in parts)))
                name = row.get("name", "")
                if name:
                    styles[name] = Style(
                        name=name,
                        alignment=row.get("alignment", ""),
                        margin_v=row.get("marginv", ""),
                        primary=row.get("primarycolour", ""),
                    )
            continue

        if section != "events":
            continue
        if key == "format":
            columns = [column.strip().lower() for column in value.split(",")]
            continue
        if key in ("comment", "picture", "sound", "movie", "command"):
            if key == "comment":
                stats.comments += 1
            continue
        if key != "dialogue":
            continue
        stats.dialogue += 1
        expected = columns or list(DEFAULT_FORMAT)
        parts = value.split(",", len(expected) - 1)
        if len(parts) < len(expected):
            stats.malformed += 1
            continue
        row = dict(zip(expected, (part.strip() for part in parts)))
        start = parse_time(row.get("start", ""))
        end = parse_time(row.get("end", ""))
        if start is None or end is None or end <= start:
            stats.malformed += 1
            continue
        rows.append((start, end, row.get("text", ""), row.get("style", "")))
    if play_res is not None and (play_res[0] <= 0 or play_res[1] <= 0):
        play_res = None
    rows.sort(key=lambda row: row[0])
    return Document(rows=rows, styles=styles, play_res=play_res, stats=stats)


# --------------------------------------------------------------------------- #
# inline styling
# --------------------------------------------------------------------------- #

def _unescapes(chunk: str) -> str:
    return chunk.replace("\\N", "\n").replace("\\n", "\n").replace("\\h", " ")


def _plain_text(chunk: str) -> str:
    """Escape readable text, dropping stray style toggles that lost their braces."""
    return html.escape(_unescapes(STRAY_TOGGLE_RE.sub("", chunk)), quote=False)


EMPTY_FONT_RE = re.compile(r'<font color="#[0-9A-Fa-f]{6}"></font>')
EMPTY_STYLE_RE = re.compile(r"<([ibu])></\1>")


def _drop_empty_tags(rendered: str) -> str:
    """Remove style pairs that wrap no text, e.g. two colours set in a row."""
    while True:
        cleaned = EMPTY_STYLE_RE.sub("", EMPTY_FONT_RE.sub("", rendered))
        if cleaned == rendered:
            return rendered
        rendered = cleaned


def _color(raw: str) -> str | None:
    """Map an ASS colour literal or name to #RRGGBB (ASS stores BGR)."""
    cleaned = raw.replace("&H", "").replace("&h", "").replace("&", "").strip()
    if not cleaned:
        return None
    if re.fullmatch(r"[0-9A-Fa-f]{1,6}", cleaned):
        digits = cleaned.zfill(6)
        return f"#{digits[4:6]}{digits[2:4]}{digits[0:2]}".upper()
    return NAMED_COLORS.get(cleaned.lower())


def _split_tag_body(body: str) -> list[str]:
    if body.startswith("\\"):
        return body.split("\\")[1:]
    return [body]


def render_cue_text(raw: str, variant: str) -> tuple[str, int, bool]:
    """Return (srt text, drawings removed, karaoke seen) for one Dialogue row."""
    if variant == "plain":
        drawings = len(DRAW_BLOCK_RE.findall(raw))
        stripped = TAG_RE.sub("", DRAW_BLOCK_RE.sub("", raw))
        return _plain_text(stripped).strip(), drawings, False

    out: list[str] = []
    stack: list[str] = []
    drawings = 0
    karaoke = False
    drawing = False
    position = 0

    def open_tag(name: str) -> None:
        if name in stack:
            return
        out.append(f"<{name}>")
        stack.append(name)

    def close_top(name: str) -> None:
        while stack:
            tag = stack.pop()
            out.append(f"</{tag}>")
            if tag == name:
                break

    for match in TAG_RE.finditer(raw):
        body = match.group(1)
        if drawing:
            position = match.end()
            if DRAW_END_RE.search(body):
                drawing = False
            continue
        chunk = raw[position:match.start()]
        if chunk:
            out.append(_plain_text(chunk))
        position = match.end()

        for token in _split_tag_body(body):
            if not token:
                continue
            indexed = INDEX_COLOR_RE.match(token)
            if indexed is not None and (indexed.group(1)[0].isdigit() or indexed.group(1) == "c"):
                name, value, rest = indexed.group(1).lower(), indexed.group(2), indexed.group(3)
                if name in ("c", "1c"):
                    color = _color(rest or value)
                    if color is not None:
                        close_top("font")
                        out.append(f'<font color="{color}">')
                        stack.append("font")
                continue
            named = TAG_NAME_RE.match(token)
            if named is None:
                continue
            name, value, rest = named.group(1).lower(), named.group(2), named.group(3)
            if name in ("i", "b", "u"):
                if value and value != "0":
                    open_tag(name)
                else:
                    close_top(name)
            elif name == "r":
                while stack:
                    out.append(f"</{stack.pop()}>")
            elif name == "p":
                drawing = value != "0" and value != ""
                drawings += 1 if drawing else 0
            elif name == "pb":
                drawing = True
                drawings += 1
            elif name == "pe":
                drawing = False
            elif name in ("k", "kf", "ko", "kt"):
                karaoke = True

    if not drawing:
        tail = raw[position:]
        if tail:
            out.append(_plain_text(tail))
    while stack:
        out.append(f"</{stack.pop()}>")
    return _drop_empty_tags("".join(out).strip()), drawings, karaoke


# --------------------------------------------------------------------------- #
# cue classes
# --------------------------------------------------------------------------- #

HEX_COLOUR_RE = re.compile(r"#[0-9A-Fa-f]{6}")



def parse_colour(raw: str) -> str | None:
    """`#RRGGBB`, or None when the class colour must not be set at all."""
    value = raw.strip()
    if value.lower() in ("", "none", "off"):
        return None
    if not HEX_COLOUR_RE.fullmatch(value):
        raise ValueError(raw)
    return value.upper()


def positional_evidence(rows: list[tuple[int, int, str, str]]) -> dict[str, float]:
    """Share of each style's cues that carry placement, animation or drawing.

    Dialogue is written with the style's own margins, so it stays near zero;
    typeset signs are placed, animated or drawn almost every time.
    """
    counts: dict[str, list[int]] = {}
    for _, _, raw, style in rows:
        bucket = counts.setdefault(style, [0, 0])
        bucket[0] += 1
        if POSITIONAL_RE.search(raw):
            bucket[1] += 1
    return {style: seen / total for style, (total, seen) in counts.items() if total}


def classify_style(name: str, style: Style | None, evidence: float) -> str:
    """Guess whether a style carries signs, over-frame speech, or plain dialogue."""
    lowered = name.lower()
    if SIGN_STYLE_RE.search(lowered):
        return CLASS_SIGN
    if ONTOP_STYLE_RE.search(lowered):
        return CLASS_ONTOP
    if SPEECH_STYLE_RE.search(lowered):
        return CLASS_DIALOGUE
    alignment = (style.alignment if style else "").strip()
    if alignment in ("7", "8", "9") and evidence < 0.5:
        return CLASS_ONTOP
    return CLASS_SIGN if evidence >= 0.5 else CLASS_DIALOGUE


def over_frame(raw: str, play_res: tuple[int, int] | None) -> bool:
    """True when the cue itself asks to sit above the bottom band."""
    if TOP_ALIGN_RE.search(raw) is not None or "\\move(" in raw:
        return True
    position = POSITION_RE.search(raw)
    if position is not None and play_res is not None:
        return float(position.group(2)) < play_res[1] / 2
    return False


def classify_cue(
    kind: str, style: Style | None, raw: str, play_res: tuple[int, int] | None
) -> str:
    """Final class of one cue: the style's guess, refined by the cue itself."""
    if kind == CLASS_SIGN:
        return CLASS_SIGN
    if DRAW_START_RE.search(raw) is not None:
        return CLASS_SIGN
    if kind == CLASS_ONTOP:
        return CLASS_ONTOP
    alignment = (style.alignment if style else "").strip()
    if alignment in ("7", "8", "9") or over_frame(raw, play_res):
        return CLASS_ONTOP
    return CLASS_DIALOGUE



def decorate_cue(rendered: str, cue_class: str, palette: Palette) -> str:
    """Wrap a rendered cue in its class colour.

    A colour written in the ASS text itself is explicit intent and is left
    alone; the class colour only fills the gap it leaves.
    """
    if COLOR_TAG_RE.search(rendered) is not None:
        return rendered
    if cue_class == CLASS_SIGN:
        colour = palette.sign
    elif cue_class == CLASS_ONTOP:
        colour = palette.ontop
    else:
        colour = None
    return f'<font color="{colour}">{rendered}</font>' if colour else rendered


# --------------------------------------------------------------------------- #
# conversion
# --------------------------------------------------------------------------- #

DEFAULT_MERGE_TOLERANCE_MS = 250

COLOR_TAG_RE = re.compile(r'<font color="#([0-9A-Fa-f]{6})">')
# A cue carrying no explicit colour is drawn in the player's own subtitle
# colour, which is the readable default; an explicit colour can only be darker
# than that in practice, which is how unreadable black text sneaks into an SRT.
PLAYER_DEFAULT_BRIGHTNESS = 255.0


def _brightness(rendered: str) -> float:
    """Perceived brightness of a rendered cue, 0-255."""
    match = COLOR_TAG_RE.search(rendered)
    if match is None:
        return PLAYER_DEFAULT_BRIGHTNESS
    red, green, blue = (int(match.group(1)[index:index + 2], 16) for index in (0, 2, 4))
    return 0.299 * red + 0.587 * green + 0.114 * blue


# A fansub draws its phone and note UI as near-black text meant to sit on a
# white background it also draws. An SRT cannot place that background, so the
# black survives as black on top of the picture and is unreadable on a TV.
# Lifting it keeps the "this text is dark on purpose" intent while making it
# visible; 0 disables the lift.
DEFAULT_MIN_BRIGHTNESS = 96


def neutral_grey(brightness: int) -> str:
    """A grey whose perceived brightness is exactly `brightness`."""
    value = max(0, min(255, round(brightness)))
    return f"{value:02X}{value:02X}{value:02X}"


def lift_colour(digits: str, floor: int) -> str:
    """Scale a colour up to `floor` brightness, keeping its hue.

    Scaling all three channels by one factor leaves the hue alone, so a dark
    violet stays violet instead of turning into the grey it would become if the
    colour were replaced outright. A saturated colour clips at 255 before it
    reaches the floor, so it is then mixed towards white just enough to make
    up the difference. Pure black has no ratio to keep and becomes neutral grey.
    """
    red, green, blue = (int(digits[index:index + 2], 16) for index in (0, 2, 4))
    brightness = 0.299 * red + 0.587 * green + 0.114 * blue
    if brightness <= 0:
        return neutral_grey(floor)
    scale = floor / brightness
    channels = [min(255.0, channel * scale) for channel in (red, green, blue)]
    reached = 0.299 * channels[0] + 0.587 * channels[1] + 0.114 * channels[2]
    if reached < floor:
        # the brightest channel saturated: add white for the remaining distance
        share = (floor - reached) / (255.0 - reached)
        channels = [channel + (255.0 - channel) * share for channel in channels]
    return "".join(f"{round(channel):02X}" for channel in channels)


def apply_brightness_floor(srt: str, floor: int = DEFAULT_MIN_BRIGHTNESS) -> tuple[str, int]:
    """Raise every too-dark explicit colour to a dark grey; report how many."""
    if floor <= 0:
        return srt, 0
    lifted = 0

    def replace(match: re.Match) -> str:
        nonlocal lifted
        digits = match.group(1)
        red, green, blue = (int(digits[index:index + 2], 16) for index in (0, 2, 4))
        if 0.299 * red + 0.587 * green + 0.114 * blue >= floor:
            return match.group(0)
        lifted += 1
        return f'<font color="#{lift_colour(digits, floor)}">'

    return COLOR_TAG_RE.sub(replace, srt), lifted


def merge_identical(
    cues: list[tuple[int, int, str, str]], tolerance_ms: int = DEFAULT_MERGE_TOLERANCE_MS
) -> tuple[list[tuple[int, int, str, str]], int]:
    """Fuse cues that show the same words at the same time.

    Two reasons for the duplicates this removes:
      * a moving sign is written as one cue per leg of its path, so the same
        words appear two or three times at once;
      * a shadowed sign is written as two layers, a lighter main line and a
        darker blurred one, each with its own colour.

    Cues match when their readable text is equal, ignoring the SRT tags: styling
    is what distinguishes the layers, and SRT has no use for a drop shadow. They
    fuse when they overlap, when they merely touch, or when a gap of less than
    `tolerance_ms` separates them — sign layers are written a few frames apart.

    The fused cue keeps the **brighter** rendering, so a shadow layer never wins
    over the main one. Ties keep the cue that came first, which keeps the output
    stable. The same words shown again after a real pause stay separate.
    """
    open_runs: dict[tuple[str, str], list] = {}
    result: list[list] = []
    merged = 0
    for start, end, text, cue_class in cues:
        key = (cue_class, SRT_TAG_RE.sub("", text))
        run = open_runs.get(key)
        if run is not None:
            gap = start - run[1]
            if gap <= 0 or (tolerance_ms > 0 and gap < tolerance_ms):
                if start < run[0]:
                    run[0] = start
                if end > run[1]:
                    run[1] = end
                if _brightness(text) > _brightness(run[2]):
                    run[2] = text
                merged += 1
                continue
        row = [start, end, text, cue_class]
        result.append(row)
        open_runs[key] = row
    return [(start, end, text, cue_class) for start, end, text, cue_class in result], merged


def convert_text(
    text: str, variant: str = "colors", encoding: str = "utf-8",
    merge: bool = True, merge_tolerance_ms: int = DEFAULT_MERGE_TOLERANCE_MS,
    min_brightness: int = DEFAULT_MIN_BRIGHTNESS, palette: Palette | None = None,
) -> Conversion:
    """Convert already-decoded ASS text into an SRT document."""
    document = parse_document(text)
    stats = document.stats
    palette = palette or Palette()
    classed = variant in CLASS_VARIANTS
    evidence = positional_evidence(document.rows) if classed else {}
    cues: list[tuple[int, int, str, str]] = []
    for start, end, raw, style_name in document.rows:
        rendered, drawings, karaoke = render_cue_text(raw, variant)
        stats.drawings += drawings
        stats.karaoke += 1 if karaoke else 0
        if not rendered or not SRT_TAG_RE.sub("", rendered).strip():
            stats.empty += 1
            continue
        cue_class = ""
        if classed:
            style = document.styles.get(style_name)
            cue_class = classify_cue(
                classify_style(style_name, style, evidence.get(style_name, 0.0)),
                style, raw, document.play_res,
            )
            rendered = decorate_cue(rendered, cue_class, palette)
            if cue_class == CLASS_SIGN:
                stats.cues_sign += 1
            elif cue_class == CLASS_ONTOP:
                stats.cues_ontop += 1
            else:
                stats.cues_dialogue += 1
        cues.append((start, end, rendered, cue_class))
    if merge:
        cues, stats.merged = merge_identical(cues, merge_tolerance_ms)
    blocks: list[str] = []
    for start, end, rendered, _ in cues:
        stats.converted += 1
        blocks.append(
            f"{stats.converted}\n{format_time(start)} --> {format_time(end)}\n{rendered}\n"
        )
    srt = "\n".join(blocks)
    srt, stats.floored = apply_brightness_floor(srt, min_brightness)
    return Conversion(srt=srt, stats=stats, encoding=encoding)


def convert_bytes(
    data: bytes, variant: str = "colors", merge: bool = True,
    merge_tolerance_ms: int = DEFAULT_MERGE_TOLERANCE_MS,
    min_brightness: int = DEFAULT_MIN_BRIGHTNESS, palette: Palette | None = None,
) -> Conversion:
    """Convert raw subtitle bytes into an SRT document."""
    text, encoding = decode_bytes(data)
    return convert_text(
        text, variant, encoding, merge, merge_tolerance_ms, min_brightness, palette,
    )


def convert_file(
    src: Path, dst: Path, variant: str = "colors", palette: Palette | None = None,
) -> Conversion:
    """Convert one subtitle file and write the SRT document to dst."""
    conversion = convert_bytes(src.read_bytes(), variant, palette=palette)
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(conversion.srt, encoding="utf-8", newline="\n")
    return conversion


# --------------------------------------------------------------------------- #
# cli
# --------------------------------------------------------------------------- #

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Convert one ASS/SSA file to SRT.",
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path, nargs="?")
    parser.add_argument("--variant", choices=VARIANTS, default="colors")
    parser.add_argument("--sign-color", default=Palette().sign, metavar="#RRGGBB")
    parser.add_argument("--ontop-color", default=Palette().ontop, metavar="#RRGGBB")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        palette = Palette(ontop=parse_colour(args.ontop_color), sign=parse_colour(args.sign_color))
    except ValueError as error:
        parser.error(f"неверное значение: {error}")

    if not args.source.is_file():
        print(f"ass2srt: not a file: {args.source}", file=sys.stderr)
        return 2
    try:
        conversion = convert_file(args.source, args.target, args.variant, palette)
    except OSError as error:
        print(f"ass2srt: {args.source}: {error}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({
            "source": str(args.source),
            "target": str(args.target) if args.target else None,
            "variant": args.variant,
            "encoding": conversion.encoding,
            "stats": asdict(conversion.stats),
        }, ensure_ascii=False))
    else:
        stats = conversion.stats
        print(
            f"{args.source.name} -> {stats.converted} cues, {stats.empty} empty, "
            f"{stats.drawings} drawings, {stats.karaoke} karaoke, "
            f"{stats.malformed} malformed, encoding {conversion.encoding}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
