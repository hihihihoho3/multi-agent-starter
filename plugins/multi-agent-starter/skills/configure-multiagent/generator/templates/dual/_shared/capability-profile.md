# Capability Profile — Dual 슬롯 배정

라우팅의 안정층은 `routing.md`에 있다. 현재 호스트에 해당하는 열만 사용한다.

## 현재 배정

| 슬롯 | Claude Code | Codex |
|------|-------------|-------|
| strategist | claude-main (경량은 직접 처리) | 직접 처리, claude-critic 품질 게이트 |
| engineer | codex-main | 직접 처리, 큰 분리 작업은 codex-main |
| computer-use | codex-main | 직접 처리 |
| reviewer | codex-critic | claude-critic |
| multimodal | gemini | gemini |

## 배정 이력

- 원본 v3.7.0의 Claude·Codex 템플릿 배정을 각 호스트에 적용했다. 각 워커의 모델은 세션 또는 사용자 설정이 결정한다.
