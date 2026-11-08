#!/usr/bin/env python3
"""plex_tracks.py — set default audio / subtitle tracks for Plex items (episode, movie, season).

Plex semantics (verified against PMS 1.x):
  * POST /library/parts/{partId}?audioStreamID=<streamId>&allParts=1
    marks that stream as `selected="1"` for the account owning the token.
    That is what the player picks by default — the `default="1"` attribute comes
    from the file's own MKV flags and is not changed by this call.
  * Same endpoint with subtitleStreamID=<streamId> (or 0 for "no subtitles").
  * An invalid/unknown stream id returns HTTP 200 and changes nothing, so every
    write must be read back and verified.
  * The setting is per media part, so a season/show must be looped episode by episode.

No third-party dependencies (stdlib only). Python 3.8+.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

DEFAULT_SERVER = os.environ.get("PLEX_URL", "http://10.0.2.2:32400")
CONFIG_PATHS = [
    os.environ.get("PLEX_CONFIG", ""),
    os.path.expanduser("~/.config/opencode/plex.yaml"),
    os.path.expanduser("~/.config/opencode/plex.json"),
    # paths from the original dsh deployment, kept as fallbacks
    os.path.expanduser("~/.dsh/plex.yaml"),
    os.path.expanduser("~/.dsh/plex.json"),
    os.path.expanduser("~/.dsh/profiles/web/plex.yaml"),
]

# Plex stores language both localized ("Русский") and as ISO codes.
# Accept a wide range of user spellings and normalise to ISO codes.
LANG_ALIASES = {
    "ru": {"rus", "рус", "русский", "русская", "russian"},
    "en": {"eng", "english", "англ", "английский", "английская"},
    "ja": {"jpn", "ja", "япон", "японский", "японская", "japanese", "日本語"},
    "de": {"deu", "ger", "нем", "немецкий", "german"},
    "fr": {"fre", "fra", "фр", "французский", "french"},
    "es": {"spa", "исп", "испанский", "spanish"},
    "it": {"ita", "ит", "итальянский", "italian"},
    "uk": {"ukr", "укр", "украинский", "ukrainian"},
    "pl": {"pol", "польский", "polish"},
    "zh": {"chi", "zh", "кит", "китайский", "chinese"},
    "ko": {"kor", "кор", "корейский", "korean"},
    "none": {"none", "off", "выкл", "без", "нет"},
}

CODEC_ALIASES = {
    "aac": {"aac"},
    "ac3": {"ac3", "ac-3"},
    "eac3": {"eac3", "e-ac3"},
    "dts": {"dts", "dts-hd", "dtshd", "dca"},
    "flac": {"flac"},
    "opus": {"opus"},
    "mp3": {"mp3", "m4a"},
}


def log(msg):
    print(msg, file=sys.stderr)


def load_config():
    """Return (server, token). Env vars win; then a config file."""
    server = os.environ.get("PLEX_SERVER") or os.environ.get("PLEX_URL")
    token = os.environ.get("PLEX_TOKEN")
    for path in CONFIG_PATHS:
        if not path or not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            continue
        if path.endswith(".json"):
            try:
                data = json.loads(text)
            except json.JSONDecodeError:
                continue
            server = server or data.get("url") or data.get("server")
            token = token or data.get("token")
        else:
            for line in text.splitlines():
                line = line.strip()
                if not line or line.startswith("#") or ":" not in line:
                    continue
                key, value = line.split(":", 1)
                key = key.strip().lower()
                value = value.strip().strip('"').strip("'")
                if key in ("url", "server") and not server:
                    server = value
                elif key == "token" and not token:
                    token = value
        if server and token:
            break
    return server or DEFAULT_SERVER, token


def request(server, path, token, method="GET", timeout=30):
    url = server.rstrip("/") + path
    sep = "&" if "?" in url else "?"
    url += sep + "X-Plex-Token=" + urllib.parse.quote(token)
    req = urllib.request.Request(
        url,
        method=method,
        headers={
            "X-Plex-Product": "dsh-plex-tracks",
            "X-Plex-Client-Identifier": "dsh-plex-tracks",
            "Accept": "application/xml",
        },
        data=b"" if method == "POST" else None,
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")[:400]
    except Exception as exc:  # network/timeout
        return 0, "transport error: %s" % exc


def xml(server, path, token):
    status, body = request(server, path, token)
    if status != 200 or not body.lstrip().startswith("<?xml"):
        raise SystemExit("Plex request failed (%s) %s: %s" % (status, path, body[:200]))
    return ET.fromstring(body)


def norm_lang(value):
    if value is None:
        return None
    v = str(value).strip().lower()
    if v in LANG_ALIASES:
        return v
    for tag, aliases in LANG_ALIASES.items():
        if v in aliases:
            return tag
    return v


def stream_language(stream):
    tag = (stream.get("languageTag") or "").lower()
    code = (stream.get("languageCode") or "").lower()
    name = (stream.get("language") or "").lower()
    return tag, code, name


def lang_matches(stream, wanted):
    tag, code, name = stream_language(stream)
    wanted = norm_lang(wanted)
    if wanted in ("none", "off"):
        return False
    if wanted in (tag, code):
        return True
    if wanted in LANG_ALIASES:
        return any(a in name for a in LANG_ALIASES[wanted])
    return wanted in name or wanted in tag or wanted in code


def streams_of(item, kind):
    kind_num = {"audio": "2", "subtitle": "3", "video": "1"}[kind]
    out = []
    for media in item.iter("Media"):
        for st in media.iter("Stream"):
            if st.attrib.get("streamType") != kind_num:
                continue
            out.append(
                {
                    "id": st.attrib.get("id"),
                    "index": st.attrib.get("index"),
                    "kind": kind,
                    "codec": st.attrib.get("codec"),
                    "channels": st.attrib.get("channels"),
                    "languageTag": st.attrib.get("languageTag"),
                    "languageCode": st.attrib.get("languageCode"),
                    "language": st.attrib.get("language"),
                    "title": st.attrib.get("title"),
                    "displayTitle": st.attrib.get("displayTitle"),
                    "selected": st.attrib.get("selected") == "1",
                    "default": st.attrib.get("default") == "1",
                    "forced": st.attrib.get("forced") == "1",
                    "file": st.attrib.get("file"),
                }
            )
    return out


def find_sections(server, token, section_filter=None):
    root = xml(server, "/library/sections", token)
    sections = []
    for d in root.findall("Directory"):
        title = (d.attrib.get("title") or "").lower()
        if section_filter and section_filter.lower() not in title:
            continue
        sections.append({
            "id": d.attrib.get("key") or d.attrib.get("ratingKey"),
            "title": d.attrib.get("title"),
            "type": d.attrib.get("type"),
        })
    return sections


def find_show(server, token, title, section=None):
    """Locate shows/movies by title across sections (case-insensitive substring)."""
    needle = title.lower()
    found = []
    for sec in find_sections(server, token, section):
        start, size = 0, 100
        while True:
            root = xml(server, "/library/sections/%s/all?X-Plex-Container-Start=%d&X-Plex-Container-Size=%d"
                       % (sec["id"], start, size), token)
            items = root.findall("Directory") + root.findall("Video")
            if not items:
                break
            for it in items:
                t = (it.attrib.get("title") or "").lower()
                orig = (it.attrib.get("originalTitle") or "").lower()
                if needle in t or needle in orig:
                    found.append({
                        "section": sec["id"],
                        "sectionTitle": sec["title"],
                        "ratingKey": it.attrib.get("ratingKey"),
                        "key": it.attrib.get("key"),
                        "title": it.attrib.get("title"),
                        "type": it.attrib.get("type"),
                    })
            if len(items) < size:
                break
            start += size
    return found


def season_items(server, token, show, season):
    if show["type"] != "show":
        return [show]
    root = xml(server, show["key"], token)
    seasons = root.findall("Directory")
    if season is not None:
        seasons = [s for s in seasons if str(s.attrib.get("index")) == str(season)]
        if not seasons:
            raise SystemExit("Сезон %s не найден в «%s»" % (season, show["title"]))
    items = []
    for s in seasons:
        ep_root = xml(server, s.attrib["key"], token)
        items.extend(ep_root.findall("Video"))
    return items


def pick(streams, wanted_lang, codec=None, keyword=None, exclude=None, allow_forced=False,
         external_only=False):
    """Return (chosen, candidates) — chosen None when no match."""
    pool = [s for s in streams if not s["forced"] or allow_forced]
    if external_only:
        pool = [s for s in pool if s["file"]]
    if wanted_lang not in (None, "", "any"):
        pool = [s for s in pool if lang_matches(s, wanted_lang)]
    if codec:
        c = codec.lower()
        allowed = CODEC_ALIASES.get(c, {c})
        # the codec is a preference: matching tracks win, but if the file has
        # none of them the pool is kept as it was
        matching = [s for s in pool
                    if (s["codec"] or "").lower() in allowed or c in (s["codec"] or "").lower()]
        pool = matching or pool
    if keyword:
        kw = keyword.lower()
        pool = [s for s in pool
                if kw in (s["title"] or "").lower() or kw in (s["displayTitle"] or "").lower()]
    if exclude:
        ex = exclude.lower()
        pool = [s for s in pool
                if ex not in (s["title"] or "").lower() and ex not in (s["displayTitle"] or "").lower()]
    if not pool:
        return None, []
    # Stable preference: already-selected > file default > first track in the file
    pool.sort(key=lambda s: (not s["selected"], not s["default"], int(s["index"] or 999)))
    return pool[0], pool


def apply(server, token, part_id, stream_id, kind):
    param = "audioStreamID" if kind == "audio" else "subtitleStreamID"
    return request(server, "/library/parts/%s?%s=%s&allParts=1" % (part_id, param, stream_id),
                   token, method="POST")


def verify(server, token, rating_key, stream_id, kind):
    root = xml(server, "/library/metadata/%s" % rating_key, token)
    streams = streams_of(root, kind)
    if stream_id == "0":
        # "no subtitles": success means nothing is selected
        return not any(s["selected"] for s in streams)
    for st in streams:
        if st["id"] == stream_id:
            return st["selected"]
    return False


def main():
    p = argparse.ArgumentParser(description="Set default audio/subtitle tracks in Plex.")
    p.add_argument("--server", help="PMS url (default $PLEX_URL / ~/.config/opencode/plex.yaml)")
    p.add_argument("--token", help="Plex token (default $PLEX_TOKEN / ~/.config/opencode/plex.yaml)")
    p.add_argument("--show", help="Show or movie title (not needed with --undo)")
    p.add_argument("--season", type=int, help="Season index (shows only)")
    p.add_argument("--section", help="Limit to one library section (name or id)")
    p.add_argument("--audio", help="Target audio language: jpn/ru/en/…")
    p.add_argument("--audio-codec", help="Prefer codec: flac/aac/ac3/dts/…")
    p.add_argument("--audio-keyword", help="Match track title, e.g. Crunchyroll / AniFilm")
    p.add_argument("--audio-exclude", help="Reject tracks whose title contains this")
    p.add_argument("--subtitle", help="Target subtitle language, or 'none' to disable")
    p.add_argument("--subtitle-keyword", help="Match subtitle title")
    p.add_argument("--subtitle-external", action="store_true",
                   help="Prefer external sidecar subtitles (.srt/.ass next to the file)")
    p.add_argument("--allow-forced", action="store_true", help="Allow forced subtitle tracks")
    p.add_argument("--limit", type=int, help="Process only the first N episodes")
    p.add_argument("--apply", action="store_true", help="Actually write changes (default: plan only)")
    p.add_argument("--undo", metavar="REPORT.json", help="Roll back: apply the 'before' ids recorded in a --json report")
    p.add_argument("--json", action="store_true", help="Machine-readable report")
    args = p.parse_args()
    if not args.show and not args.undo:
        raise SystemExit("Нужен --show <название> (или --undo <report.json>)")

    server, token = load_config()
    if args.server:
        server = args.server
    if args.token:
        token = args.token
    if not token:
        raise SystemExit("No Plex token: set PLEX_TOKEN or ~/.config/opencode/plex.yaml (url:, token:)")

    if args.undo:
        with open(args.undo, encoding="utf-8") as fh:
            saved = json.load(fh)
        restored = 0
        for e in saved.get("items", []):
            rk, part = e.get("ratingKey"), e.get("partId")
            if not rk or not part:
                continue
            for kind in ("audio", "subtitle"):
                back = (e.get(kind) or {}).get("before")
                if back is None:
                    continue
                status, _ = apply(server, token, part, back, kind)
                ok = verify(server, token, rk, back, kind)
                print("  %s (ep %s) %s -> id=%s %s" % (e.get("episode"), e.get("index"), kind, back,
                                                       "ok" if ok else "FAILED(%s)" % status))
                restored += 1 if ok else 0
        print("Восстановлено дорожек: %d" % restored)
        return

    shows = find_show(server, token, args.show, args.section)
    if not shows:
        raise SystemExit("Ничего не найдено по «%s»" % args.show)
    if len(shows) > 1:
        log("Найдено несколько совпадений:")
        for s in shows:
            log("  - %s (%s, section %s, ratingKey %s)" % (s["title"], s["type"], s["sectionTitle"], s["ratingKey"]))
        raise SystemExit("Уточни название или добавь --section")

    show = shows[0]
    log("Шоу: %s (ratingKey %s, section %s)" % (show["title"], show["ratingKey"], show["sectionTitle"]))

    report = []
    for item in season_items(server, token, show, args.season):
        if args.limit and len(report) >= args.limit:
            break
        rk = item.attrib["ratingKey"]
        # List endpoints (/all, /children) omit <Stream>: fetch full metadata per item.
        full = xml(server, "/library/metadata/%s" % rk, token)
        video = full.find("Video")
        item = full if video is None else video
        media = item.find("Media")
        part = media.find("Part") if media is not None else None
        if part is None:
            report.append({"episode": item.attrib.get("title"), "status": "no media part"})
            continue
        entry = {
            "episode": item.attrib.get("title"),
            "index": item.attrib.get("index"),
            "ratingKey": rk,
            "partId": part.attrib.get("id"),
            "file": part.attrib.get("file"),
        }
        entry["available"] = {
            kind: streams_of(item, kind) for kind in ("audio", "subtitle")
        }
        for kind, lang, codec, keyword, exclude, allow_forced, external in (
            ("audio", args.audio, args.audio_codec, args.audio_keyword, args.audio_exclude, False, False),
            ("subtitle", args.subtitle, None, args.subtitle_keyword, None, args.allow_forced,
             args.subtitle_external),
        ):
            if lang is None:
                continue
            streams = streams_of(item, kind)
            if not streams:
                entry[kind] = {"status": "no tracks of this kind"}
                continue
            if norm_lang(lang) in ("none", "off"):
                target = "0"
            else:
                chosen, candidates = pick(streams, lang, codec, keyword, exclude, allow_forced, external)
                if chosen is None:
                    entry[kind] = {"status": "no match",
                                   "available": [{"id": s["id"], "displayTitle": s["displayTitle"],
                                                 "codec": s["codec"], "title": s["title"]} for s in streams]}
                    continue
                if len(candidates) > 1:
                    entry[kind + "ambiguous"] = [{"id": c["id"], "displayTitle": c["displayTitle"],
                                                 "codec": c["codec"], "title": c["title"]} for c in candidates]
                target = chosen["id"]
            before = next((s["id"] for s in streams if s["selected"]), None)
            already = (before == target) or (target == "0" and before is None)
            info = {"target": target, "before": before,
                    "status": "unchanged" if already else "change"}
            if args.apply and info["status"] == "change":
                status, _ = apply(server, token, entry["partId"], target, kind)
                info["http"] = status
                info["after"] = verify(server, token, rk, target, kind)
                info["status"] = "applied" if info["after"] else "FAILED (write returned %s)" % status
            entry[kind] = info
        report.append(entry)

    if args.json:
        print(json.dumps({"show": show["title"], "count": len(report), "items": report},
                         ensure_ascii=False, indent=2))
        return

    for e in report:
        print("== %s  (ep %s, rk %s, part %s)" % (e["episode"], e.get("index"), e.get("ratingKey"), e.get("partId")))
        for kind in ("audio", "subtitle"):
            for s in e.get("available", {}).get(kind, []):
                tag = s["languageTag"] or s["languageCode"] or "?"
                extra = " [%s]" % s["title"] if s["title"] else ""
                flags = []
                if s["selected"]:
                    flags.append("ВЫБРАНО")
                if s["default"]:
                    flags.append("file-default")
                if s["forced"]:
                    flags.append("forced")
                if s["file"]:
                    flags.append("external")
                print("    %-4s id=%-5s %-3s %-6s %-24s%s  %s" % (
                    kind, s["id"], tag, s["codec"] or "", (s["displayTitle"] or "")[:24], extra,
                    " ".join(flags)))
            info = e.get(kind)
            if not info:
                continue
            if info.get("status") in ("no tracks of this kind", "no match"):
                print("  %s: %s" % (kind, info["status"]))
                if info.get("available"):
                    for s in info["available"]:
                        print("     id=%s %s (%s)" % (s["id"], s["displayTitle"], s["codec"]))
                continue
            print("  %s: %s -> id=%s (before id=%s)" % (kind, info["status"], info["target"], info.get("before")))
            for c in e.get(kind + "ambiguous", []):
                print("     кандидат: id=%s %s (%s)" % (c["id"], c["displayTitle"], c["codec"]))
        if not args.apply:
            print("  [план, ничего не изменено — добавь --apply]")
    print("\nОбработано эпизодов: %d%s" % (len(report), " (применено)" if args.apply else ""))


if __name__ == "__main__":
    main()
