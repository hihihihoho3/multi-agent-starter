# Orchestrator Rules — Dual

이 설치본은 **Claude**와 **Codex** 두 오케스트레이터를 함께 담는다. 실행 중인 호스트가
자기 자신을 식별해 자기 워커풀만 쓴다. 각 항목은 세션 시작 시 자체 점검 대상이며,
위반 시 즉시 사용자에게 알리고 작업을 중단한다.

---

## 0. 오케스트레이터 자기인식 (Dual 전용 — 가장 먼저)

세션 시작 시 "나는 누구인가"를 먼저 확정한다. **오케스트레이터는 어떤 CLI를 실행했느냐로 결정된다** —
JSON 플래그가 호스트를 바꾸지 못한다.

- **Claude Code 세션** → `self = claude`. `CLAUDE.md` + `routing.md` "A. Claude Orchestrator" + `backends.json` `orchestrators.claude` 만 사용.
- **Codex 세션** → `self = codex`. `AGENTS.md` + `routing.md` "B. Codex Orchestrator" + `backends.json` `orchestrators.codex` 만 사용.

**active 가드 (선택적 정책)**: `backends.json` 의 `active` 필드는 "지정 오케스트레이터"를 뜻한다(쿼터 절약 운영 등).
`self != active` 이면 작업 전 사용자에게 한 번 알린다:
> "현재 지정 오케스트레이터는 `<active>` 인데 지금 `<self>` 로 실행 중입니다. 계속할까요, 아니면 `<active>` 로 전환할까요?"
사용자가 계속을 택하면 진행하되, 혼동을 막기 위해 `active` 를 `self` 로 갱신할지 물어본다. 정확성은 자기인식이 보장하고, `active` 는 실수 방지·정책 표시용이다.

**디스패처 호출 규약**: cli/api 워커(gemini, claude-critic)를 디스패처로 부를 때 반드시
`MULTIAGENT_ORCH=<self>` 를 함께 넘긴다:
```bash
MULTIAGENT_ORCH=claude bash _shared/adapters/call_worker.sh gemini <brief-file>   # Claude일 때
MULTIAGENT_ORCH=codex  bash _shared/adapters/call_worker.sh claude-critic <brief-file>   # Codex일 때
```
넘기지 않으면 디스패처가 `active` 로 폴백한다 — `self != active` 면 잘못된 워커풀을 볼 수 있으므로 항상 명시한다.

**전환(switch) 운영**: 한 호스트의 쿼터가 부족해 다른 호스트로 옮길 때, 같은 설치 폴더에서 그냥 다른 CLI를 실행하면 된다.
`tasks/`·`_local/` 작업 상태는 공유되므로 끊김 없이 이어진다. 재설치·재생성 불필요. (필요 시 `active` 만 갱신.)

---

## 1. Orchestrator 실행 환경

MultiAgent Orchestrator는 인터랙티브 세션(Claude Code 또는 Codex)에서만 실행한다. 세션 시작 시 자체 점검:

- 시스템 프롬프트에 `# Background Session` 블록이 보이거나
- `$CLAUDE_JOB_DIR` 환경변수가 설정돼 있으면

→ 즉시 거부하고 "인터랙티브 세션에서 다시 시작해주세요" 안내. 백그라운드 harness는 worktree를 강제하므로 본체 `tasks/` 경로에 직접 쓸 수 없고, file-as-memory 원칙(외부 도구가 본체를 읽음)과 충돌한다.

---

## 2. 시스템 수정·검증 프로토콜

**적용 조건 (게이트)**: 이번 작업이 시스템 파일 — `CLAUDE.md`·`AGENTS.md`·`_shared/*`·`_templates/*` — 을 **수정하거나 검증**하는 작업일 때만 이 절을 적용한다. 일반 작업에서는 아래 파일들을 읽지 않는다 (progressive disclosure — 상시 로드 금지).

**작업 위치**: 시스템 수정·검증은 `<설치한-폴더>/`에서만 수행한다. 다른 디렉토리·다른 도구의 편집은 지침 파일이 적용 안 되고 아래 점검을 건너뛰므로 금지. 외부 편집을 발견하면 사용자에게 알리고 점검부터 돌린다.

**절차**:
1. `_shared/design-basis.md` 를 읽는다 — 개념↔규칙 매핑·권위 우선순위·기존 결정(D*). GitHub 레퍼런스부터 재분석하지 말 것.
2. 수정한다 (권위 우선순위 준수: 지침 파일 > routing/approval/orchestrator-rules > 매뉴얼).
3. `_shared/system-invariants.md` 의 자가 점검 + `generator/validate.py --flavor dual` 를 실행한다.
4. 통과 시에만 커밋. 깨지면 고치거나, 의도된 변경이면 `design-basis.md` 결정(D*)·`system-invariants.md`를 함께 갱신한 뒤 커밋.

**전면 재감사 조건**: 새 외부 개념·레퍼런스 도입, worker pool 구성·역할 변경, 불변식으로 표현 불가한 구조 변경일 때만 새 `tasks/<task>/`로 교차 벤더 비평(codex-critic/claude-critic)·gemini 포함 재점검.

---

## 3. 작업 재진입 프로토콜 (기존 작업에 다시 들어갈 때)

이미 `tasks/<task>/`가 있는 작업을 다시 만질 때(특히 맥락 0인 새 세션) 적용. 끝난 작업이라도 콜드세션이 맨손으로 시작하지 않게 한다. **호스트가 바뀌어 재개하는 경우(Claude→Codex 또는 반대)에도 동일하게 적용** — 먼저 §0 자기인식으로 self를 확정한 뒤 아래를 따른다.

**1단계 — 재정박(re-anchor, 필수)**: 어떤 액션(편집·worker 호출) 전에도 먼저 읽는다 — `task.md`(goal·**status**·workers_approved) → `context.md`(현재 스냅샷) → `log.md` 최근 항목(특히 마지막 `[WORKER_CALL]`/`[VERIFICATION]`) → 관련 `workers/<role>/brief.md`·`result.md`. 읽기 전 행동 금지.

**2단계 — 분기 판단** (result.md 유무만으로 판단하지 말 것 — status·log·brief를 함께 본다):
- **초기 실행** — brief·result 모두 없고 status `pending` → 정상 라이프사이클(지침 파일 "Task Lifecycle")
- **응답 대기/지연** — status `waiting_<role>`이거나 log에 `[WORKER_CALL]`만 있고 result.md 없음 → worker hang인지 늦게 도착할 응답인지 먼저 확인. hang 판정 시 3단계로
- **부분 재실행** — 특정 worker result만 미흡/검증 미통과 → 그 worker만 재호출. 다른 worker 결과 보존
- **기존 결과 개선** — 이전 result.md는 덮지 말고 `result-fix.md` 등으로 버전 보존하고, **현재 채택(authoritative) result 경로를 `context.md`에 명시**
- **새 입력** — 입력이 바뀌었으면 이전 산출물 보존하고 새 result로. **`target_repo`/`write_scope`가 바뀌면 기존 승인 무효 — 새 승인 없이는 외부 쓰기 금지**
- **status↔log 불일치 (가장 먼저 적용)** — 불일치면 log(append-only 정본)를 신뢰해 status를 정정하고 `[DECISION]` 기록한 뒤, 정정된 status로 위 분기를 다시 적용
- **워커풀 불일치 (Dual 전용)** — 이전 워커가 현재 self의 워커풀에 없으면(예: claude 작업의 codex-critic 결과를 codex 세션이 이어받음) 기존 result는 **보존·참조만** 하고, 새 호출이 필요하면 현재 self의 교차 벤더 워커로 대체한다. `log.md` `[DECISION]`에 전환 근거 기록.

**3단계 — 에러 후 진행(worker 실패·hang·상충)**:
- 실패/타임아웃 → **1회 재시도**. 재실패 시 누락을 `result.md`·`log.md` `[ERROR]`에 명시하고 가능한 부분만 진행
- 결과 상충 → 삭제 금지. 양쪽 출처 병기, 권위 우선순위/사실검증으로 해소, `log.md` `[DECISION]` 기록 (routing.md Fan-in 규칙과 동일)

재진입 시에도 승인 게이트·외부 쓰기 4조건은 그대로 유효. 재개 시 status를 `in_progress`로 되돌린다.
