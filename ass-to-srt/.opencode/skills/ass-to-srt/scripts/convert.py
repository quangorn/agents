#!/usr/bin/env python3
"""Convert dropped .ass/.ssa files, or zip/7z archives of them, to .srt.

Archive in, archive of the same kind out. Nothing outside --out-dir is
written, so the source attached to a chat message stays untouched.

    convert.py --input PATH [--input PATH ...] [--out-dir DIR]
               [--variant tags|plain|colors|both] [--sign-color #RRGGBB]
               [--ontop-color #RRGGBB] [--json] [--selftest]

Exit codes: 0 all converted, 1 some files failed, 2 a fatal input problem.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import asdict, dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ass2srt import (  # noqa: E402
    DEFAULT_MERGE_TOLERANCE_MS, DEFAULT_MIN_BRIGHTNESS,
    VARIANTS, Palette, convert_bytes, convert_text, parse_colour,
)

SUBTITLE_SUFFIXES = (".ass", ".ssa")
ARCHIVE_KINDS = {".zip": "zip", ".7z": "7z"}
SEVEN_ZIP_NAMES = ("7z", "7za", "7zr", "7zz")

# "colors" is the default: the tags the TV player renders correctly, plus a
# colour per cue class (dialogue / over-frame speech / sign). "tags" stays
# available behind an explicit flag, "plain" as the no-markup fallback.
DEFAULT_VARIANT = "colors"


VARIANT_GROUPS = {
    "both": ("colors", "plain"),
    "classes": ("colors",),
}


class Fatal(Exception):
    """One input cannot be processed at all."""


@dataclass(frozen=True)
class Options:
    """Every conversion knob, threaded through the pipeline in one piece."""
    merge: bool = True
    merge_tolerance_ms: int = DEFAULT_MERGE_TOLERANCE_MS
    min_brightness: int = DEFAULT_MIN_BRIGHTNESS
    palette: Palette = field(default_factory=Palette)


def parse_variants(raw: str) -> tuple[str, ...]:
    """`colors` or `tags,plain`, or a comma-separated list of variants."""
    chosen: list[str] = []
    for part in raw.split(","):
        name = part.strip()
        if not name:
            continue
        for variant in VARIANT_GROUPS.get(name, (name,)):
            if variant not in VARIANTS:
                raise ValueError(name)
            if variant not in chosen:
                chosen.append(variant)
    if not chosen:
        raise ValueError(raw)
    return tuple(chosen)


@dataclass
class SourceReport:
    source: str
    kind: str
    outputs: list[str] = field(default_factory=list)
    files: int = 0
    cues: int = 0
    empty: int = 0
    drawings: int = 0
    karaoke: int = 0
    merged: int = 0
    floored: int = 0
    malformed: int = 0
    cues_dialogue: int = 0
    cues_ontop: int = 0
    cues_sign: int = 0
    encodings: dict[str, int] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

def seven_zip_binary() -> str | None:
    candidates: list[str | None] = []
    if sys.platform.startswith("cygwin"):
        # Windows 7-Zip cannot parse cygwin paths (/cygdrive/...), while the
        # p7zip build from the cygwin repo does; prefer it over 7z.exe on PATH.
        candidates.extend(f"/usr/bin/{name}" for name in SEVEN_ZIP_NAMES)
    candidates.extend(shutil.which(name) for name in SEVEN_ZIP_NAMES)
    for found in candidates:
        if found and Path(found).is_file():
            return found
    return None


def run_seven_zip(args: list[str], cwd: Path | None = None) -> None:
    binary = seven_zip_binary()
    if binary is None:
        raise Fatal("7z не найден — установите пакет p7zip-full (sudo apt-get install -y p7zip-full)")
    result = subprocess.run(
        [binary, *args], cwd=cwd, capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip().splitlines()
        raise Fatal(f"7z завершился с кодом {result.returncode}: {detail[-1] if detail else 'нет вывода'}")


def output_name(stem: str, variant: str, suffix: str, many: bool) -> str:
    """`movie.ass` + one variant -> `movie.srt`; with several -> `movie.tags.srt`."""
    return f"{stem}.{variant}{suffix}" if many else f"{stem}{suffix}"


def allocate_target(out_root: Path, relative: Path, used: set[str]) -> Path:
    """Pick a collision-free `.srt` name next to the source's relative path."""
    stem = relative.stem
    candidate = f"{stem}.srt"
    if candidate.lower() in used:
        candidate = f"{stem}{relative.suffix.lower()}.srt"
    counter = 2
    while candidate.lower() in used:
        candidate = f"{stem}-{counter}.srt"
        counter += 1
    used.add(candidate.lower())
    return out_root / relative.with_name(candidate)


def subtitle_files(root: Path) -> list[Path]:
    return sorted(
        (path for path in root.rglob("*")
         if path.is_file() and path.suffix.lower() in SUBTITLE_SUFFIXES),
        key=lambda path: path.relative_to(root).as_posix(),
    )


# --------------------------------------------------------------------------- #
# conversion of one source
# --------------------------------------------------------------------------- #

def convert_blob(
    data: bytes,
    relative: Path,
    out_root: Path,
    conversions: dict[str, object],
    variant: str,
    used: set[str],
    report: SourceReport,
    count_stats: bool,
) -> None:
    """Write one SRT file for one subtitle blob inside an archive round trip."""
    conversion = conversions[variant]
    if count_stats:
        stats = conversion.stats
        report.files += 1
        report.cues += stats.converted
        report.empty += stats.empty
        report.drawings += stats.drawings
        report.karaoke += stats.karaoke
        report.merged += stats.merged
        report.floored += stats.floored
        report.malformed += stats.malformed
        report.cues_dialogue += stats.cues_dialogue
        report.cues_ontop += stats.cues_ontop
        report.cues_sign += stats.cues_sign
        report.encodings[conversion.encoding] = report.encodings.get(conversion.encoding, 0) + 1
        counts = {name: item.stats.converted for name, item in conversions.items()}
        if len(set(counts.values())) > 1:
            detail = ", ".join(f"{name}={count}" for name, count in counts.items())
            report.warnings.append(f"{relative.as_posix()}: варианты расходятся по числу реплик — {detail}")
    target = allocate_target(out_root, relative, used)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(conversion.srt, encoding="utf-8", newline="\n")


def convert_single_file(src: Path, out_dir: Path, variants: tuple[str, ...], options: Options = Options()) -> SourceReport:
    report = SourceReport(source=str(src), kind="file")
    many = len(variants) > 1
    out_dir.mkdir(parents=True, exist_ok=True)
    used: set[str] = set()
    try:
        data = src.read_bytes()
    except OSError as error:
        raise Fatal(f"{src.name}: {error}") from error
    for variant in variants:
        conversion = convert_bytes(
            data, variant, options.merge, options.merge_tolerance_ms,
            options.min_brightness, options.palette,
        )
        if variant == variants[0]:
            stats = conversion.stats
            report.files = 1
            report.cues = stats.converted
            report.empty = stats.empty
            report.drawings = stats.drawings
            report.karaoke = stats.karaoke
            report.merged = stats.merged
            report.floored = stats.floored
            report.malformed = stats.malformed
            report.cues_dialogue = stats.cues_dialogue
            report.cues_ontop = stats.cues_ontop
            report.cues_sign = stats.cues_sign
            report.encodings[conversion.encoding] = 1
        target = out_dir / output_name(src.stem, variant, ".srt", many)
        target.write_text(conversion.srt, encoding="utf-8", newline="\n")
        report.outputs.append(str(target))
    return report


def extract_zip(src: Path, staging: Path) -> list[str]:
    problems: list[str] = []
    anchor = staging.resolve()
    with zipfile.ZipFile(src) as archive:
        for member in archive.infolist():
            if member.is_dir():
                continue
            target = (staging / member.filename).resolve()
            if not target.is_relative_to(anchor):
                problems.append(f"небезопасный путь пропущен: {member.filename}")
                continue
            try:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as reader, target.open("wb") as writer:
                    shutil.copyfileobj(reader, writer)
            except (OSError, zipfile.BadZipFile) as error:
                problems.append(f"{member.filename}: {error}")
    return problems


def create_zip(source_dir: Path, target: Path) -> None:
    files = sorted(path for path in source_dir.rglob("*") if path.is_file())
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            info = zipfile.ZipInfo(path.relative_to(source_dir).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes())


def convert_archive(src: Path, out_dir: Path, variants: tuple[str, ...], options: Options = Options()) -> SourceReport:
    kind = ARCHIVE_KINDS[src.suffix.lower()]
    report = SourceReport(source=str(src), kind=kind)
    many = len(variants) > 1
    out_dir.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".stage-", dir=out_dir))
    try:
        unpacked = stage / "in"
        unpacked.mkdir()
        if kind == "zip":
            try:
                report.warnings.extend(extract_zip(src, unpacked))
            except (OSError, zipfile.BadZipFile) as error:
                raise Fatal(f"{src.name}: нечитаемый zip ({error})") from error
        else:
            run_seven_zip(["x", "-y", f"-o{unpacked}", str(src.resolve())])

        sources = subtitle_files(unpacked)
        if not sources:
            raise Fatal(f"{src.name}: в архиве нет файлов .ass/.ssa")

        anchor = unpacked.resolve()
        for variant in variants:
            out_root = stage / f"out-{variant}"
            used: set[str] = set()
            for path in sources:
                relative = path.relative_to(unpacked)
                if not path.resolve().is_relative_to(anchor):
                    report.warnings.append(f"небезопасный путь пропущен: {relative.as_posix()}")
                    continue
                try:
                    data = path.read_bytes()
                except OSError as error:
                    report.errors.append(f"{relative.as_posix()}: {error}")
                    continue
                conversions = {
                    name: convert_bytes(
                        data, name, options.merge, options.merge_tolerance_ms,
                        options.min_brightness, options.palette,
                    )
                    for name in variants
                }
                convert_blob(
                    data, relative, out_root, conversions, variant, used, report,
                    count_stats=variant == variants[0],
                )
            archive_path = out_dir / output_name(src.stem, variant, src.suffix.lower(), many)
            if kind == "zip":
                create_zip(out_root, archive_path)
            else:
                run_seven_zip(
                    ["a", "-t7z", "-mx=5", "-bd", "-bso0", "-bsp0", str(archive_path.resolve()), "."],
                    cwd=out_root,
                )
            report.outputs.append(str(archive_path))
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    return report


def convert_input(src: Path, out_dir: Path, variants: tuple[str, ...], options: Options = Options()) -> SourceReport:
    suffix = src.suffix.lower()
    if suffix in ARCHIVE_KINDS:
        return convert_archive(src, out_dir, variants, options)
    if suffix in SUBTITLE_SUFFIXES:
        return convert_single_file(src, out_dir, variants, options)
    raise Fatal(f"{src.name}: поддерживаются .ass, .ssa, .zip и .7z")


# --------------------------------------------------------------------------- #
# reporting
# --------------------------------------------------------------------------- #

def report_line(index: int, total: int, report: SourceReport) -> str:
    name = Path(report.source).name
    outputs = ", ".join(Path(path).name for path in report.outputs) or "—"
    head = f"[{index}/{total}] {name} -> {outputs}"
    if report.kind == "file":
        detail = (
            f"реплик {report.cues}, пустых {report.empty}, рисунков {report.drawings}, "
            f"караоке {report.karaoke}, склеено {report.merged}, осветлено {report.floored}, "
            f"отброшено {report.malformed}"
        )
    else:
        detail = (
            f"файлов {report.files}, реплик {report.cues}, пустых {report.empty}, "
            f"рисунков {report.drawings}, караоке {report.karaoke}, склеено {report.merged}, "
            f"осветлено {report.floored}, отброшено {report.malformed}"
        )
    classes = report.cues_dialogue + report.cues_ontop + report.cues_sign
    if classes:
        detail += (
            f", классы {report.cues_dialogue}/{report.cues_ontop}/{report.cues_sign}"
            " (реплика/поверх/надпись)"
        )
    return f"{head} | {detail}"


def print_human(reports: list[SourceReport], failures: list[str]) -> int:
    total = len(reports) + len(failures)
    for index, report in enumerate(reports, start=1):
        print(report_line(index, total, report))
        for warning in report.warnings:
            print(f"    ! {warning}")
        for error in report.errors:
            print(f"    x {error}")
    for offset, failure in enumerate(failures, start=len(reports) + 1):
        print(f"[{offset}/{total}] {failure}")
    errored = sum(len(report.errors) for report in reports)
    warnings = sum(len(report.warnings) for report in reports)
    print(
        f"Итого: обработано {len(reports)}/{total}, ошибок {errored + len(failures)}, "
        f"предупреждений {warnings}"
    )
    if failures:
        return 2
    return 1 if errored else 0


# --------------------------------------------------------------------------- #
# self test
# --------------------------------------------------------------------------- #

def selftest() -> int:
    passed = failed = skipped = 0

    def check(name: str, actual, expected) -> None:
        nonlocal passed, failed
        if actual == expected:
            passed += 1
            print(f"PASS {name}")
        else:
            failed += 1
            print(f"FAIL {name}\n  ожидалось: {expected!r}\n  получено: {actual!r}")

    def events(*rows: str, columns: str | None = None) -> str:
        header = f"Format: {columns}\n" if columns else ""
        return "[Script Info]\nScriptType: v4.00+\n\n[Events]\n" + header + "".join(
            f"Dialogue: {row}\n" for row in rows
        )

    def std_row(text: str, start: str = "0:00:01.20", end: str = "0:00:04.56") -> str:
        return f"0,{start},{end},Default,,0,0,0,,{text}"

    def cue_of(text: str, variant: str = "tags", **kwargs) -> str:
        return convert_text(text, variant, **kwargs).srt.strip()

    # 1. non-standard column order, no Layer column
    check("порядок колонок Format", cue_of(events(
        "0:00:02.00,0:00:03.00,Default,,0,0,0,,Привет",
        columns="Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text",
    )), "1\n00:00:02,000 --> 00:00:03,000\nПривет")

    # 2. missing Format line falls back to the v4+ default
    check("без Format", cue_of(events(std_row("Привет"))),
          "1\n00:00:01,200 --> 00:00:04,560\nПривет")

    # 3. every accepted timestamp spelling
    check("дробная часть в 1 цифру", cue_of(events(std_row("x", "0:00:01.5", "0:00:04.5"))),
          "1\n00:00:01,500 --> 00:00:04,500\nx")
    check("дробная часть через двоеточие", cue_of(events(std_row("x", "0:00:01:25", "0:00:04:75"))),
          "1\n00:00:01,250 --> 00:00:04,750\nx")

    # 4. line breaks
    check("переводы строк", cue_of(events(std_row(r"верх\Nниз\nещё\hдалее"))),
          "1\n00:00:01,200 --> 00:00:04,560\nверх\nниз\nещё\u00a0далее")

    # 5. nested style tags, plus a toggle that lost its braces
    check("вложенные b и i", cue_of(events(std_row(r"{\b1\i1}оба{\i0\b0}только"))),
          "1\n00:00:01,200 --> 00:00:04,560\n<b><i>оба</i></b>только")
    check("сиротский \\b0 вырезан", cue_of(events(std_row(r"{\i1}да{\i0}нет\i0"))),
          "1\n00:00:01,200 --> 00:00:04,560\n<i>да</i>нет")

    # 6. colours: ASS stores BGR, so &H0000FF is red
    check("цвет &H0000FF", cue_of(events(std_row(r"{\1c&H0000FF&}красный")), min_brightness=0),
          '1\n00:00:01,200 --> 00:00:04,560\n<font color="#FF0000">красный</font>')
    check("цвет по имени", cue_of(events(std_row(r"{\1c&Hblue&}синий")), min_brightness=0),
          '1\n00:00:01,200 --> 00:00:04,560\n<font color="#0000FF">синий</font>')

    # 7. style reset closes open tags
    check("сброс стиля закрывает теги", cue_of(events(std_row(r"{\i1}курсив{\r}обычный"))),
          "1\n00:00:01,200 --> 00:00:04,560\n<i>курсив</i>обычный")

    # 8. drawing blocks vanish, their text is not leaked
    conversion = convert_text(events(std_row(r"{\p1}m 0 0 l 100 100 50 0{\p0}текст")))
    check("рисунок p1 удалён", conversion.srt.strip().endswith('<font color="#A9A9A9">текст</font>'), True)
    check("рисунок посчитан", conversion.stats.drawings, 1)
    check("рисунок p1 удалён в tags",
          convert_text(events(std_row(r"{\p1}m 0 0 l 100 100 50 0{\p0}текст")), "tags").srt.strip().endswith("текст"), True)

    # 9. karaoke timings keep their text
    conversion = convert_text(events(std_row(r"{\k40}а{\k30}б")))
    check("караоке сохраняет текст", conversion.srt.strip().endswith("аб"), True)
    check("караоке посчитан", conversion.stats.karaoke, 1)

    # 10. the plain variant carries no styling and no vector data
    check("вариант plain", cue_of(events(std_row(r"{\i1\pos(10,20)}Привет{\i0}")), "plain"),
          "1\n00:00:01,200 --> 00:00:04,560\nПривет")
    conversion = convert_text(events(std_row(r"{\p1}m 0 0 l 100 100 50 0{\p0}текст")), "plain")
    check("рисунок удалён и в plain", conversion.srt.strip().endswith("текст"), True)
    check("рисунок посчитан в plain", conversion.stats.drawings, 1)

    # 11. HTML metacharacters are escaped, not interpreted
    check("экранирование", cue_of(events(std_row("a < b & c > d"))),
          "1\n00:00:01,200 --> 00:00:04,560\na &lt; b &amp; c &gt; d")

    # 12. encodings
    check("cp1251", convert_bytes(events(std_row("Привет")).encode("cp1251")).srt.strip().endswith("Привет"), True)
    check("utf-16 с BOM", convert_bytes(events(std_row("Привет")).encode("utf-16")).srt.strip().endswith("Привет"), True)
    check("utf-8 с BOM", convert_bytes(("\ufeff" + events(std_row("Привет"))).encode("utf-8")).srt.strip().endswith("Привет"), True)

    # 13. rows that must never reach the output
    conversion = convert_text(
        "[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        "Comment: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,комментарий\n"
        "Dialogue: 0,0:00:05.00,0:00:04.00,Default,,0,0,0,,конец раньше начала\n"
        "Dialogue: 0,0:00:06.00,0:00:07.00,Default,,0,0,0,,{\\b1\\i0}\n"
    )
    check("Comment не попал в вывод", conversion.srt, "")
    check("пустая реплика отброшена", conversion.stats.empty, 1)
    check("некорректный интервал отброшен", conversion.stats.malformed, 1)

    # 14. a.ass and a.ssa in one folder must not overwrite each other
    used: set[str] = set()
    names = (
        allocate_target(Path("out"), Path("a.ass"), used).name,
        allocate_target(Path("out"), Path("a.ssa"), used).name,
    )
    check("коллизия имён", names, ("a.srt", "a.ssa.srt"))

    # 15. moving signs split into overlapping legs must fuse into one cue.
    # ASS stores &H957A75 as BGR, so the SRT colour is #757A95.
    moving = events(
        std_row(r"{\1c&H957A75&}Клубничные дайфуку", "0:03:46.28", "0:03:48.04"),
        std_row(r"{\1c&H957A75&}Клубничные дайфуку", "0:03:46.28", "0:03:49.50"),
        std_row(r"{\1c&H957A75&}Клубничные дайфуку", "0:03:48.04", "0:03:49.50"),
        std_row("совсем другой текст", "0:03:47.00", "0:03:47.50"),
    )
    conversion = convert_text(moving)
    check("склейка перекрывающихся реплик", conversion.srt, (
        '1\n00:03:46,280 --> 00:03:49,500\n<font color="#757A95">Клубничные дайфуку</font>\n\n'
        "2\n00:03:47,000 --> 00:03:47,500\nсовсем другой текст\n"
    ))
    check("склеено реплик", conversion.stats.merged, 2)

    # touching cues with the same words still fuse
    touching = events(
        std_row("Да", "0:00:10.00", "0:00:12.00"),
        std_row("Да", "0:00:12.00", "0:00:14.00"),
    )
    check("склейка соприкасающихся реплик", convert_text(touching).stats.converted, 1)

    # the same words after a real pause stay separate
    apart = events(
        std_row("Да", "0:00:10.00", "0:00:12.00"),
        std_row("Да", "0:00:30.00", "0:00:32.00"),
    )
    check("пауза не склеивается", convert_text(apart).stats.converted, 2)

    # a colour difference alone no longer blocks fusion: SRT has no drop shadow
    coloured = events(
        std_row(r"{\1c&H0000FF&}Да", "0:00:10.00", "0:00:12.00"),
        std_row(r"{\1c&HFF0000&}Да", "0:00:12.00", "0:00:14.00"),
    )
    check("разный цвет склеивается", convert_text(coloured).stats.converted, 1)

    # and the whole behaviour can be switched off again
    check("--no-merge отключает склейку", convert_text(moving, merge=False).stats.converted, 4)

    # 16. shadowed signs: two layers, different colour, times a few frames apart
    shadow = events(
        std_row(r"{\1c&H21211F&\b1}Токийский университет", "0:00:53.32", "0:00:53.82"),
        std_row(r"{\1c&H111210&\b1}Токийский университет", "0:00:53.32", "0:00:53.82"),
        std_row(r"{\1c&H21211F&\b1}Токийский университет", "0:00:53.82", "0:00:55.99"),
        std_row(r"{\1c&H111210&\b1}Токийский университет", "0:00:53.82", "0:00:56.03"),
    )
    conversion = convert_text(shadow, min_brightness=0)
    check("теневые слои склеены в одну реплику", conversion.srt, (
        '1\n00:00:53,320 --> 00:00:56,030\n<font color="#1F2121"><b>Токийский университет</b></font>\n'
    ))
    check("склеено реплик теней", conversion.stats.merged, 3)

    # overlapping layers need no tolerance at all
    check("перекрытие склеивается даже без допуска",
          convert_text(shadow, merge_tolerance_ms=0).stats.converted, 1)

    # a gap beyond the tolerance is a real pause, not a layer offset
    apart_layers = events(
        std_row(r"{\1c&H21211F&}Да", "0:00:10.00", "0:00:12.00"),
        std_row(r"{\1c&H111210&}Да", "0:00:12.40", "0:00:14.40"),
    )
    check("разрыв больше допуска не склеивается", convert_text(apart_layers).stats.converted, 2)
    check("разрыв меньше допуска склеивается",
          convert_text(apart_layers, merge_tolerance_ms=500).stats.converted, 1)

    # different words never fuse, whatever the timing
    different = events(
        std_row("Да", "0:00:10.00", "0:00:12.00"),
        std_row("Нет", "0:00:10.10", "0:00:12.10"),
    )
    check("разный текст не склеивается", convert_text(different).stats.converted, 2)

    # 17. the fused cue keeps the brighter rendering, not the first one
    dark_then_bright = events(
        std_row(r"{\1c&H000000&}Да", "0:00:10.00", "0:00:12.00"),
        std_row(r"{\1c&H00FFFF&}Да", "0:00:12.00", "0:00:14.00"),
    )
    check("из двух цветов берётся более яркий", convert_text(dark_then_bright).srt,
          '1\n00:00:10,000 --> 00:00:14,000\n<font color="#FFFF00">Да</font>\n')

    bright_then_dark = events(
        std_row(r"{\1c&H00FFFF&}Да", "0:00:10.00", "0:00:12.00"),
        std_row(r"{\1c&H000000&}Да", "0:00:12.00", "0:00:14.00"),
    )
    check("порядок в файле не влияет на выбор", convert_text(bright_then_dark).srt,
          '1\n00:00:10,000 --> 00:00:14,000\n<font color="#FFFF00">Да</font>\n')

    # no explicit colour means the player's own colour, which beats a dark tag
    plain_vs_dark = events(
        std_row(r"{\1c&H292929&}Да", "0:00:10.00", "0:00:12.00"),
        std_row("Да", "0:00:12.00", "0:00:14.00"),
    )
    check("бесцветный побеждает тёмный тег", convert_text(plain_vs_dark).srt,
          "1\n00:00:10,000 --> 00:00:14,000\nДа\n")

    # an identical shade keeps the cue that came first
    equal_shade = events(
        std_row(r"{\1c&H111111&}Да", "0:00:10.00", "0:00:12.00"),
        std_row(r"{\1c&H111111&}Да", "0:00:12.00", "0:00:14.00"),
    )
    check("одинаковые цвета: остаётся первый", convert_text(equal_shade, min_brightness=0).srt,
          '1\n00:00:10,000 --> 00:00:14,000\n<font color="#111111">Да</font>\n')

    # 18. near-black colours are lifted to a dark grey, brighter ones are left alone
    black = events(std_row(r"{\1c&H000000&}У вас 1 новое сообщение"))
    conversion = convert_text(black)
    check("чёрный поднят до тёмно-серого", conversion.srt,
          '1\n00:00:01,200 --> 00:00:04,560\n<font color="#606060">У вас 1 новое сообщение</font>\n')
    check("поднятых цветов посчитано", conversion.stats.floored, 1)
    check("порог 0 отключает осветление", convert_text(black, min_brightness=0).srt,
          '1\n00:00:01,200 --> 00:00:04,560\n<font color="#000000">У вас 1 новое сообщение</font>\n')
    check("яркий цвет не трогаем", convert_text(events(std_row(r"{\1c&H00FFFF&}Привет"))).stats.floored, 0)
    check("средне-тёмный тоже поднимается",
          convert_text(events(std_row(r"{\1c&H292929&}Привет"))).srt,
          '1\n00:00:01,200 --> 00:00:04,560\n<font color="#606060">Привет</font>\n')
    check("бесцветная реплика не трогается", convert_text(events(std_row("Привет"))).stats.floored, 0)

    # a saturated colour keeps its hue instead of turning grey
    # &H260D8E& is BGR, so the cue is dark crimson #8E0D26 — it must stay red
    check("насыщенный цвет сохраняет оттенок",
          convert_text(events(std_row(r"{\1c&H260D8E&}Дорога закрыта"))).srt,
          '1\n00:00:01,200 --> 00:00:04,560\n<font color="#FA1743">Дорога закрыта</font>\n')
    check("тёмный насыщенный дотягивается до порога",
          convert_text(events(std_row(r"{\1c&H0F0063&}МАГИЧЕСКАЯ БИТВА"))).srt,
          '1\n00:00:01,200 --> 00:00:04,560\n<font color="#FF153F">МАГИЧЕСКАЯ БИТВА</font>\n')
    check("порог задаётся числом",
          convert_text(events(std_row(r"{\1c&H000000&}Привет")), min_brightness=128).srt,
          '1\n00:00:01,200 --> 00:00:04,560\n<font color="#808080">Привет</font>\n')

    # 19. colours set back to back must not leave empty pairs behind;
    # the second \c wins, so the first must vanish without leaving <font></font>
    check("пустые пары тегов убраны",
          cue_of(events(std_row(r"{\c&HD70007&\c&H404040&}МАГИЧЕСКАЯ БИТВА")), min_brightness=0),
          '1\n00:00:01,200 --> 00:00:04,560\n<font color="#404040">МАГИЧЕСКАЯ БИТВА</font>')
    check("вложенность тегов не ломается", cue_of(events(std_row(r"{\b1\i1}оба{\i0\b0}"))),
          "1\n00:00:01,200 --> 00:00:04,560\n<b><i>оба</i></b>")

    # 20. cue classes: dialogue keeps the player's own colour, speech over the
    # picture is forced white, a sign is light grey
    def style_row(name, *, size="22", align="2", margin_v="25", primary="&H00FFFFFF"):
        return (f"{name},Tahoma,{size},{primary},&H000000FF,&H00000000,&H00000000,"
                f"0,0,0,0,100,100,0,0,1,2,2,{align},10,10,{margin_v},1")

    def styled(styles, *rows):
        return (
            "[Script Info]\nScriptType: v4.00+\nPlayResX: 640\nPlayResY: 360\n\n"
            "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, "
            "OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, "
            "Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, "
            "MarginV, Encoding\n"
            + "".join(f"Style: {row}\n" for row in styles)
            + "\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, "
            "MarginV, Effect, Text\n"
            + "".join(f"Dialogue: {row}\n" for row in rows)
        )

    def dialogue(style, text, start="0:00:01.20", end="0:00:04.56"):
        return f"0,{start},{end},{style},,0,0,0,,{text}"

    classes = styled(
        [style_row("Default"), style_row("Main - Top"), style_row("Sign"), style_row("OS")],
        dialogue("Default", "Привет"),
        dialogue("Main - Top", "В углу кадра"),
        dialogue("Sign", "Дом продаётся"),
        dialogue("OS", "Сэндвичи"),
    )
    conversion = convert_text(classes, "colors")
    check("реплика без цветового тега", "\nПривет\n" in conversion.srt, True)
    check("поверх кадра — белый",
          '<font color="#FFFFFF">В углу кадра</font>' in conversion.srt, True)
    check("надпись по стилю Sign — серый",
          '<font color="#A9A9A9">Дом продаётся</font>' in conversion.srt, True)
    check("стиль OS считается надписью",
          '<font color="#A9A9A9">Сэндвичи</font>' in conversion.srt, True)
    check("классы посчитаны",
          (conversion.stats.cues_dialogue, conversion.stats.cues_ontop, conversion.stats.cues_sign),
          (1, 1, 2))

    # an explicit ASS colour is intent and beats the class colour
    explicit = styled(
        [style_row("Sign")],
        dialogue("Sign", r"{\1c&H0000FF&}Красная надпись"),
    )
    check("явный цвет сильнее класса надписи",
          convert_text(explicit, "colors", min_brightness=0).srt,
          '1\n00:00:01,200 --> 00:00:04,560\n<font color="#FF0000">Красная надпись</font>\n')

    # a dialogue style that places its own cue above the middle is over-frame speech
    placed = styled(
        [style_row("Main")],
        dialogue("Main", r"{\an8}Сверху"),
        dialogue("Main", r"{\pos(320,40)}И тут"),
        dialogue("Main", "Внизу"),
    )
    placed_srt = convert_text(placed, "colors").srt
    check("\\an8 и верхний \\pos дают белый", placed_srt.count('<font color="#FFFFFF">'), 2)
    check("нижняя реплика осталась без тега", "\nВнизу\n" in placed_srt, True)

    # an anonymous style is judged by its cues: placed or drawn means a sign
    anonymous = styled(
        [style_row("Style A")],
        dialogue("Style A", r"{\pos(100,100)\p1}m 0 0 l 10 10{\p0}Указатель"),
        dialogue("Style A", "Обычный текст"),
        dialogue("Style A", "И ещё текст"),
    )
    anonymous_srt = convert_text(anonymous, "colors").srt
    check("безымянный стиль с рисунком — надпись",
          '<font color="#A9A9A9">Указатель</font>' in anonymous_srt, True)
    check("безымянный стиль без разметки — реплика", "\nОбычный текст\n" in anonymous_srt, True)

    # identical words in different classes are different cues and must not fuse
    cross = styled(
        [style_row("Default"), style_row("Sign")],
        dialogue("Default", "Спасибо", "0:00:10.00", "0:00:12.00"),
        dialogue("Sign", "Спасибо", "0:00:12.00", "0:00:14.00"),
    )
    check("разные классы не склеиваются", convert_text(cross, "colors").stats.converted, 2)

    # variant shortcuts
    check("группы вариантов",
          (parse_variants("classes"), parse_variants("both"), parse_variants("colors")),
          (("colors",), ("colors", "plain"), ("colors",)))
    check("дефолтный вариант — colors", DEFAULT_VARIANT, "colors")
    # the grey must be far enough from white to be seen as a different colour
    digits = Palette().sign.lstrip("#")
    grey = sum(int(digits[index:index + 2], 16) for index in (0, 2, 4)) / 3
    check("серый надписи ощутимо темнее белого", grey < 180, True)

    # 16. zip round trip keeps the tree and drops everything that is not a subtitle
    with tempfile.TemporaryDirectory() as raw_tmp:
        tmp = Path(raw_tmp)
        (tmp / "sub").mkdir()
        (tmp / "sub" / "movie.en.ass").write_text(events(std_row("Привет")), encoding="utf-8")
        (tmp / "readme.txt").write_text("не субтитры", encoding="utf-8")
        packed = tmp / "pack.zip"
        create_zip(tmp, packed)
        out_dir = tmp / "out"
        report = convert_archive(packed, out_dir, ("tags", "plain"))
        with zipfile.ZipFile(out_dir / "pack.tags.zip") as archive:
            members = sorted(archive.namelist())
            body = archive.read("sub/movie.en.srt").decode("utf-8")
        check("в zip только субтитры", members, ["sub/movie.en.srt"])
        check("содержимое в zip", body.strip().endswith("Привет"), True)
        check("zip отчёт", (report.files, report.cues), (1, 1))
        check("оба варианта на месте",
              sorted(path.name for path in out_dir.iterdir()), ["pack.plain.zip", "pack.tags.zip"])

    # 16. 7z round trip, only once p7zip-full is installed
    if seven_zip_binary() is None:
        skipped += 1
        print("SKIP 7z — p7zip-full не установлен")
    else:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            (tmp / "movie.ass").write_text(events(std_row("Привет")), encoding="utf-8")
            packed = tmp / "pack.7z"
            run_seven_zip(["a", "-t7z", "-bd", "-bso0", "-bsp0", str(packed.resolve()), "."], cwd=tmp)
            out_dir = tmp / "out"
            report = convert_archive(packed, out_dir, ("tags",))
            check("7z на выходе", (out_dir / "pack.7z").is_file(), True)
            unpacked = out_dir / "roundtrip"
            produced = out_dir / "pack.7z"
            run_seven_zip(["x", "-y", f"-o{unpacked.resolve()}", str(produced.resolve())])
            check("7z содержит .srt", (unpacked / "movie.srt").is_file(), True)
            check("7z отчёт", (report.files, report.cues), (1, 1))

    print(f"\nИтог: PASS {passed}, FAIL {failed}, SKIP {skipped}")
    return 1 if failed else 0


# --------------------------------------------------------------------------- #
# cli
# --------------------------------------------------------------------------- #

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Конвертирует .ass/.ssa (или архив .zip/.7z с ними) в .srt.",
    )
    parser.add_argument("--input", type=Path, action="append", default=[], help="путь к файлу или архиву; можно повторять")
    parser.add_argument("--out-dir", type=Path, default=None, help="куда писать результат (по умолчанию ./subtitle-output/<имя входа>/)")
    parser.add_argument("--variant", default=DEFAULT_VARIANT, metavar="ИМЯ[,ИМЯ]",
                        help="colors | tags | plain; both = colors,plain")
    parser.add_argument("--no-merge", dest="merge", action="store_false", default=True,
                        help="не склеивать подряд идущие реплики с одинаковым текстом")
    parser.add_argument("--merge-tolerance", type=int, default=DEFAULT_MERGE_TOLERANCE_MS,
                        metavar="MS",
                        help="допуск расхождения концов реплик при склейке, мс (0 — только точное совпадение)")
    parser.add_argument("--min-brightness", type=int, default=DEFAULT_MIN_BRIGHTNESS, metavar="N",
                        help="поднять цвета темнее яркости N до тёмно-серого (0 — не трогать)")
    parser.add_argument("--sign-color", default=Palette().sign, metavar="#RRGGBB",
                        help="цвет надписей (none — не задавать)")
    parser.add_argument("--ontop-color", default=Palette().ontop, metavar="#RRGGBB",
                        help="цвет реплик поверх кадра (none — не задавать)")
    parser.add_argument("--json", action="store_true", help="структурированный отчёт вместо human-readable")
    parser.add_argument("--selftest", action="store_true", help="прогнать встроенные проверки и выйти")
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.input:
        parser.error("нужен хотя бы один --input")

    try:
        variants = parse_variants(args.variant)
        options = Options(
            merge=args.merge,
            merge_tolerance_ms=args.merge_tolerance,
            min_brightness=args.min_brightness,
            palette=Palette(
                ontop=parse_colour(args.ontop_color),
                sign=parse_colour(args.sign_color),
            ),
        )
    except ValueError as error:
        parser.error(f"неверное значение: {error}")
    reports: list[SourceReport] = []
    failures: list[str] = []
    for src in args.input:
        if not src.is_file():
            failures.append(f"{src}: файл не найден")
            continue
        out_dir = args.out_dir if args.out_dir is not None else Path.cwd() / "subtitle-output" / src.stem
        try:
            reports.append(convert_input(src, out_dir, variants, options))
        except Fatal as error:
            failures.append(str(error))
        except OSError as error:
            failures.append(f"{src.name}: {error}")

    if args.json:
        payload = {
            "reports": [asdict(report) for report in reports],
            "failures": failures,
            "code": 2 if failures else (1 if any(report.errors for report in reports) else 0),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return payload["code"]
    return print_human(reports, failures)


if __name__ == "__main__":
    raise SystemExit(main())
