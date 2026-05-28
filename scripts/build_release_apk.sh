#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f "$ROOT/.env" ]]; then
  echo "Missing $ROOT/.env — copy .env.example to .env and set CHANCE_UA_SECRET." >&2
  exit 1
fi

export JAVA_HOME="${JAVA_HOME:-/root/jdk-17}"
export ANDROID_HOME="${ANDROID_HOME:-/root/android-sdk}"
export PATH="/root/flutter/bin:${JAVA_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

exec "$ROOT/scripts/flutter" build apk --split-per-abi --release --android-skip-build-dependency-validation "$@"
