#!/usr/bin/env bash
# Regenerate the Drift code, then format it at the project's line width.
# build_runner always writes 80-column code and has no width option, so the
# format step is what keeps the generated file identical to what
# `dart format` expects (no formatting-only diffs).
set -euo pipefail
cd "$(dirname "$0")/.."
dart run build_runner build --delete-conflicting-outputs
dart format lib/data/db/app_database.g.dart
