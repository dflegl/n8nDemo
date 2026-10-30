#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Publish this repository to GitHub.
#
#   ./scripts/github-init.sh [owner] [repo-name]
#
# Defaults: owner=dflegl, repo-name=n8nDemo, visibility=public.
#
# The script is interactive where it has to be: if the target account is not
# present in the GitHub CLI it stops and tells you to run `gh auth login`.
# It never changes your global git configuration.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

cd "$REPO_DIR"

OWNER="${1:-dflegl}"
NAME="${2:-n8nDemo}"
VISIBILITY="public"
COMMIT_EMAIL="david.flegl@email.cz"
COMMIT_NAME="David Flegl"

require_cmd git
require_cmd gh "install the GitHub CLI: https://cli.github.com"

[ -d "$REPO_DIR/.git" ] || die "$REPO_DIR is not a git repository."

# --- repository-local identity ---------------------------------------------
# Scoped to this repository only. Your global/work identity is not touched.
git config user.name  "$COMMIT_NAME"
git config user.email "$COMMIT_EMAIL"
ok "Repository-local git identity: $COMMIT_NAME <$COMMIT_EMAIL>"

# --- account selection ------------------------------------------------------
log "Checking GitHub CLI authentication"
if ! gh auth status >/dev/null 2>&1; then
  die "The GitHub CLI is not authenticated. Run: gh auth login"
fi

if gh auth status 2>&1 | grep -q "account $OWNER "; then
  ok "Account '$OWNER' is known to the GitHub CLI"
else
  warn "Account '$OWNER' is not authenticated in the GitHub CLI."
  echo
  echo "  Run this, then re-run the script:"
  echo "      gh auth login --hostname github.com --web"
  echo "  and sign in as '$OWNER'."
  echo
  echo "  Already-authenticated accounts:"
  gh auth status 2>&1 | sed -n 's/.*account \([^ ]*\).*/    - \1/p'
  die "Aborted."
fi

current="$(gh api user --jq .login 2>/dev/null || echo '')"
if [ "$current" != "$OWNER" ]; then
  log "Switching the active GitHub CLI account to '$OWNER'"
  gh auth switch --hostname github.com --user "$OWNER"
  ok "Active account is now '$OWNER'"
fi

# --- commit -----------------------------------------------------------------
if [ -z "$(git log --oneline -1 2>/dev/null || true)" ]; then
  log "Creating the initial commit"
  git add -A
  git commit -q -m "Initial commit: n8n Community Edition sandbox"
  ok "Initial commit created"
elif ! git diff-index --quiet HEAD -- 2>/dev/null; then
  warn "You have uncommitted changes. Commit them before publishing."
  git status --short
  die "Aborted."
fi

# --- remote + push ----------------------------------------------------------
if git remote get-url origin >/dev/null 2>&1; then
  ok "Remote 'origin' already set: $(git remote get-url origin)"
  log "Pushing"
  git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
else
  log "Creating github.com/$OWNER/$NAME ($VISIBILITY) and pushing"
  gh repo create "$OWNER/$NAME" \
    --"$VISIBILITY" \
    --source=. \
    --remote=origin \
    --push \
    --description "Reproducible n8n Community Edition sandbox: Docker Compose, bootstrap script, host file-exchange directory."
fi

ok "Published: https://github.com/$OWNER/$NAME"
