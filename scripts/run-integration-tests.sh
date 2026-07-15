#!/usr/bin/env bash
# Usage: scripts/run-integration-tests.sh [OPTIONS]
#
# Decrypts ~/.authinfo.gpg into ~/.authinfo, runs make test-integration,
# then restores the original ~/.authinfo regardless of test outcome.
#
# ~/.authinfo.gpg must contain entries for the forges you want to test:
#   machine api.github.com login USER^forge password TOKEN
#   machine gitlab.com     login USER^forge password TOKEN
#
# Batch Emacs cannot decrypt GPG files (no pinentry), so the plain-text
# file is written for the duration of the test run only.
#
# Options (env vars used as fallback when flag is omitted):
#   --github OWNER/REPO   GitHub repo to test  (FORGE_TEST_GITHUB_REPO)
#   --gitlab OWNER/REPO   GitLab repo to test  (FORGE_TEST_GITLAB_REPO)
# At least one must be provided; tests for the other forge are skipped.

set -euo pipefail

_fail() { echo "Error: $*" >&2; exit 1; }

github_repo="${FORGE_TEST_GITHUB_REPO:-}"
gitlab_repo="${FORGE_TEST_GITLAB_REPO:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github) github_repo="$2"; shift 2 ;;
    --gitlab) gitlab_repo="$2"; shift 2 ;;
    *) _fail "unknown option: $1" ;;
  esac
done

[[ -n "$github_repo" || -n "$gitlab_repo" ]] \
  || _fail "usage: $0 [--github OWNER/REPO] [--gitlab OWNER/REPO]  (at least one required)"

# Obtain tokens: prefer plaintext ~/.authinfo, fall back to decrypting ~/.authinfo.gpg.
if [[ -f "$HOME/.authinfo" ]]; then
  plaintext=$(cat "$HOME/.authinfo")
elif [[ -f "$HOME/.authinfo.gpg" ]]; then
  plaintext=$(gpg --quiet --batch --decrypt "$HOME/.authinfo.gpg" 2>/dev/null) \
    || _fail "GPG decryption failed — unlock your key first (e.g. gpg --card-status)"
else
  _fail "neither ~/.authinfo nor ~/.authinfo.gpg found"
fi

# Extract entries for whichever forges are being tested.
entries=""
if [[ -n "$github_repo" ]]; then
  gh_entries=$(printf '%s\n' "$plaintext" \
    | grep -E "machine[[:space:]]+api\.github\.com" || true)
  [[ -n "$gh_entries" ]] || _fail "no api.github.com entries in authinfo"
  entries+="$gh_entries"$'\n'
fi
if [[ -n "$gitlab_repo" ]]; then
  gl_entries=$(printf '%s\n' "$plaintext" \
    | grep -E "machine[[:space:]]+gitlab\.com" || true)
  [[ -n "$gl_entries" ]] || _fail "no gitlab.com entries in authinfo"
  entries+="$gl_entries"$'\n'
fi

# Write ~/.authinfo for the duration of the test run; restore on exit.
authinfo_existed=false
authinfo_backup=""
if [[ -f "$HOME/.authinfo" ]]; then
  authinfo_existed=true
  authinfo_backup=$(mktemp)
  cp "$HOME/.authinfo" "$authinfo_backup"
fi

{
  if $authinfo_existed; then
    grep -v -E "machine[[:space:]]+(api\.github\.com|gitlab\.com)" \
      "$authinfo_backup" || true
  fi
  printf '%s' "$entries"
} > "$HOME/.authinfo"
chmod 600 "$HOME/.authinfo"
unset plaintext entries gh_entries gl_entries

cleanup() {
  if $authinfo_existed; then
    mv "$authinfo_backup" "$HOME/.authinfo"
  else
    rm -f "$HOME/.authinfo"
  fi
}
trap cleanup EXIT

FORGE_TEST_GITHUB_REPO="$github_repo" \
FORGE_TEST_GITLAB_REPO="$gitlab_repo" \
  make test-integration
