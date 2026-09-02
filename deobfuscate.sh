#!/bin/bash
# ============================================================================
#  deobfuscate.sh: вернуть оригинальные имена в текст ошибки сборки, снятой с
#  ОБФУСЦИРОВАННОГО кода. Инструмент читает ConversionMap.json в обратную
#  сторону (обфусцированное -> оригинал) и переписывает только известные
#  обфусцированные идентификаторы; остальной текст не меняется.
#
#  Использование:
#      pbpaste | ./deobfuscate.sh /путь/к/Проекту | pbcopy   # из буфера (macOS)
#      ./deobfuscate.sh /путь/к/Проекту error.txt            # из файла
#      xcodebuild ... 2>&1 | ./deobfuscate.sh /путь/к/Проекту # весь лог сборки
#
#  В режиме с каталогом проекта карта берётся из <проект>/out/ConversionMap.json
#  (её пишет обфускация). Продвинутый режим: без каталога проекта все аргументы
#  уходят в `swiftprof deobfuscate` напрямую (--map, --replace, --annotate, -o).
# ============================================================================

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

# Собираем один раз и кладём бинарник в видимую папку swiftprof/. Вывод сборки в
# stderr, чтобы не попасть в stdout (важно для конвейера `| pbcopy`).
if [[ ! -x "$REPO/swiftprof/swiftprof" ]]; then
  echo "==> сборка SwiftProf (release)" >&2
  swift build -c release --package-path "$REPO" >&2
  mkdir -p "$REPO/swiftprof"
  cp -f "$REPO/.build/release/swiftprof" "$REPO/swiftprof/swiftprof"
fi
BIN="$REPO/swiftprof/swiftprof"

# Проектный режим: первый аргумент это каталог проекта -> карта известна.
if [[ -n "${1:-}" && -d "${1:-}" ]]; then
  PROJECT="$1"; shift
  MAP="$PROJECT/out/ConversionMap.json"
  if [[ ! -f "$MAP" ]]; then
    echo "ошибка: нет карты $MAP" >&2
    echo "        сначала обфусцируйте проект: ./obfuscate.sh $PROJECT" >&2
    exit 1
  fi
  exec "$BIN" deobfuscate --map "$MAP" "$@"
else
  # Продвинутый режим: аргументы напрямую в swiftprof deobfuscate.
  exec "$BIN" deobfuscate "$@"
fi
