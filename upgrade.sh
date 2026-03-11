#!/bin/bash
# upgrade.sh — Pull latest Lauren Loop + diff scaffold for new files
set -e

PROJECT_DIR="${1:-$(cd "$(dirname "$0")" && pwd)}"

if [[ ! -d "$PROJECT_DIR/vendor/lauren-loop" ]]; then
  echo "ERROR: No vendor/lauren-loop submodule found in $PROJECT_DIR"
  echo "Run install.sh first."
  exit 1
fi

echo "Updating Lauren Loop submodule..."
git -C "$PROJECT_DIR" submodule update --remote vendor/lauren-loop

echo ""
echo "Checking for new scaffold files..."
diff_output=$(diff -rq "$PROJECT_DIR/vendor/lauren-loop/scaffold/" "$PROJECT_DIR/" 2>/dev/null \
  | grep "^Only in.*vendor/lauren-loop/scaffold" || true)

if [[ -n "$diff_output" ]]; then
  echo "New scaffold files available:"
  echo "$diff_output"
  echo ""
  echo "Copy with: cp -rn vendor/lauren-loop/scaffold/. ./"
else
  echo "No new scaffold files."
fi

# Check for updated .example files (reference docs that may have new config options)
echo ""
echo "Checking for updated reference files..."
updated_examples=""
while IFS= read -r -d '' scaffold_file; do
  relative="${scaffold_file#$PROJECT_DIR/vendor/lauren-loop/scaffold/}"
  project_file="$PROJECT_DIR/$relative"
  if [[ -f "$project_file" ]] && ! diff -q "$scaffold_file" "$project_file" &>/dev/null; then
    updated_examples+="  $relative"$'\n'
  fi
done < <(find "$PROJECT_DIR/vendor/lauren-loop/scaffold" -name '*.example' -print0 2>/dev/null)

if [[ -n "$updated_examples" ]]; then
  echo "Updated reference files (your copies differ from upstream):"
  printf '%s' "$updated_examples"
  echo "Review changes with: diff <project-file> vendor/lauren-loop/scaffold/<file>"
else
  echo "No updated reference files."
fi

echo ""
echo "Submodule updated. Review: git diff --cached"
