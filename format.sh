#!/usr/bin/env bash

set -euo pipefail

# Always run from the repository root (directory containing this script).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v tofu >/dev/null 2>&1; then
	echo "Error: 'tofu' CLI is not installed or not in PATH." >&2
	exit 1
fi

echo "Formatting Terraform/OpenTofu files..."
tofu fmt -recursive .
echo "Done."
