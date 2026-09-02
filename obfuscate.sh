#!/bin/bash
# ============================================================================
#  obfuscate.sh: собрать SwiftProf (если нужно) и обфусцировать проект.
#
#  Использование:
#      ./obfuscate.sh /путь/к/Проекту
#
#  В каталоге проекта должен лежать swiftprof.yaml (скопируйте туда
#  swiftprof.yaml и впишите пути к модулям в секции module).
#
#  Скрипт собирает инструмент (release) и кладёт бинарник в видимую папку
#  swiftprof/ рядом со скриптом (не в скрытую .build), чтобы его было легко
#  найти и запустить руками. Деобфускация ошибок: ./deobfuscate.sh.
#
#  ВНИМАНИЕ: обфускация переписывает исходники проекта НА МЕСТЕ. Запускайте на
#  копии проекта или под git, чтобы вернуть дерево после сборки архива.
# ============================================================================

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PROJECT="${1:-}"

if [[ -z "$PROJECT" ]]; then
  echo "использование: $0 /путь/к/Проекту" >&2
  exit 1
fi
if [[ ! -d "$PROJECT" ]]; then
  echo "ошибка: не каталог: $PROJECT" >&2
  exit 1
fi
if [[ ! -f "$PROJECT/swiftprof.yaml" && ! -f "$PROJECT/swiftprof.yml" ]]; then
  echo "ошибка: в $PROJECT нет swiftprof.yaml" >&2
  echo "        скопируйте туда $REPO/swiftprof.yaml и укажите пути к модулям." >&2
  exit 1
fi

echo "==> сборка SwiftProf (release)"
swift build -c release --package-path "$REPO"

# Кладём бинарник в видимую папку swiftprof/ (а не в скрытую .build).
mkdir -p "$REPO/swiftprof"
cp -f "$REPO/.build/release/swiftprof" "$REPO/swiftprof/swiftprof"
BIN="$REPO/swiftprof/swiftprof"

echo "==> обфускация $PROJECT (на месте)"
( cd "$PROJECT" && "$BIN" )

echo "==> готово. Отчёты в каталоге вывода проекта (по умолчанию $PROJECT/out)."
echo "    Проверьте, что проект собирается; вернуть исходники: git restore ."
echo "    Ошибку сборки из обфусцированного кода читать так: ./deobfuscate.sh."
