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
  echo "  Run this, then re-run the script, signing in as '$OWNER':"
  echo "      gh auth login"
  echo
  echo "  Headless machine? Use a token with the repo, read:org and gist scopes:"
  echo "      gh auth login --with-token < token.txt"
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

# --- remote ------------------------------------------------------------------
# Three possible starting states, all of which must work on a re-run:
#   a) origin already configured      -> use it
#   b) repo exists on GitHub, no origin -> attach to it (e.g. created by hand)
#   c) repo does not exist            -> create it
DESCRIPTION="Reproducible n8n Community Edition sandbox: Docker Compose, bootstrap script, host file-exchange directory."

if git remote get-url origin >/dev/null 2>&1; then
  ok "Remote 'origin' already set: $(git remote get-url origin)"

elif gh repo view "$OWNER/$NAME" --json name >/dev/null 2>&1; then
  log "github.com/$OWNER/$NAME already exists - attaching to it"
  git remote add origin "https://github.com/$OWNER/$NAME.git"
  ok "Remote 'origin' added"

else
  log "Creating github.com/$OWNER/$NAME ($VISIBILITY)"
  if gh repo create "$OWNER/$NAME" \
       --"$VISIBILITY" \
       --description "$DESCRIPTION" >/dev/null 2>&1; then
    git remote add origin "https://github.com/$OWNER/$NAME.git"
    ok "Repository created and remote 'origin' added"
  else
    # Most common cause: the account is authenticated with a fine-grained PAT.
    # Those cannot create repositories unless the token grants
    # "Administration: write" on the account. Classic tokens need "repo".
    warn "Could not create the repository through the API."
    echo
    echo "  This usually means the token for '$OWNER' lacks permission to create"
    echo "  repositories. Fine-grained personal access tokens need"
    echo "  'Administration: write'; classic tokens need the 'repo' scope."
    echo
    echo "  Two ways forward:"
    echo "    1. Create it by hand at https://github.com/new"
    echo "         name:       $NAME"
    echo "         visibility: $VISIBILITY"
    echo "         do NOT add a README, .gitignore or licence"
    echo "       then re-run this script - it will attach to the existing repo."
    echo "    2. Re-authenticate with a token that may create repositories:"
    echo "         gh auth login"
    echo
    die "Aborted."
  fi
fi

# --- push ---------------------------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
log "Pushing '$BRANCH' to origin"
if ! git push -u origin "$BRANCH"; then
  echo
  warn "Push failed."
  echo "  A fine-grained token also needs 'Contents: write' on this repository."
  echo "  Check the token's permissions, then re-run this script."
  die "Aborted."
fi

ok "Published: https://github.com/$OWNER/$NAME"
