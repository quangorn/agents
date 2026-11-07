# Ловушки

Каждый пункт получен в реальной сессии на этой машине (Windows + Cygwin bash,
ffmpeg с NVENC, GPAC, dovi_tool, MKVToolNix, jq.exe). Не «упрощать» ни один из
них: все они стоят денег в виде пустых файлов, неправильных дорожек или
ложных выводов.

## Проверенные ловушки (дословно)

- `-avoid_negative_ts make_window` → `Undefined constant or missing '(' in
  'make_window'`; писать `1` / `make_zero`
- `-rc vbr_hq` → `Error opening output files: Invalid argument`
- `-profile:v main` в MKV → «not a suitable output format»; `-f mkv` невалидно
  → `matroska`
- `-c:a truehd` / `-c:a dca` → experimental, нужен `-strict -2`; без него rc=127
  и пустой файл
- PCM пишется и в MKV, и в MP4 (ffmpeg rc=0, проверено), так что ограничение не
  контейнер, а поддержка TV
- `-ss`/`-t` на входе **не** режут субтитры — работает только `-t` на выходе
  (`-c:s srt -t 20`)
- ffmpeg **не** кодирует PGS и не пишет `.sup`; `pgssub` — только decoder.
  Рабочий путь:
  ```
  FF -ss <t> -t 20 -i src.mkv -map 0:<sub> -c:s copy pgstemp.mkv
  mkvextract <pgstemp windows path> tracks 0:<name>.jpn.sup   # ID из `mkvmerge -i`, не предполагать
  ```
  magic `50 47` = "PG"
- mkvmerge/mkvextract/ffprobe падают на путях `/cygdrive/...` → нужен
  `cygpath -m`; closing quote после `"$(cygpath -m ...)"` обязателен
- write tool сохраняет CRLF → перед запуском bash делать `sed -i 's/\r$//'`

## cygpath: native-инструменты не понимают Cygwin-пути

`ffmpeg.exe`, `MP4Box.exe`, `dovi_tool.exe`, `mkvextract.exe` — Windows-бинарники.
Cygwin-путь они не понимают и падают:

```
ffmpeg ... -f hevc ~/tmp/dv2mp4.XXXX/BL_RPU.hevc
```

→ `No such file or directory`. Правило: `cygpath -m` (`~/tmp/x` → `D:/tmp/x`) для
каждого аргумента, который уходит в native-инструмент. Bash-встроенные команды
(перенаправления, `mktemp`, `cp`) остаются на Cygwin-пути. `mktemp -d` возвращает
Cygwin-путь, в который ffmpeg не может писать — это тоже нормализуется.

## Windows `jq.exe` выдаёт CRLF

Каждое значение из jq приходит с хвостовым `\r`, и это тихо ломает валидацию, а
не выдаёт ошибку:

```
"rus\r"        fails ^[a-z]{2,3}$      -> язык показан как "und"
"448000\r"     fails ^[0-9]+$          -> битрейт показан как "unknown"
"subrip\r"     misses the case arms    -> экспортирован как "unsupported"
```

Вывод jq всегда прогонять через `tr -d '\r'`. Скрипты централизуют это в одной
функции.

## В jq число `0` — truthy

```jq
if .disposition.forced then "1" else "0" end     # wrong: every track is "1"
if .disposition.forced == 1 then "1" else "0" end # right
```

В jq falsy только `false` и `null`. Проверять `== 1`, а не «истинность».

## `ffprobe -select_streams a:N` — НЕ абсолютный индекс

Самая опасная ловушка, потому что она молчит:

- `ffprobe -select_streams a -show_entries stream=index` печатает **абсолютные**
  индексы потоков (`1,2,3,4,5`).
- `ffprobe -select_streams a:1` — индекс **относительно типа «аудио»**.

Смешивание сдвигает все поля на число предшествующих потоков: аудиодорожка `1`
показывала данные дорожки `2`, одна дорожка читалась как пустая. `ffmpeg -map 0:N`
— абсолютный индекс, так что извлечение было правильным, а метаданные — ложными.

Рабочий путь: прочитать все потоки один раз в JSON и искать
`select(.index==$idx)`. Для lookup'а `-select_streams a:ID` не использовать
никогда.

## Смежные

- `-show_entries` вместе с `-show_streams` на ffmpeg 4.4 тихо теряет поля:
  `language` исчезал, таблица субтитров становилась бесполезной. Использовать
  plain `-show_streams -of json` и фильтровать через jq.
- Записи дорожек не собирать через `|`: в названиях очень часто встречается
  `Дубляж | Some Studio`, и поля разъезжаются. Разделитель — US (`0x1f`).
- `while IFS=$'\t' read -r a b c` схлопывает серии табуляций: пустые поля
  (пустое название, пустой язык) сдвигают всё вправо. Использовать JSON-строки.
- Долгое извлечение должно печатать heartbeat (каждые 20 s), иначе лог выглядит
  зависшим и сессия делает ложный вывод о «застрявшем» скрипте.
