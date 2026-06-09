#!/usr/bin/env python3
# _deansi.py — agy(winpty) 헤드리스 출력 정리기.
# agy --print는 TTY drip 렌더로 출력한다: CR(\r)로 줄을 col0부터 점진적으로
# 다시 그리고(progressive superset), LF(\n)로 줄을 확정한다. winpty로 캡처하면
# ANSI(CSI/OSC)·커서이동·줄당 다중 \r-세그먼트가 섞인다.
# 정리: ANSI 제거 → 각 \n-라인에서 '가장 긴 \r-세그먼트'(=최종 상태) 채택.
# 사용: python3 _deansi.py < raw > clean   (stdin→stdout, UTF-8)
import sys
import re

raw = sys.stdin.buffer.read().decode("utf-8", "replace")

# OSC: ESC ] ... (BEL | ESC \)
raw = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", raw)
# CSI: ESC [ params intermediates final
raw = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", raw)
# 남은 단독 ESC
raw = raw.replace("\x1b", "")

out_lines = []
for line in raw.split("\n"):
    segs = line.split("\r")
    best = max(segs, key=len) if segs else ""
    out_lines.append(best.rstrip())

# 과도한 연속 빈 줄 1개로 축약
text = "\n".join(out_lines)
text = re.sub(r"\n{3,}", "\n\n", text)
# Windows 콘솔 코드페이지(cp949 등) 재인코딩 회피 — UTF-8 바이트로 직접 출력
sys.stdout.buffer.write((text.strip() + "\n").encode("utf-8"))
