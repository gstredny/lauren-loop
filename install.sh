#!/bin/bash
# install.sh — Install Lauren Loop as a git submodule + scaffold project structure
set -e

TARGET="${1:-.}"
REPO="${LAUREN_LOOP_REPO:-git@github.com:gstredny/lauren-loop.git}"

[[ -d "$TARGET/.git" ]] || { echo "ERROR: $TARGET is not a git repo"; exit 1; }

echo "Adding Lauren Loop as submodule..."
if git -C "$TARGET" submodule status vendor/lauren-loop &>/dev/null; then
    echo "Submodule vendor/lauren-loop already registered — skipping add."
elif [[ -d "$TARGET/vendor/lauren-loop" ]]; then
    echo "ERROR: vendor/lauren-loop/ exists but is not a registered submodule."
    echo "Remove it manually and re-run: rm -rf vendor/lauren-loop"
    exit 1
else
    git -C "$TARGET" submodule add "$REPO" vendor/lauren-loop
fi

echo "Creating shim scripts..."
for script in lauren-loop.sh lauren-loop-v2.sh; do
  cat > "$TARGET/$script" << 'SHIM'
#!/bin/bash
# shim v1
export LAUREN_LOOP_PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$LAUREN_LOOP_PROJECT_DIR/vendor/lauren-loop/SCRIPT_NAME" "$@"
SHIM
  # Replace SCRIPT_NAME placeholder with actual script name
  sed -i.bak "s/SCRIPT_NAME/$script/" "$TARGET/$script" && rm -f "$TARGET/$script.bak"
  chmod +x "$TARGET/$script"
done

echo "Copying scaffold files (won't overwrite existing)..."
cp -rn "$TARGET/vendor/lauren-loop/scaffold/." "$TARGET/" 2>/dev/null || true
# Spot-check that scaffold landed
if [[ ! -f "$TARGET/prompts/project-rules.md.example" ]] && \
   [[ ! -f "$TARGET/prompts/project-rules.md" ]]; then
  echo "ERROR: scaffold copy failed — check permissions"; exit 1
fi

echo ""
echo "Installed. Next steps:"
echo "  1. Rename prompts/project-rules.md.example → prompts/project-rules.md"
echo "  2. Rename .lauren-loop.conf.example → .lauren-loop.conf"
echo "  3. Rename AGENTS.md.example → AGENTS.md (if not already present)"
echo "  4. Commit the changes"
