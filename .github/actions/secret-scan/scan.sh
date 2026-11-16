#!/usr/bin/env bash
# Scan git history for secrets with betterleaks. Inputs (env): EVENT_NAME, BASE_SHA, HEAD_SHA,
# LOG_OPTS_INPUT. Run from the repository root; betterleaks must be on PATH.
#
# Trust model for pull requests: the PR author controls everything in the checked-out tree, so
# nothing in it may weaken the scan:
#   - the ignore file (.betterleaksignore / .gitleaksignore) is read from the PR's BASE commit,
#     never from the PR's own tree (otherwise a PR could add a secret and then a later commit
#     adding its fingerprint, and pass). betterleaks also reads an ignore file from the scanned
#     source directory regardless of --gitleaks-ignore-path, so the .git directory is scanned
#     as the source instead of the working tree (git history is the same; the working tree's
#     files are simply never consulted);
#   - inline `betterleaks:allow` / `gitleaks:allow` comments are not honored (same reason);
#   - betterleaks does not auto-load .betterleaks.toml / .gitleaks.toml from the scanned repo
#     (that needs --unsafe-auto-load-config, which we never pass; tests/ guards this).
# Accepted findings therefore have to be merged into the base branch's ignore file first.
set -euo pipefail

EVENT_NAME="${EVENT_NAME:-}"
BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-}"
LOG_OPTS_INPUT="${LOG_OPTS_INPUT:-}"

# Never send detected secrets to provider APIs. Off by default; set explicitly too, because
# explicit flags override BETTERLEAKS_VALIDATE / BETTERLEAKS_ANALYZE from the environment.
export BETTERLEAKS_VALIDATE=false BETTERLEAKS_ANALYZE=false

if [ "$EVENT_NAME" = "pull_request_target" ]; then
  echo "::error::secret-scan does not support pull_request_target (it runs in the base repo's context without the PR's commits). Use the pull_request trigger."
  exit 1
fi

TMP="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/secret-scan.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REPORT="$TMP/report.json"
ARGS=(--no-banner --redact --exit-code 10 --validation=false --ignore-gitleaks-allow
      --report-format json --report-path "$REPORT")
GIT_DIR="$(git rev-parse --absolute-git-dir)"

if [ "$EVENT_NAME" = "pull_request" ]; then
  : "${BASE_SHA:?BASE_SHA is required for pull_request events}"
  : "${HEAD_SHA:?HEAD_SHA is required for pull_request events}"
  DEFAULT_RANGE="${BASE_SHA}..${HEAD_SHA}"
  IGNORE_DIR="$TMP/ignore"
  mkdir -p "$IGNORE_DIR"
  for f in .betterleaksignore .gitleaksignore; do
    git show "${BASE_SHA}:${f}" > "$IGNORE_DIR/$f" 2>/dev/null || rm -f "$IGNORE_DIR/$f"
  done
  ARGS+=(--gitleaks-ignore-path "$IGNORE_DIR")
else
  DEFAULT_RANGE="--all"   # not attacker-controlled: schedule/push scan a branch we already merged
  ARGS+=(--gitleaks-ignore-path "$PWD")   # trusted: the checked-out ref's own baseline
fi
LOG_OPTS="${LOG_OPTS_INPUT:-$DEFAULT_RANGE}"

echo "Scanning git history with: --log-opts=$LOG_OPTS"
rc=0
betterleaks git "${ARGS[@]}" --log-opts="$LOG_OPTS" "$GIT_DIR" || rc=$?

if [ "$rc" -eq 10 ]; then
  echo "::error::betterleaks found potential secrets in the scanned commits"
  echo
  echo "Findings (fingerprint = commit:file:rule:line). A false positive or an accepted/rotated"
  echo "finding is suppressed by adding its fingerprint, with a comment saying why, to"
  echo ".betterleaksignore on the BASE branch (an ignore file changed in the PR itself is"
  echo "deliberately not honored):"
  if [ -s "$REPORT" ]; then
    grep -o '"Fingerprint": *"[^"]*"' "$REPORT" | sed 's/^"Fingerprint": *"//; s/"$//' | sort -u | sed 's/^/  /' || true
  else
    echo "  (report unavailable)"
  fi
  exit 1
elif [ "$rc" -ne 0 ]; then
  echo "::error::betterleaks failed to run (exit $rc)"
  exit "$rc"
fi
echo "No secrets found."
