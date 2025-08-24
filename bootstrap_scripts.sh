#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/david-andreasson/scripts.git"
BRANCH="main"
TARGET_DIR="${HOME}/scripts"

# --- preflight ---
command -v git >/dev/null 2>&1 || { echo "git is required but not installed."; exit 1; }

mkdir -p "${TARGET_DIR}"

# --- work in a tmp folder to avoid clutter ---
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

echo "Cloning ${REPO_URL} (${BRANCH})..."
git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${TMP_DIR}/repo" >/dev/null

echo "Copying shell scripts to ${TARGET_DIR}..."
# copy only .sh files from repo root (adjust path if you later nest them)
find "${TMP_DIR}/repo" -maxdepth 1 -type f -name "*.sh" -print0 \
  | xargs -0 -I{} cp "{}" "${TARGET_DIR}/"

echo "Setting executable bit..."
chmod +x "${TARGET_DIR}"/*.sh

echo "Done. Files now in ${TARGET_DIR}:"
ls -1 "${TARGET_DIR}"
