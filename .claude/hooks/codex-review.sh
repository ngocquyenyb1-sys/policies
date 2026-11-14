#!/usr/bin/env bash
# Stop hook: when Claude finishes a turn with uncommitted code changes,
# ask Codex CLI to review them. If Codex finds problems, block the stop
# and hand the warnings back to Claude. Each distinct diff is reviewed once.
set -uo pipefail

input=$(cat)
# Avoid loops: if this stop was already triggered by a previous block, let it pass.
if printf '%s' "$input" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
command -v codex >/dev/null 2>&1 || exit 0

# Nothing changed -> nothing to review.
changes=$( { git diff HEAD 2>/dev/null; git ls-files --others --exclude-standard -z 2>/dev/null | xargs -0 -r cat 2>/dev/null; } )
[ -z "$changes" ] && exit 0

state_dir="$(git rev-parse --git-dir)/codex-review"
mkdir -p "$state_dir"
hash=$(printf '%s' "$changes" | sha256sum | cut -c1-16)
[ -f "$state_dir/$hash" ] && exit 0

# Log in once per container. The real key is injected by the network proxy.
if ! codex login status >/dev/null 2>&1; then
  echo "sk-proxy-injected" | codex login --with-api-key >/dev/null 2>&1 || exit 0
fi

out="$state_dir/$hash.md"
prompt='You are reviewing uncommitted changes in this git repo (run `git diff HEAD` and inspect untracked files from `git status`). Review ONLY those changes for: bugs, security issues, broken logic, performance problems, and bad practices. Be concise. List each problem as: [HIGH|MEDIUM|LOW] file:line - problem - suggested fix. If there are no real problems, reply with exactly: NO_ISSUES'

if ! timeout 300 codex exec --skip-git-repo-check -s read-only --output-last-message "$out" "$prompt" >/dev/null 2>&1; then
  echo "Codex review failed or timed out; skipping." >&2
  exit 0
fi
touch "$state_dir/$hash"

result=$(cat "$out" 2>/dev/null)
if [ -z "$result" ] || printf '%s' "$result" | grep -qx 'NO_ISSUES'; then
  echo "Codex review: no issues found." >&2
  exit 0
fi

python3 -c 'import json,sys; print(json.dumps({"decision":"block","reason":"⚠️ CODEX REVIEW WARNINGS — review these, fix real problems, and tell the user (in Vietnamese) what Codex flagged and what you changed:\n\n"+sys.stdin.read()}))' <<<"$result"
exit 0
