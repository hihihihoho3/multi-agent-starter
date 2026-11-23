#!/usr/bin/env bash
. "$(dirname "$0")/_lib.sh"
echo "Windows agy argument and PTY capture"

ROOT="$(new_root <<'JSON'
{"flavor":"claude","workers":{"gemini":{"model":"agy-default","call_type":"cli","cli":{"command":"agy","args_template":["--prompt","@brief_content"]},"timeout":5}}}
JSON
)"
BIN="$ROOT/_shared/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo MINGW64_NT' > "$BIN/uname"
cat > "$BIN/agy" <<'BASH'
#!/usr/bin/env bash
[[ "$1" == --prompt && "$2" == *WINDOWS_BRIEF* ]] || exit 3
printf '\033[31mWINDOWS_OK\033[0m\n'
BASH
cat > "$BIN/winpty" <<'BASH'
#!/usr/bin/env bash
[[ "$1" == -Xallow-non-tty && "$2" == agy ]] || exit 4
read -r -t 0.1 line
[[ $? -gt 128 ]] || exit 5
echo fake-winpty-active >&2
shift
exec "$@"
BASH
touch "$BIN/agy.exe"
chmod +x "$BIN/uname" "$BIN/agy" "$BIN/winpty"

approve "$ROOT" gemini
BRIEF="$ROOT/tasks/t/workers/gemini/brief.md"
printf 'write_scope: none\nWINDOWS_BRIEF\n' > "$BRIEF"
dispatch "$ROOT" gemini "$BRIEF"
assert_eq "callback accepted flag and expanded brief" 0 "$RC"
assert_eq "PTY output is stripped of ANSI" WINDOWS_OK "$(jq -r '.stdout | rtrimstr("\n")' <<<"$OUT")"
assert_contains "winpty path kept stdin open" fake-winpty-active "$OUT"

rm -rf -- "$ROOT"
finish
