#!/usr/bin/env bash
# Fixture tests for the secret-scan action's scripts: they guard the trust model (a PR must not
# be able to weaken its own scan) and the install checksum. Needs network (downloads
# betterleaks via install.sh) and git. Run: bash .github/actions/secret-scan/tests/test-scan.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export RUNNER_TEMP="$WORK/runner-temp" GITHUB_PATH="$WORK/github_path"
mkdir -p "$RUNNER_TEMP"; : > "$GITHUB_PATH"

fails=0
check() { # check "description" expected_exit actual_exit
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected exit $2, got $3)"; fails=$((fails+1)); fi
}

echo "--- install"
bash "$HERE/install.sh" >/dev/null 2>&1; check "install.sh installs a verified binary" 0 $?
export PATH="$(tail -1 "$GITHUB_PATH"):$PATH"
betterleaks version >/dev/null 2>&1; check "betterleaks runs" 0 $?
sed 's/^VERSION=1.10.1$/VERSION=1.10.1/; s/SHA256=c174b42d/SHA256=00000000/; s/SHA256=62a63199/SHA256=00000000/' "$HERE/install.sh" > "$WORK/install-tampered.sh"
GITHUB_PATH="$WORK/gp2" bash "$WORK/install-tampered.sh" >/dev/null 2>&1; check "tampered checksum is rejected" 1 $?

# A fake, non-functional GitHub-PAT-shaped token (assembled so this file itself isn't a finding).
TOK="ghp_$(printf 'R7kD2mQx9ZpL4vNc8TbY1wHs6JfEa3UgXoKi')"
git_() { git -c user.email=t@t -c user.name=t "$@"; }

new_repo() { rm -rf "$WORK/repo"; mkdir "$WORK/repo"; cd "$WORK/repo" || exit 1; git_ init -q -b main; echo hello > a.txt; git_ add -A; git_ commit -q -m base; BASE="$(git rev-parse HEAD)"; }
scan() { # scan [LOG_OPTS_INPUT]; runs as a pull_request against $BASE..HEAD
  EVENT_NAME=pull_request BASE_SHA="$BASE" HEAD_SHA="$(git rev-parse HEAD)" LOG_OPTS_INPUT="${1:-}" bash "$HERE/scan.sh" >"$WORK/out.txt" 2>&1
}
fp_of_head() { betterleaks git --no-banner --redact --exit-code 0 --report-format json --report-path - --log-opts="$BASE..HEAD" . 2>/dev/null | grep -o '"Fingerprint": *"[^"]*"' | head -1 | sed 's/.*: *"//; s/"$//'; }

echo "--- scan: basic behavior"
new_repo; echo "also clean" > b.txt; git_ add -A; git_ commit -q -m clean; scan; check "clean PR passes" 0 $?
new_repo; printf 'token = "%s"\n' "$TOK" > leak.txt; git_ add -A; git_ commit -q -m leak; scan; check "secret in a PR commit is caught" 1 $?
grep -q "Fingerprint\|:leak.txt:" "$WORK/out.txt" && echo "PASS  fingerprint printed" || { echo "FAIL  fingerprint not printed"; fails=$((fails+1)); }
grep -q "$TOK" "$WORK/out.txt" && { echo "FAIL  secret value leaked into the log"; fails=$((fails+1)); } || echo "PASS  secret value is redacted in the log"

echo "--- scan: a PR must not weaken its own scan"
new_repo; printf 'token = "%s"\n' "$TOK" > leak.txt; git_ add -A; git_ commit -q -m leak
fp="$(fp_of_head)"; echo "$fp" > .betterleaksignore; git_ add -A; git_ commit -q -m "ignore it"
scan; check "ignore file added by the PR itself (later commit) is NOT honored" 1 $?
new_repo; printf 'token = "%s"\n' "$TOK" > leak.txt; git_ add -A; git_ commit -q -m leak
fp="$(fp_of_head)"; echo "$fp" > .gitleaksignore; git_ add -A; git_ commit -q -m "legacy ignore it"
scan; check "legacy .gitleaksignore added by the PR is NOT honored" 1 $?
new_repo; printf 'token = "%s"  # betterleaks:allow\n' "$TOK" > leak.txt; git_ add -A; git_ commit -q -m "inline allow"
scan; check "inline betterleaks:allow comment is NOT honored" 1 $?
new_repo; printf 'token = "%s"  # gitleaks:allow\n' "$TOK" > leak.txt; git_ add -A; git_ commit -q -m "inline legacy allow"
scan; check "inline gitleaks:allow comment is NOT honored" 1 $?
new_repo; printf 'token = "%s"\n' "$TOK" > leak.txt; printf '[allowlist]\nregexes = ["ghp_.*"]\n' > .betterleaks.toml; printf '[allowlist]\nregexes = ["ghp_.*"]\n' > .gitleaks.toml; git_ add -A; git_ commit -q -m "leak + allowlist config"
scan; check "malicious .betterleaks.toml/.gitleaks.toml in the PR is NOT loaded" 1 $?
betterleaks git --no-banner --redact --exit-code 10 --unsafe-auto-load-config --log-opts="$BASE..HEAD" . >/dev/null 2>&1
check "(control) that same config WOULD bypass if auto-loaded, so the test above is meaningful" 0 $?

echo "--- scan: baseline from the BASE branch IS honored"
new_repo; printf 'token = "%s"\n' "$TOK" > leak.txt; git_ add -A; git_ commit -q -m "old leak"; OLD="$(git rev-parse HEAD)"
fp="$(betterleaks git --no-banner --redact --exit-code 0 --report-format json --report-path - --log-opts="$BASE..$OLD" . 2>/dev/null | grep -o '"Fingerprint": *"[^"]*"' | head -1 | sed 's/.*: *"//; s/"$//')"
echo "$fp" > .betterleaksignore; git_ add -A; git_ commit -q -m "baseline (on base branch)"; BASE2="$(git rev-parse HEAD)"
echo "next change" > c.txt; git_ add -A; git_ commit -q -m "unrelated PR commit"
EVENT_NAME=pull_request BASE_SHA="$BASE2" HEAD_SHA="$(git rev-parse HEAD)" bash "$HERE/scan.sh" >"$WORK/out.txt" 2>&1; check "PR range after a base-branch baseline passes" 0 $?
EVENT_NAME=schedule bash "$HERE/scan.sh" >"$WORK/out.txt" 2>&1; check "full-history scan honors the checked-out baseline" 0 $?

new_repo; printf 'token = "%s"\n' "$TOK" > leak.txt; git_ add -A; git_ commit -q -m "leak (never baselined)"
EVENT_NAME=schedule bash "$HERE/scan.sh" >"$WORK/out.txt" 2>&1; check "full-history scan with no baseline catches the leak" 1 $?
new_repo; printf 'token = "%s"\n' "$TOK" > leak.txt; git_ add -A; git_ commit -q -m leak; ( cd "$WORK/repo" && EVENT_NAME=pull_request BASE_SHA="$BASE" HEAD_SHA="$(git rev-parse HEAD)" bash "$HERE/scan.sh" >"$WORK/out.txt" 2>&1 ); rc=$?
git status --porcelain | grep -q . && { echo "FAIL  scan modified the working tree"; fails=$((fails+1)); } || echo "PASS  scan leaves the working tree untouched"

echo "--- scan: misc"
new_repo; EVENT_NAME=pull_request_target BASE_SHA="$BASE" HEAD_SHA="$BASE" bash "$HERE/scan.sh" >"$WORK/out.txt" 2>&1; check "pull_request_target is refused" 1 $?
new_repo; EVENT_NAME=push LOG_OPTS_INPUT="not-a-ref..also-fake" bash "$HERE/scan.sh" >"$WORK/out.txt" 2>&1; rc=$?
check "a tool error fails the job" 1 $rc
grep -q "failed to run" "$WORK/out.txt" && echo "PASS  tool error is reported as a failure, not as findings" || { echo "FAIL  tool error mislabeled"; fails=$((fails+1)); }

echo
[ "$fails" -eq 0 ] && echo "ALL PASSED" || echo "$fails FAILED"
exit "$fails"
