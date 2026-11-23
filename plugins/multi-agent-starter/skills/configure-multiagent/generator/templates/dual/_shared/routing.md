# Worker Routing Rules — Dual Orchestrator

이 시스템은 **두 오케스트레이터**를 한 설치본에 담는다. 실행 중인 호스트가 **자기 자신**을 식별해
자기 섹션의 워커풀만 사용한다 (`_shared/orchestrator-rules.md` §0 자기인식 참조).

- **Claude Code 세션** → "A. Claude Orchestrator" 섹션 + `backends.json` `orchestrators.claude`
- **Codex 세션** → "B. Codex Orchestrator" 섹션 + `backends.json` `orchestrators.codex`

능력 슬롯과 호스트별 배정은 `_shared/capability-profile.md`를 따른다.

> 워커풀 정본은 항상 `_shared/backends.json`. 디스패처(`call_worker.sh`)는 호출 시
> `MULTIAGENT_ORCH=<self>` 를 받아 `orchestrators[self].workers[role]` 만 본다.

---

## A. Claude Orchestrator (워커: claude-main / codex-main / codex-critic / gemini)

### Decision Tree

```
작업 성격 파악 → 능력 슬롯 → 담당 워커 (배정 정본: capability-profile.md)
│
├── [strategist] 기획 · 설계 · 아키텍처 · 요구사항 · 전략 · UI/UX 디자인 방향
│   · 문체가 중요한 글쓰기 · 까다로운 로직 설계 · 디버깅 원인 분석?
│   └── claude-main
│
├── [engineer] 대규모 구현 · 리팩토링 · 테스트 작성·실행 · diff · 로컬 CLI 검증 · 이미지 생성?
│   └── codex-main
│
├── [computer-use] 브라우저 조작 · 복잡한 도구 워크플로우 자동화?
│   └── codex-main
│
├── [reviewer] 산출물 리뷰 / 비판적 검증?
│   └── codex-critic   (Codex의 주된 역할)
│
├── [multimodal] 이미지 · 스크린샷 분석 / 50페이지+ 문서 / 제3자 시각의 검토?
│   └── gemini
│
└── 판단 어려움?
    └── claude-main으로 시작 후 필요 시 추가
```

### 복합 작업 우선순위

한 작업이 여러 분기에 해당할 때:

1. **선행 의존성 우선**: codex-critic은 리뷰 대상(보통 claude-main 결과)이 먼저 있어야 함 → 해당 산출물 뒤에 호출
2. **Orchestrator 내부 추론 우선**: 별도 worker 호출 전에 orchestrator 자체 추론으로 해결 가능한지 먼저 판단. 그래도 부족할 때만 claude-main 호출 (claude-main도 비용·쿼터 대상)
3. **검증은 한 번만**: codex-critic은 작업당 1회 원칙. 재호출은 검증 실패 시만
4. **gemini는 명시적 트리거 시만**: 멀티모달 또는 "제3자 시각의 검토 필요" 명시 없으면 호출 금지

---

## B. Codex Orchestrator (워커: codex-main / claude-critic / gemini)

### Decision Tree

```
작업 성격 파악 → 능력 슬롯 → 담당 (배정 정본: capability-profile.md)
│
├── [engineer·computer-use] 현재 Codex Orchestrator가 직접 처리 가능한
│   구현 · 테스트 · 로컬 검증 · 브라우저 조작 단일 작업?
│   └── worker 호출 없이 진행 (두 슬롯의 기본 담당 = Orchestrator 자신)
│
├── [engineer] 구현 / 코드 분석 / 테스트 / diff / 로컬 검증 / 이미지 생성이 크고 분리 가능?
│   └── codex-main
│
├── [strategist] 설계 · UI/UX 디자인 · 전략 · 문체가 중요한 산출물?
│   └── Orchestrator가 생성 → 완성 후 claude-critic 품질 게이트 권장
│      (critic은 리뷰 대상 산출물이 먼저 있어야 함 — 최초 생성에 직접 라우팅 금지)
│
├── [reviewer] 산출물의 독립 리뷰 / 비판적 검증?
│   └── claude-critic
│
├── [multimodal] 이미지 · 스크린샷 분석 / 50페이지+ 문서 / 제3자 시각의 검토?
│   └── gemini
│
└── 판단 어려움?
    └── Orchestrator가 먼저 범위를 좁히고, 필요한 worker만 사용자 승인 후 추가
```

### 복합 작업 우선순위

1. **Orchestrator 우선**: 별도 worker 호출 전에 현재 Codex 세션의 추론·로컬 도구로 해결 가능한지 판단한다.
2. **최소 worker set**: 필요한 worker만 고른다. 모든 worker를 기본 호출하지 않는다.
3. **선행 의존성 우선**: `claude-critic`은 리뷰 대상 산출물 경로가 먼저 있어야 한다.
4. **검증은 한 번만**: `claude-critic`은 작업당 1회 원칙. 재호출은 검증 실패나 입력 변경 시만.
5. **gemini는 명시적 트리거 시만**: 멀티모달, 긴 문서, 또는 제3자 관점 필요가 명확할 때만.

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
| claude-main | claude | Claude Code 내장 Task tool, `subagent_type: claude-main` (호출 인자 `model` 생략, 에이전트의 `model: inherit` 적용) |
| codex-main | claude | `MULTIAGENT_ORCH=claude bash _shared/adapters/call_worker.sh codex-main <brief-file>` → `codex exec`, 기본 read-only, 외부 구현 승인 시만 workspace-write. |
| codex-main | codex | 네이티브 서브에이전트. 승인 후 `gate.sh`를 먼저 실행하고 호출 인자에 모델은 넣지 않는다. |
| codex-critic | claude | `MULTIAGENT_ORCH=claude bash _shared/adapters/call_worker.sh codex-critic <brief-file>` → `codex exec`, read-only. |
| claude-critic | codex | `MULTIAGENT_ORCH=codex bash _shared/adapters/call_worker.sh claude-critic <brief-file>`. 비평 모드, 쓰기 없음. |
| gemini | claude·codex | `MULTIAGENT_ORCH=<self> bash _shared/adapters/call_worker.sh gemini <brief-file>` (결과 JSON envelope). 백엔드 = Antigravity `agy` CLI, 모델은 agy 설정 기본값. 폐기 프록시 브리지 사용 금지. |

CLI 호출은 기본적으로 워크스페이스 루트에서 시작한다. 외부 쓰기 승인 시에만 승인된 `target_repo`에서 시작한다. 디스패처는 `gate.sh` 승인 검사와 `scope_check.sh` 사후 검사를 적용한다. 네이티브 호출은 오케스트레이터가 직접 `gate.sh`를 통과시킨 뒤 실행한다.

## Worker 파일 쓰기 (공통)

- `write_scope` 값: `none` / `tasks-only` / `"src/**, tests/**"` 패턴.
- 기본은 `tasks-only` — `tasks/<task>/` 내부만. 외부 repo 쓰기는 4조건(지침 파일 "Worker 파일 쓰기 정책") 모두 충족 시에만.
- 어느 worker도 `_shared/`, `_templates/`, 다른 작업 폴더는 수정하지 말 것.

## 모델 정책

- **claude-main**: 호출한 Claude 세션에서 선택한 모델을 사용한다 (`.claude/agents/claude-main.md`의 `model: inherit`).
- **codex-main / codex-critic**: 호출 인자에 모델을 지정하지 않는다. Codex의 네이티브 워커는 별도 서브에이전트 모델 설정이 없으면 호출한 세션 모델을 상속한다. Claude에서 별도로 실행하는 `codex exec`는 Codex 설정의 기본값을 쓴다.
- **claude-critic**: 승인된 Claude 도구의 현재 기본/별칭 모델. 버전 핀하지 않음.
- **gemini**: 백엔드 `agy` CLI (`backends.json` 정본), 모델은 agy 설정 기본값. 근거: `_shared/learnings.md` · `design-basis.md` D4.

## Worker 추가 조건
- 이미 있는 worker 결과로 해결 가능하면 추가 호출 금지.
- 이전 결과가 검증 미통과(또는 입력 변경) 시에만 동일 worker 재호출.
- 외부/유료 모델(claude-critic·codex worker·gemini)은 매 호출 전 승인 경계를 분명히 한다.
