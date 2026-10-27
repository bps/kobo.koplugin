#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
: "${KOREADER_BASE:?Set KOREADER_BASE to a koreader-base checkout}"
command -v luajit >/dev/null
command -v timeout >/dev/null
export PATH="$PWD/test/integration/fixtures:$PATH"

for suite in test/integration/*_test.lua; do
    echo "Running $suite"
    timeout 20 luajit "$suite"
done
