#!/usr/bin/env bash
# call_worker.sh — backends.json 디스패처 (cli/api 전용).
# native/mcp는 오케스트레이터가 직접 호출(디스패처 비경유).
# 사용: call_worker.sh <role> <brief-file>
# 반환: stdout에 result envelope(JSON). exit 0=성공, 비0=실패/거부.
set -euo pipefail

# ── 임시자원 추적 + 강제 정리(die·인터럽트·정상 모두) ──
_TMPS=()
cleanup() { local p; for p in "${_TMPS[@]:-}"; do [ -n "$p" ] && rm -rf -- "$p"; done; return 0; }  # 항상 0: EXIT trap이 종료코드 덮어쓰지 않도록
trap cleanup EXIT INT TERM
mktmp()  { local t; t="$(mktemp)";    _TMPS+=("$t"); printf '%s' "$t"; }
mktmpd() { local t; t="$(mktemp -d)"; _TMPS+=("$t"); printf '%s' "$t"; }

die() { echo "call_worker: $1" >&2; exit "${2:-1}"; }

ROLE="${1:-}"; BRIEF="${2:-}"
[ -n "$ROLE" ] && [ -n "$BRIEF" ] || die "usage: call_worker.sh <role> <brief-file>" 64

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${MULTIAGENT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BACKENDS="$ROOT/_shared/backends.json"


# Windows agy.exe prints through a TTY drip renderer. If this dispatcher is
# launched from WSL/Linux while targeting the Gemini/agy worker, agy can exit 0
# with empty stdout because the MINGW/MSYS winpty branch below cannot activate.
# Re-enter through Git-Bash when available so uname=MINGW* and winpty capture is
# used. This keeps WSL sessions from producing false-success empty Gemini results.
to_gitbash_path() {
  local p="$1" drive rest
  case "$p" in
    /mnt/[a-zA-Z]/*)
      drive="${p:5:1}"; rest="${p:7}"
      printf '/%s/%s' "$drive" "$rest" ;;
    *) return 1 ;;
  esac
}
if [ "$ROLE" = "gemini" ] && [ "${MAT_GITBASH_REEXEC:-0}" != "1" ]; then
  if [ "$(uname -s 2>/dev/null || true)" = "Linux" ] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    GIT_BASH=""
    for cand in "/mnt/c/Program Files/Git/bin/bash.exe" "/mnt/c/Program Files/Git/usr/bin/bash.exe"; do
      [ -x "$cand" ] && { GIT_BASH="$cand"; break; }
    done
    if [ -n "$GIT_BASH" ]; then
      case "$BRIEF" in /*) BRIEF_ABS="$BRIEF";; *) BRIEF_ABS="$(pwd)/$BRIEF";; esac
      if ROOT_GB="$(to_gitbash_path "$ROOT")" && BRIEF_GB="$(to_gitbash_path "$BRIEF_ABS")"; then
        printf -v ROOT_Q '%q' "$ROOT_GB"
        printf -v BRIEF_Q '%q' "$BRIEF_GB"
        printf -v ROLE_Q '%q' "$ROLE"
        printf -v NS_Q '%q' "${MULTIAGENT_ORCH:-}"
        exec "$GIT_BASH" -lc "cd $ROOT_Q && export MAT_GITBASH_REEXEC=1 && export MULTIAGENT_ORCH=$NS_Q && bash _shared/adapters/call_worker.sh $ROLE_Q $BRIEF_Q"
      fi
    fi
  fi
fi

command -v jq >/dev/null 2>&1 || die "jq 필요(JSON 파싱)" 5
[ -f "$BACKENDS" ] || die "backends.json 없음: $BACKENDS" 5

# backends schema v2(dual): 활성 오케스트레이터 네임스페이스 결정.
# backends schema v1(single): top-level .workers 를 사용한다.
HAS_ORCH="$(jq -r 'has("orchestrators")' "$BACKENDS")"
NS="${MULTIAGENT_ORCH:-}"
if [ "$HAS_ORCH" = "true" ]; then
  # 우선순위: 환경변수 MULTIAGENT_ORCH > backends.json 의 .active.
  # 각 오케스트레이터(claude/codex)는 자기 호출 시 MULTIAGENT_ORCH=<self> 를 export 한다.
  [ -n "$NS" ] || NS="$(jq -r '.active // empty' "$BACKENDS")"
  [ -n "$NS" ] || die "활성 오케스트레이터 미지정(MULTIAGENT_ORCH 또는 backends.json .active)" 2
  jq -e --arg ns "$NS" '.orchestrators[$ns]' "$BACKENDS" >/dev/null 2>&1 \
    || die "알 수 없는 오케스트레이터 네임스페이스: $NS" 2
else
  NS="$(jq -r '.flavor // "single"' "$BACKENDS")"
fi

# timeout: coreutils timeout/gtimeout 우선, 없으면 portable bash 폴백(둘 다 유한 보장)
TIMEOUT_BIN=""
command -v timeout  >/dev/null 2>&1 && TIMEOUT_BIN=timeout
[ -z "$TIMEOUT_BIN" ] && command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN=gtimeout
run_limited() {  # run_limited <secs> -- <cmd...>
  local t="$1"; shift; [ "$1" = "--" ] && shift
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" -k 5 "$t" "$@"; return $?; fi
  # 폴백: python3 러너(결정적, 프로세스그룹 TERM→KILL). python3은 시스템 필수 의존성.
  command -v python3 >/dev/null 2>&1 || die "timeout 유틸 또는 python3 필요" 5
  python3 "$SCRIPT_DIR/_run.py" "$t" "$@"; return $?
}

# brief 절대경로화 + 검증 ('--'로 옵션 하이재킹 방어)
case "$BRIEF" in *..*) die "brief 경로에 '..' 금지" 6;; esac
[ -f "$BRIEF" ] || die "brief 파일 없음: $BRIEF" 6
BRIEF="$(cd "$(dirname -- "$BRIEF")" && pwd)/$(basename -- "$BRIEF")"

if [ "$HAS_ORCH" = "true" ]; then
  rec="$(jq -c --arg ns "$NS" --arg r "$ROLE" '.orchestrators[$ns].workers[$r] // empty' "$BACKENDS")"
  [ -n "$rec" ] || die "role 미정의(orchestrator=$NS): $ROLE" 2
else
  rec="$(jq -c --arg r "$ROLE" '.workers[$r] // empty' "$BACKENDS")"
  [ -n "$rec" ] || die "role 미정의(flavor=$NS): $ROLE" 2
fi

redact() { sed -E 's/[A-Za-z0-9_-]{32,}/[REDACTED]/g'; }

# 단일 backend 실행 → envelope(JSON)을 stdout, exit code 반환
run_backend() {
  local spec="$1" ctype bmode tmo cwdp model wd out err errd rc start dur agy_pty=0
  ctype="$(jq -r '.call_type' <<<"$spec")"
  model="$(jq -r '.model // "?"' <<<"$spec")"
  case "$ctype" in
    native|mcp) die "native/mcp는 오케스트레이터 직접 호출(디스패처 비경유)" 3 ;;
    cli|api) ;;
    *) die "잘못된 call_type: $ctype" 7 ;;
  esac
  bmode="$(jq -r '.brief_mode // "content"' <<<"$spec")"
  tmo="$(jq -r '.timeout // 300' <<<"$spec")"
  cwdp="$(jq -r '.cwd_policy // "repo_root"' <<<"$spec")"

  case "$cwdp" in
    isolated_tmp) wd="$(mktmpd)";;
    target)       wd="${TARGET_REPO:-$ROOT}";;
    *)            wd="$ROOT";;
  esac

  local -a cmd=()
  if [ "$ctype" = "cli" ]; then
    local command_bin args_json a
    command_bin="$(jq -r '.cli.command' <<<"$spec")"
    case "$command_bin" in agy|codex|claude) ;; *) die "command allowlist 위반: $command_bin" 7;; esac
    cmd+=("$command_bin")
    args_json="$(jq -r '.cli.args_template[]' <<<"$spec")"   # jq 실패 시 set -e 트리거
    while IFS= read -r a; do
      a="${a%$'\r'}"   # Windows jq.exe는 CRLF 출력 → 인자 끝 \r 제거(없으면 agy가 '--model\r' 등으로 거부)
      case "$a" in
        "@brief")         cmd+=("$BRIEF");;
        "@brief_content") cmd+=("$(cat -- "$BRIEF")");;
        *)                cmd+=("$a");;
      esac
    done <<<"$args_json"
    # Windows(MSYS/Cygwin): agy --print는 TTY drip 렌더라 비-TTY stdout엔 0바이트.
    # winpty로 의사 TTY를 부여해 캡처 가능하게 한다(있을 때만). 출력엔 ANSI/drip 섞임 → 사후 _deansi.py 정리.
    if [ "$command_bin" = "agy" ]; then
      case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)
          if command -v winpty >/dev/null 2>&1; then
            cmd=("winpty" "-Xallow-non-tty" "${cmd[@]}"); agy_pty=1
          fi ;;
      esac
    fi
    # codex 워커: 기본은 git 요구(안전망). git 없으면 명확히 실패. 옵트아웃 시에만 우회.
    if [ "$command_bin" = "codex" ]; then
      if [ "${MULTIAGENT_CODEX_SKIP_GIT:-0}" = "1" ]; then
        local -a _nc=(); local _ins=0 _x
        for _x in "${cmd[@]}"; do
          _nc+=("$_x")
          if [ "$_ins" = 0 ] && [ "$_x" = "exec" ]; then _nc+=("--skip-git-repo-check"); _ins=1; fi
        done
        cmd=("${_nc[@]}")
      elif ! command -v git >/dev/null 2>&1; then
        die "codex 워커는 git이 필요합니다. git 설치 후 재시도하거나, 위험을 감수하면 MULTIAGENT_CODEX_SKIP_GIT=1 로 우회하세요." 8
      fi
    fi
  else
    local ref reqenv brief_pass
    ref="$(jq -r '.api.ref' <<<"$spec")"
    case "$ref" in adapters/*) ;; *) die "api.ref는 adapters/ 내부만" 7;; esac
    case "$ref" in *..*) die "api.ref에 '..' 금지" 7;; esac
    [ -f "$ROOT/_shared/$ref" ] || die "api 스크립트 없음: $ref" 4
    while IFS= read -r reqenv; do
      [ -n "$reqenv" ] || continue
      [ -n "${!reqenv:-}" ] || die "필수 env 없음: $reqenv" 4
    done < <(jq -r '.api.required_env[]? // empty' <<<"$spec")
    brief_pass="$(jq -r '.api.brief_pass // "arg1"' <<<"$spec")"
    cmd+=("bash" "$ROOT/_shared/$ref")
    [ "$brief_pass" = "arg1" ] && cmd+=("$BRIEF")
    [ "$brief_pass" = "stdin" ] && bmode="stdin"
  fi

  out="$(mktmp)"; err="$(mktmp)"; errd="$(mktmp)"
  start=$(date +%s)
  rc=0
  (
    cd "$wd" || exit 70
    export CI=1 DEBIAN_FRONTEND=noninteractive
    if [ "$bmode" = "stdin" ]; then
      run_limited "$tmo" -- "${cmd[@]}" <"$BRIEF"
    elif [ "$agy_pty" = "1" ]; then
      # winpty+agy --print는 stdin이 즉시 EOF면(/dev/null·닫힌 파이프) 출력 0바이트로
      # 조기 종료한다. timeout 동안 열린(비-EOF) stdin을 공급해야 PTY가 유지되고
      # agy가 응답을 낸다. agy는 timeout 전에 끝나며 sleep은 그 후 정리된다.
      run_limited "$tmo" -- "${cmd[@]}" < <(sleep "$tmo")
    else
      run_limited "$tmo" -- "${cmd[@]}" </dev/null
    fi
  ) >"$out" 2>"$err" || rc=$?
  dur=$(( $(date +%s) - start ))

  # agy(winpty) 출력 정리: ANSI 제거 + drip 줄당 최장 \r-세그먼트 채택(최종 상태 복원)
  if [ "$agy_pty" = "1" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$SCRIPT_DIR/_deansi.py" <"$out" >"$out.clean" 2>/dev/null && mv -f "$out.clean" "$out"
  fi

  local status="ok"
  [ "$rc" -ne 0 ] && status="error"
  [ "$rc" -eq 124 ] && status="timeout"

  redact <"$err" >"$errd"
  jq -n --arg status "$status" --argjson exit "$rc" \
        --rawfile stdout "$out" --rawfile stderr "$errd" \
        --argjson dur "$dur" --arg backend "$ctype" --arg model "$model" \
        '{status:$status, exit_code:$exit, backend:$backend, model:$model,
          duration_s:$dur, stdout:$stdout, stderr_sanitized:$stderr}'
  return "$rc"
}

# primary → 실패 시 fallbacks 순차 (set -e 우회: || prc=$?)
prc=0; env_primary="$(run_backend "$rec")" || prc=$?
if [ "$prc" -eq 0 ]; then
  jq -n --argjson e "$env_primary" '$e + {fallback_used:false}'
  exit 0
fi
nf="$(jq '.fallbacks | length' <<<"$rec")"
env_fb=""; i=0
while [ "$i" -lt "${nf:-0}" ]; do
  fb="$(jq -c --argjson i "$i" '.fallbacks[$i]' <<<"$rec")"
  frc=0; env_fb="$(run_backend "$fb")" || frc=$?
  if [ "$frc" -eq 0 ]; then
    jq -n --argjson e "$env_fb" '$e + {fallback_used:true}'
    exit 0
  fi
  i=$((i+1))
done
jq -n --argjson e "${env_fb:-$env_primary}" '$e + {fallback_used:true}'
exit 1
