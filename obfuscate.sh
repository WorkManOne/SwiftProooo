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

BIN="$REPO/.build/release/swiftprof"
echo "==> обфускация $PROJECT (на месте)"
( cd "$PROJECT" && "$BIN" )

echo "==> готово. Отчёты в каталоге вывода проекта (по умолчанию $PROJECT/out)."
echo "    Проверьте, что проект собирается; вернуть исходники: git restore ."
