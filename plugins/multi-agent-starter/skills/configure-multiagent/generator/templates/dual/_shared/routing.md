# Worker Routing Rules — Dual Orchestrator

이 시스템은 **두 오케스트레이터**를 한 설치본에 담는다. 실행 중인 호스트가 **자기 자신**을 식별해
자기 섹션의 워커풀만 사용한다 (`_shared/orchestrator-rules.md` §0 자기인식 참조).

- **Claude Code 세션** → "A. Claude Orchestrator" 섹션 + `backends.json` `orchestrators.claude`
- **Codex 세션** → "B. Codex Orchestrator" 섹션 + `backends.json` `orchestrators.codex`

> 워커풀 정본은 항상 `_shared/backends.json`. 디스패처(`call_worker.sh`)는 호출 시
> `MULTIAGENT_ORCH=<self>` 를 받아 `orchestrators[self].workers[role]` 만 본다.

---

## A. Claude Orchestrator (워커: claude-main / codex-main / codex-critic / gemini)

### Decision Tree

```
작업 성격 파악
│
├── 메인 코딩 / 디버깅 / 기획 · 설계 · 요구사항 · 전략 · 문서화?
│   └── claude-main
│
├── claude-main 산출물 리뷰 / 비판적 검증?      (교차 벤더 — Codex가 비평)
│   └── codex-critic
│
├── 보조 구현 / 코드 분석 / 테스트 / 이미지 생성?
│   └── codex-main
│
├── 이미지 · 스크린샷 분석 / 50페이지+ 문서 / 제3자 시각의 검토?
│   └── gemini
│
└── 판단 어려움?
    └── claude-main으로 시작 후 필요 시 추가
```

**복합 작업 우선순위**
1. **선행 의존성 우선**: codex-critic은 리뷰 대상(보통 claude-main 결과)이 먼저 있어야 함.
2. **Orchestrator 내부 추론 우선**: 별도 worker 호출 전에 자체 추론으로 가능한지 먼저 판단. claude-main도 비용·쿼터 대상.
3. **검증은 한 번만**: codex-critic은 작업당 1회 원칙. 재호출은 검증 실패 시만.
4. **gemini는 명시적 트리거 시만**.

**교차 벤더 비평**: Claude가 오케스트레이터일 때 비평은 **codex-critic**(다른 벤더)에게 맡긴다.
같은 벤더 자기검수(claude-critic)는 이 섹션에서 쓰지 않는다.

### 최소 Worker Set
| 작업 유형 | 권장 최소 set |
|----------|------------|
| 문서/기획만 · 코드 구현 | claude-main |
| 구현 + 비평 | claude-main → codex-critic → claude-main (반영) |
| 보조 구현 / 이미지 생성 | codex-main |
| 대용량 문서/이미지 | gemini |

---

## B. Codex Orchestrator (워커: codex-main / claude-critic / gemini)

### Decision Tree

```
작업 성격 파악
│
├── 현재 Codex Orchestrator가 직접 처리 가능한 단일 작업?
│   └── worker 호출 없이 진행
│
├── 구현 / 코드 분석 / 테스트 / diff / 로컬 검증 / 이미지 생성이 크고 분리 가능?
│   └── codex-main
│
├── Codex 또는 codex-main 산출물의 독립 리뷰 / 비판적 검증?   (교차 벤더 — Claude가 비평)
│   └── claude-critic
│
├── 이미지 · 스크린샷 분석 / 50페이지+ 문서 / 제3자 시각의 검토?
│   └── gemini
│
└── 판단 어려움?
    └── Orchestrator가 먼저 범위를 좁히고, 필요한 worker만 사용자 승인 후 추가
```

**복합 작업 우선순위**
1. **Orchestrator 우선**: 별도 worker 호출 전에 현재 Codex 세션의 추론·로컬 도구로 해결 가능한지 판단.
2. **최소 worker set**: 필요한 worker만 고른다.
3. **선행 의존성 우선**: `claude-critic`은 리뷰 대상 산출물 경로가 먼저 있어야 한다.
4. **검증은 한 번만**: `claude-critic`은 작업당 1회 원칙. 재호출은 검증 실패나 입력 변경 시만.
5. **gemini는 명시적 트리거 시만**.

**교차 벤더 비평**: Codex가 오케스트레이터일 때 비평은 **claude-critic**(다른 벤더)에게 맡긴다.
같은 벤더 자기검수(codex-critic)는 이 섹션에서 쓰지 않는다.

### 최소 Worker Set
| 작업 유형 | 권장 최소 set |
|-----------|---------------|
| 작고 명확한 구현/문서 | worker 없음, Orchestrator 직접 처리 |
| 분리 가능한 구현/검증 | codex-main |
| 구현 + 독립 비평 | codex-main → claude-critic |
| 대용량 문서/이미지 | gemini |

---

## 토폴로지 패턴 (양 오케스트레이터 공통)

decision tree로 "누구를" 고른 뒤 "어떻게 엮을지" 고른다. **단일 orchestrator 구조에 맞는 4패턴만** 쓴다.

| 패턴 | 언제 | 이 시스템에서 |
|------|------|-------------|
| Pipeline (순차) | 앞 결과가 뒤 입력 | 기본. main → critic → main(반영) |
| Fan-out/Fan-in (병렬→통합) | 서로 독립된 산출물 여럿을 하나로 통합 | 예: main(코드) ∥ gemini(이미지). 각 brief에 "타 worker 결과 미참조" 명시. 통합은 Orchestrator |
| Expert Pool (전문가 선택) | 작업 성격에 맞는 worker만 | 새 실행 패턴이 아니라 **worker 선택 정책** — 위 decision tree + 최소 worker set |
| Producer-Reviewer (생성+게이트) | 산출물 품질 검증 필요 | main(생성) → critic(adversarial 게이트) |

**금지**: 같은 입력에 같은 종류 worker 동시 호출.
**배제**: Supervisor(별도 long-lived 조정자 worker/런타임 동적분배 계층)·Hierarchical Delegation(worker가 worker를 부르는 재귀 위임)은 단일 orchestrator·worker간 무통신·file-as-memory와 충돌 → 미사용. 근거: design-basis D6.

### Fan-in 규칙 (병렬 결과 통합)
1. 각 worker 원문을 `result.md`에 그대로 보존 (telephone game 방지).
2. 결과가 충돌하면 삭제 금지 → 양쪽 출처 병기, 권위 우선순위/사실검증으로 해소, `log.md` `[DECISION]` 기록.
3. 통합 결론 한 줄을 `context.md`에 기록.

---

## Worker 호출 방식 요약

| Worker | 활성 오케스트레이터 | 호출 방식 |
|--------|------------------|----------|
| claude-main | claude | Claude Code 내장 Task tool, `subagent_type: claude-main` (`.claude/agents/claude-main.md`, `model: opus`) |
| codex-main | claude | `mcp__codex__codex` MCP (cli 폴백). claude일 때 보조 구현. |
| codex-main | codex | 현재 Codex 환경의 native sub-agent/worker. |
| codex-critic | claude | `mcp__codex__codex` MCP, `sandbox: read-only`, 비평 모드. |
| claude-critic | codex | 승인된 Claude CLI (`claude -p`). 비평 모드, 쓰기 없음. |
| gemini | claude·codex | `MULTIAGENT_ORCH=<self> bash _shared/adapters/call_worker.sh gemini <brief-file>` (결과 JSON envelope). 백엔드 = Antigravity `agy` CLI, 기본 `Gemini 3.5 Flash (High)`, 폴백 api. 폐기 프록시 브리지 사용 금지. |

## Worker 파일 쓰기 (공통)

- `write_scope` 값: `none` / `tasks-only` / `"src/**, tests/**"` 패턴.
- 기본은 `tasks-only` — `tasks/<task>/` 내부만. 외부 repo 쓰기는 4조건(지침 파일 "Worker 파일 쓰기 정책") 모두 충족 시에만.
- 어느 worker도 `_shared/`, `_templates/`, 다른 작업 폴더는 수정하지 말 것.

## 모델 정책

- **claude-main**: 별칭 `opus` (`.claude/agents/claude-main.md` frontmatter). 버전 핀하지 않음 — 환경의 최신 Opus로 해석.
- **codex-main / codex-critic**: 사용자 `~/.codex/config.toml` 기본값 자동 적용. 버전 핀하지 않음.
- **claude-critic**: 승인된 Claude 도구의 현재 기본/별칭 모델. 버전 핀하지 않음.
- **gemini**: 백엔드 `agy` CLI (`backends.json` 정본), 기본 `Gemini 3.5 Flash (High)`, 빠른 경로 `gemini-3-flash`/`pro-low`, 폴백 api. agy Windows CLI는 `--model` UI 라벨로 per-call 지정한다. 근거: `_shared/learnings.md` · `design-basis.md` D4.

## Worker 추가 조건
- 이미 있는 worker 결과로 해결 가능하면 추가 호출 금지.
- 이전 결과가 검증 미통과(또는 입력 변경) 시에만 동일 worker 재호출.
- 외부/유료 모델(claude-critic·codex worker·gemini)은 매 호출 전 승인 경계를 분명히 한다.
