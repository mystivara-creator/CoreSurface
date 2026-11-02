#!/system/bin/sh
# Creates one NEW private GitHub repo and pushes this exact source snapshot.
# Must be run intentionally by the repo owner, never as part of installation.
set -eu
TARGET=mystivara-creator/Kunzite-Capability-Suite
cd "$(dirname "$0")/.."
command -v gh >/dev/null 2>&1 || { echo 'Install GitHub CLI (gh) first'; exit 1; }
command -v git >/dev/null 2>&1 || { echo 'Install git first'; exit 1; }
LOGIN=$(gh api user --jq .login 2>/dev/null) || { echo 'Authenticate with gh auth login'; exit 1; }
[ "$LOGIN" = mystivara-creator ] || { echo "Wrong GitHub account: $LOGIN"; exit 1; }
[ -d .git ] || { echo 'Missing .git history; extract full repository ZIP'; exit 1; }
if gh repo view "$TARGET" >/dev/null 2>&1; then
  if git remote get-url origin >/dev/null 2>&1; then
    echo "Repo exists: checking origin"
    [ "$(git remote get-url origin)" = "https://github.com/$TARGET.git" ] || { echo 'Origin mismatch; refusing to push'; exit 1; }
  else
    git remote add origin "https://github.com/$TARGET.git"
  fi
  git push -u origin main
else
  gh repo create "$TARGET" --private --source=. --remote=origin --push
fi
echo "Published to https://github.com/$TARGET"
