#!/usr/bin/env bash
# Post a CI/CD failure notification to Slack via shovel.bot.
# Usage: ci_notify.sh <app_name> <sha> <actor> <run_url> [log_file]
#
# Reads SHOVEL_BOT_URL, SHOVEL_BOT_API_KEY, SHOVEL_BOT_CHANNEL from
# ~/.secrets/deployment_secrets.yml, deployed by the github-runner Ansible
# role on this host - not from any app's deployed .env file, so this works
# the same way regardless of which app is deployed to this host, and
# doesn't require the calling workflow to pass anything via env:.
set -euo pipefail

APP_NAME="$1"
SHA="${2:0:7}"
ACTOR="$3"
RUN_URL="$4"
LOG_FILE="${5:-}"

# shellcheck disable=SC1090
source "$HOME/.secrets/deployment_secrets.yml"

: "${SHOVEL_BOT_URL:?SHOVEL_BOT_URL must be set}"
: "${SHOVEL_BOT_API_KEY:?SHOVEL_BOT_API_KEY must be set}"
: "${SHOVEL_BOT_CHANNEL:?SHOVEL_BOT_CHANNEL must be set}"

export CI_APP="$APP_NAME"
export CI_SHA="$SHA"
export CI_ACTOR="$ACTOR"
export CI_RUN_URL="$RUN_URL"

if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    export CI_LOG_TAIL
    CI_LOG_TAIL=$(tail -20 "$LOG_FILE")
else
    export CI_LOG_TAIL=""
fi

python3 - <<'EOF'
import json, os, sys, urllib.request

url = os.environ["SHOVEL_BOT_URL"].rstrip("/")
api_key = os.environ["SHOVEL_BOT_API_KEY"]
channel = os.environ["SHOVEL_BOT_CHANNEL"]
app = os.environ["CI_APP"]
sha = os.environ["CI_SHA"]
actor = os.environ["CI_ACTOR"]
run_url = os.environ["CI_RUN_URL"]
log_tail = os.environ.get("CI_LOG_TAIL", "")

message = f"Pipeline failed on `{sha}` by {actor}\n<{run_url}|View full log>"
if log_tail.strip():
    message += f"\n\n```\n{log_tail[-1500:]}\n```"

payload = {
    "channel": channel,
    "app": "ci/cd",
    "severity": "error",
    "title": f"❌ Deploy failed: {app}",
    "message": message,
}

req = urllib.request.Request(
    f"{url}/notifications",
    data=json.dumps(payload).encode(),
    headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print(f"Notification sent: {resp.status}")
except Exception as e:
    print(f"Failed to send failure notification: {e}", file=sys.stderr)
    sys.exit(0)  # Never fail the CI job from the notification step itself
EOF
