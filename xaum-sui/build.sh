#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_DIR="${SCRIPT_DIR}/packages"

for dir in "${PACKAGES_DIR}"/*/; do
  if [[ -d "$dir" ]]; then
    name="$(basename "$dir")"
    echo ">>> Building package: $name"
    (cd "$dir" && sui move build) || exit 1
    echo ">>> Done: $name"
  fi
done

echo "All packages built successfully."
