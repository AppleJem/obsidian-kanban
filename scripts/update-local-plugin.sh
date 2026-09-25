#!/usr/bin/env bash
set -euo pipefail

# Updates the Kanban plugin in a local Obsidian vault.
#
# Usage:
#   ./scripts/update-local-plugin.sh            install the latest CI build from GitHub
#   ./scripts/update-local-plugin.sh --local    build the current working tree and install it
#   ./scripts/update-local-plugin.sh --help     show this help
#
# Environment:
#   KANBAN_PLUGIN_DIR   target plugin directory
#                       (default: ~/Obsidian/.obsidian/plugins/obsidian-kanban)
#
# If the CI build cannot be downloaded, the script falls back to a local build.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="${KANBAN_PLUGIN_DIR:-$HOME/Obsidian/.obsidian/plugins/obsidian-kanban}"
ARTIFACT_NAME="obsidian-kanban-build"
PLUGIN_FILES=(main.js styles.css manifest.json)

usage() { sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

mode="${1:---github}"

if [ "$mode" = "--help" ] || [ "$mode" = "-h" ]; then
  usage
  exit 0
fi

if [ ! -d "$PLUGIN_DIR" ]; then
  echo "error: plugin directory not found: $PLUGIN_DIR" >&2
  exit 1
fi

build_local() {
  echo ">> Building from $REPO_DIR ..."
  (cd "$REPO_DIR" && yarn build >/dev/null)
  src="$REPO_DIR"
}

download_ci_build() {
  echo ">> Looking up latest CI build on main ..."
  cd "$REPO_DIR"
  local repo_slug run_id
  # Derive the target repo from 'origin' explicitly: gh would otherwise
  # prefer the 'upstream' remote in this checkout.
  repo_slug=$(git remote get-url origin \
    | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
  run_id=$(gh run list --repo "$repo_slug" --workflow build.yml \
    --branch main --status success --limit 1 --json databaseId --jq '.[0].databaseId')

  if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
    echo "!! No successful CI build found on main." >&2
    return 1
  fi

  CLEANUP_DIR=$(mktemp -d)

  echo ">> Downloading artifact from run #$run_id ..."
  if ! gh run download "$run_id" --repo "$repo_slug" --name "$ARTIFACT_NAME" --dir "$CLEANUP_DIR"; then
    echo "!! Could not download the CI artifact (missing 'actions: read' scope?)." >&2
    return 1
  fi

  # gh extracts either into the target dir or into a subdirectory named
  # after the artifact.
  if [ -f "$CLEANUP_DIR/main.js" ]; then
    src="$CLEANUP_DIR"
  elif [ -f "$CLEANUP_DIR/$ARTIFACT_NAME/main.js" ]; then
    src="$CLEANUP_DIR/$ARTIFACT_NAME"
  else
    echo "!! Artifact did not contain main.js" >&2
    return 1
  fi
}

if [ "$mode" = "--local" ]; then
  build_local
else
  download_ci_build || {
    echo ">> Falling back to a local build ..."
    build_local
  }
fi

for f in "${PLUGIN_FILES[@]}"; do
  if [ ! -f "$src/$f" ]; then
    echo "error: build is missing $f" >&2
    [ -n "${CLEANUP_DIR:-}" ] && rm -rf "$CLEANUP_DIR"
    exit 1
  fi
done

old_version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$PLUGIN_DIR/manifest.json")
new_version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$src/manifest.json")

echo ">> Installing into $PLUGIN_DIR ..."
for f in "${PLUGIN_FILES[@]}"; do
  cp "$src/$f" "$PLUGIN_DIR/$f"
done

# Marker file for the Hot Reload plugin, so Obsidian picks up changes
# without a restart. Harmless if Hot Reload is not installed.
touch "$PLUGIN_DIR/.hotreload"

[ -n "${CLEANUP_DIR:-}" ] && rm -rf "$CLEANUP_DIR"

echo ">> Done. Kanban $old_version -> $new_version"
echo ">> If Hot Reload is enabled, the plugin has already reloaded; otherwise restart Obsidian (Cmd+R)."
