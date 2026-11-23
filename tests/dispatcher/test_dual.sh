#!/usr/bin/env bash
. "$(dirname "$0")/_lib.sh"
echo "dual host dispatch"

TEMPLATE="$REPO/plugins/multi-agent-starter/skills/configure-multiagent/generator/templates/dual"
ROOT="$(new_root < "$TEMPLATE/_shared/backends.json")"
git -C "$ROOT" init -q
fake_bin "$ROOT" codex 0
cat > "$ROOT/_shared/bin/claude" <<'BASH'
#!/usr/bin/env bash
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then exit 6; fi
echo fake-claude-out
BASH
chmod +x "$ROOT/_shared/bin/claude"

approve "$ROOT" codex-main
BRIEF="$ROOT/tasks/t/workers/codex-main/brief.md"
echo 'write_scope: none' > "$BRIEF"
MULTIAGENT_ORCH=claude dispatch "$ROOT" codex-main "$BRIEF"
assert_eq "Claude host runs codex-main CLI" 0 "$RC"
assert_contains "codex CLI ran" fake-codex-out "$OUT"

MULTIAGENT_ORCH=codex dispatch "$ROOT" codex-main "$BRIEF"
assert_eq "Codex host keeps codex-main native" 1 "$RC"
assert_contains "dispatcher declines native workers" 'native/mcp' "$ERR"

approve "$ROOT" claude-critic
BRIEF="$ROOT/tasks/t/workers/claude-critic/brief.md"
echo 'write_scope: none' > "$BRIEF"
mkdir -p "$ROOT/tmp"
TMPDIR="$ROOT/tmp" MULTIAGENT_ORCH=codex dispatch "$ROOT" claude-critic "$BRIEF"
assert_eq "Codex host runs Claude critic CLI" 0 "$RC"
assert_contains "Claude CLI ran" fake-claude-out "$OUT"
assert_eq "Isolated worker ignores enclosing Git repo" skipped "$(jq -r .scope_check <<<"$OUT")"
assert_eq "Temporary workspace was removed" "" "$(ls -A "$ROOT/tmp")"

MULTIAGENT_ORCH=claude dispatch "$ROOT" claude-critic "$BRIEF"
assert_eq "Claude host cannot use the other host's critic" 2 "$RC"
MULTIAGENT_ORCH=invalid dispatch "$ROOT" claude-critic "$BRIEF"
assert_eq "Unknown namespace cannot use a worker" 2 "$RC"

rm -rf -- "$ROOT"
finish
