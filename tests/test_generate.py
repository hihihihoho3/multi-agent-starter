#!/usr/bin/env python3
"""L1/A2: 각 flavor를 임시폴더에 생성 → validate가 전부 PASS인지.

외부 호출 없음, 결정적. validate 체크 *개수*는 하드코딩하지 않는다
(F4 등으로 체크가 늘어도 안 깨지도록 — "전부 PASS"와 exit 0만 단언).
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
GEN = REPO / "plugins" / "multi-agent-starter" / "skills" / "configure-multiagent" / "generator"
FLAVORS = sorted(p.name for p in (GEN / "templates").iterdir() if p.is_dir())


def run(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True)


def has_model_override(backend: dict) -> bool:
    cli_args = backend.get("cli", {}).get("args_template", [])
    mcp_args = backend.get("mcp", {}).get("args_template", {})
    return (
        "model_alias" in backend.get("native", {})
        or "model" in mcp_args
        or any(arg.split("=", 1)[0] in {"-m", "--model", "model"} for arg in cli_args)
    )


def main() -> None:
    fails = 0
    for f in FLAVORS:
        with tempfile.TemporaryDirectory() as d:
            tgt = Path(d) / f"sys-{f}"
            r = run([sys.executable, str(GEN / "init.py"),
                     "--flavor", f, "--target", str(tgt), "--yes", "--no-validate", "--skip-host-fixes"])
            if r.returncode != 0:
                print(f"  FAIL [{f}] init exit {r.returncode}\n{r.stderr}")
                fails += 1
                continue
            v = run([sys.executable, str(GEN / "validate.py"),
                     "--flavor", f, "--target", str(tgt)])
            ok = v.returncode == 0 and "전부 PASS" in v.stdout
            print(f"  {'PASS' if ok else 'FAIL'} [{f}] validate exit {v.returncode}")
            if not ok:
                print(v.stdout)
                fails += 1
            backends = json.loads((tgt / "_shared" / "backends.json").read_text(encoding="utf-8"))
            worker_pools = (
                [orchestrator["workers"] for orchestrator in backends["orchestrators"].values()]
                if f == "dual" else [backends["workers"]]
            )
            for workers in worker_pools:
                claude_main = workers.get("claude-main", {})
                if claude_main.get("call_type") == "native":
                    agent_file = tgt / ".claude" / "agents" / "claude-main.md"
                    frontmatter = agent_file.read_text(encoding="utf-8").partition("\n---")[0]
                    if "model: inherit" not in frontmatter.splitlines() or has_model_override(claude_main):
                        print(f"  FAIL [{f}] claude-main must inherit the session model")
                        fails += 1
                for role in ("codex-main", "codex-critic"):
                    if role not in workers:
                        continue
                    worker = workers[role]
                    if any(has_model_override(backend) for backend in (worker, *worker.get("fallbacks", []))):
                        print(f"  FAIL [{f}] {role} must not override the Codex model")
                        fails += 1
                if "gemini" not in workers:
                    continue
                gemini = workers["gemini"]
                if gemini["model"] != "agy-default" or has_model_override(gemini):
                    print(f"  FAIL [{f}] gemini must inherit the agy model")
                    fails += 1
    print(f"test_generate: {'all pass' if not fails else f'{fails} fail'}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
