# oshvl-ci-shared

Shared GitHub Actions CI tooling consumed by three independently-owned repos
(`orangeshovel`, `lonebirchlab`, `projectunmute`) that each run their own
self-hosted runner and deploy independently. Public so cross-owner `uses:`
references work with no access grant.

Referenced via floating `@main` — no version pinning. There's no CI gate in
this repo; a bad change here can break all three consumers' pipelines at
once. If that happens, revert here and the consumers pick it up on their
next run.

## Contents

- **`.github/actions/prepare-deploy/`** — composite action: checks out the
  calling repo, syncs it to `/opt/{app_name}/repo`, symlinks
  `/opt/{app_name}/current`, and sets up the Ansible tooling venv. Requires
  an `ansible_venv_path` input (this varies per consumer repo, since each
  self-hosted runner's OS user differs). Its `ansible-galaxy collection
  install` runs with `--force`: the self-hosted runners' collection cache
  (`~/.ansible/collections`) lives outside the per-run venv and persists
  across CI runs, so without `--force` a floating git-source collection
  (e.g. `orangeshovel/oshvl-ansible-shared`) can silently keep serving a
  stale cached copy after it's updated upstream.
- **`.github/actions/notify/`** — composite action wrapping `ci_notify.sh`:
  posts a Slack failure notification via shovel.bot. Bundles its own copy
  of the script (referenced via `${{ github.action_path }}`) so it can run
  from a job with no checkout step of its own.
- **`.github/workflows/claude.yml`**, **`claude-code-review.yml`** —
  reusable workflows (`workflow_call`) for `@claude`-comment handling and
  automated PR review via `anthropics/claude-code-action`. Each consumer
  repo keeps a thin wrapper workflow with its own `on:` triggers that calls
  into these via `uses:` and passes its own `ANTHROPIC_API_KEY` secret.
  **These reusable workflows deliberately declare no `permissions:` of
  their own** — cross-owner `workflow_call` fails at startup (`startup_failure`,
  zero jobs, no useful error message) if the *called* workflow requests
  permissions the caller doesn't already grant. The caller's thin wrapper
  must declare `permissions:` itself (see usage below); `id-token: write`
  in particular is required by `claude-code-action` for OIDC and its
  absence fails at the action-execution step with "Could not fetch an
  OIDC token" rather than at startup.

## Usage from a consumer repo

```yaml
- name: Prepare deploy
  uses: orangeshovel/oshvl-ci-shared/.github/actions/prepare-deploy@main
  with:
    app_name: shovel.bot
    service_user: shovel-bot
    ansible_venv_path: /home/oshvl-github-runner/ansible-venv
```

```yaml
- name: Notify on failure
  if: needs.setup.result == 'failure' || needs.ansible.result == 'failure'
  uses: orangeshovel/oshvl-ci-shared/.github/actions/notify@main
  with:
    app_name: shovel.bot
    sha: ${{ github.sha }}
    actor: ${{ github.actor }}
    run_url: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
    log_file: ${{ env.DEPLOY_LOG }}
```

```yaml
# .github/workflows/claude.yml in the consumer repo
name: Claude Code
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  pull_request_review:
    types: [submitted]
  issues:
    types: [opened]
jobs:
  claude:
    permissions:
      contents: write
      pull-requests: write
      issues: write
      id-token: write
      actions: read
    uses: orangeshovel/oshvl-ci-shared/.github/workflows/claude.yml@main
    secrets:
      anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
```

```yaml
# .github/workflows/claude-code-review.yml in the consumer repo
name: Claude Code Review
on:
  pull_request:
    types: [opened, synchronize]
concurrency:
  group: claude-code-review-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  review:
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
    uses: orangeshovel/oshvl-ci-shared/.github/workflows/claude-code-review.yml@main
    secrets:
      anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
```
