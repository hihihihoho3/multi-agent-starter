#!/usr/bin/env python3
"""MultiAgent 시스템 생성기 — 결정적(deterministic) 스캐폴더.

flavor 템플릿(dual 기본, claude | codex | antigravity 선택 가능)을 대상 폴더에 복사한다.
- 결정적: 번들된 템플릿 파일을 그대로 복사. LLM 자유작문 없음 → 불변식 보장.
- 안전: 기존 tasks/·_local/ 사용자 데이터를 절대 지우지 않음(update 모드 보존).
- 호스트 독립: 순수 파이썬. plugin/skill/ZIP은 이 스크립트를 부르는 얇은 front door일 뿐.

사용:
    python3 init.py                         # 기본 dual 설치
    python3 init.py --interactive           # 대화형(메뉴)
    python3 init.py --flavor codex --target ~/work/my-system --yes
    python3 init.py --flavor claude --target . --dry-run
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
TEMPLATES_DIR = SCRIPT_DIR / "templates"
FLAVORS = ("claude", "codex", "antigravity", "dual")
# 사용자 데이터 디렉토리 — 내용물은 절대 덮어쓰거나 지우지 않는다(.gitkeep만 보장).
PRESERVE_DIRS = ("tasks", "_local")


def available_flavors() -> list[str]:
    return [f for f in FLAVORS if (TEMPLATES_DIR / f).is_dir()]


def choose_flavor(arg: str | None, flavors: list[str], interactive: bool = False) -> str:
    if arg:
        if arg not in flavors:
            sys.exit(f"[error] unknown flavor '{arg}'. available: {', '.join(flavors)}")
        return arg
    if not interactive:
        default = "dual" if "dual" in flavors else flavors[0]
        return default
    print("어떤 멀티에이전트 시스템을 구성할까요?")
    for i, f in enumerate(flavors, 1):
        print(f"  {i}. {f}")
    while True:
        sel = input("선택 [번호]: ").strip()
        if sel.isdigit() and 1 <= int(sel) <= len(flavors):
            return flavors[int(sel) - 1]
        print("  잘못된 선택")


def choose_target(arg: str | None, flavor: str) -> Path:
    if arg:
        return Path(arg).expanduser().resolve()
    default = str(Path.cwd() / f"multi-agent-{flavor}")
    raw = input(f"설치할 폴더 [{default}]: ").strip() or default
    return Path(raw).expanduser().resolve()


def guard_target(target: Path, template_dir: Path) -> None:
    """installer 자기 자신/템플릿 트리 안에 설치하는 사고 방지."""
    bad = [SCRIPT_DIR, template_dir]
    for b in bad:
        if target == b or b in target.parents or target in b.parents:
            sys.exit(f"[error] installer/template 트리 안에는 설치할 수 없습니다: {target}")


def is_user_data(rel: Path) -> bool:
    """tasks/ · _local/ 하위의 .gitkeep 외 파일 = 사용자 데이터(건드리지 않음)."""
    return len(rel.parts) >= 1 and rel.parts[0] in PRESERVE_DIRS and rel.name != ".gitkeep"


def copy_template(template_dir: Path, target: Path, dry: bool) -> list[Path]:
    """템플릿 파일을 target에 복사. target-only 파일(사용자 tasks/ 작업물)은
    삭제하지 않으므로 update 모드에서 자동 보존된다."""
    written: list[Path] = []
    for src in sorted(template_dir.rglob("*")):
        if src.is_dir():
            continue
        rel = src.relative_to(template_dir)
        if is_user_data(rel):  # 방어적: 템플릿엔 .gitkeep만 있어 보통 도달 안 함
            continue
        dest = target / rel
        if not dry:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
        written.append(rel)
    return written




POWERSHELL_PROFILE_MARKER_START = "# >>> multi-agent-starter Git Bash PATH fix >>>"
POWERSHELL_PROFILE_MARKER_END = "# <<< multi-agent-starter Git Bash PATH fix <<<"


def _windows_git_bin() -> Path | None:
    """Return the standard Git Bash bin directory on Windows, if installed."""
    candidates: list[Path] = []
    for env_name in ("ProgramFiles", "ProgramFiles(x86)"):
        base = os.environ.get(env_name)
        if base:
            candidates.append(Path(base) / "Git" / "bin")
    for cand in candidates:
        if (cand / "bash.exe").exists():
            return cand
    return None


def _powershell_profile_path() -> Path:
    user = Path(os.environ.get("USERPROFILE", str(Path.home())))
    return user / "Documents" / "PowerShell" / "profile.ps1"


def ensure_windows_gitbash_path(dry: bool) -> None:
    """On Windows, make future PowerShell sessions resolve `bash` to Git Bash.

    Windows often exposes C:\\Windows\\System32\\bash.exe (WSL launcher) before
    Git Bash. The MAT dispatcher is a bash script that expects the Git Bash/MSYS
    environment where winget-installed jq and agy capture behave correctly. This
    idempotently prepends Git Bash to the user's PowerShell profile and also
    updates the current process PATH for any post-install checks.
    """
    if os.name != "nt":
        return

    git_bin = _windows_git_bin()
    if git_bin is None:
        print("  [host-fix] Windows: Git Bash not found; install Git for Windows if call_worker.sh cannot find jq.")
        return

    git_bin_s = str(git_bin)
    path_parts = [p for p in os.environ.get("PATH", "").split(os.pathsep) if p]
    if not path_parts or path_parts[0].lower() != git_bin_s.lower():
        os.environ["PATH"] = git_bin_s + os.pathsep + os.environ.get("PATH", "")
        print(f"  [host-fix] current PATH prepended: {git_bin_s}")

    profile = _powershell_profile_path()
    block = f"""
{POWERSHELL_PROFILE_MARKER_START}
# Ensure `bash` resolves to Git Bash before the Windows WSL stub so MAT call_worker.sh can run jq.
# Resolve dynamically at shell startup; do not bake in the installer machine's absolute path.
$gitBinCandidates = @()
if ($env:ProgramFiles) {{ $gitBinCandidates += (Join-Path (Join-Path $env:ProgramFiles 'Git') 'bin') }}
if (${{env:ProgramFiles(x86)}}) {{ $gitBinCandidates += (Join-Path (Join-Path ${{env:ProgramFiles(x86)}} 'Git') 'bin') }}
$gitBinForMat = $gitBinCandidates | Where-Object {{ Test-Path (Join-Path $_ 'bash.exe') }} | Select-Object -First 1
if ($gitBinForMat) {{
    $pathParts = $env:Path -split ';' | Where-Object {{ $_ }}
    if ($pathParts.Count -eq 0 -or $pathParts[0] -ne $gitBinForMat) {{
        $env:Path = $gitBinForMat + ';' + ($pathParts -join ';')
    }}
}}
{POWERSHELL_PROFILE_MARKER_END}
"""
    existing = ""
    if profile.exists():
        existing = profile.read_text(encoding="utf-8-sig", errors="replace")
    if POWERSHELL_PROFILE_MARKER_START in existing:
        print(f"  [host-fix] PowerShell profile already contains Git Bash PATH fix: {profile}")
        return
    if dry:
        print(f"  [dry-run] PowerShell profile Git Bash PATH fix would be added: {profile}")
        return
    profile.parent.mkdir(parents=True, exist_ok=True)
    with profile.open("a", encoding="utf-8") as f:
        if existing and not existing.endswith(("\n", "\r")):
            f.write("\n")
        f.write(block)
    print(f"  [host-fix] PowerShell profile updated for Git Bash PATH: {profile}")


def main() -> None:
    ap = argparse.ArgumentParser(description="MultiAgent 시스템 생성기 (결정적 스캐폴더)")
    ap.add_argument("--flavor", choices=FLAVORS, help="claude | codex | antigravity | dual (생략 시 dual)")
    ap.add_argument("--target", help="설치 대상 폴더 (생략 시 질문)")
    ap.add_argument("--interactive", action="store_true", help="flavor 메뉴를 표시해 직접 선택")
    ap.add_argument("--yes", action="store_true", help="확인 프롬프트 생략")
    ap.add_argument("--no-validate", action="store_true", help="설치 후 validate 건너뜀")
    ap.add_argument("--dry-run", action="store_true", help="실제 쓰지 않고 미리보기")
    ap.add_argument("--skip-host-fixes", action="store_true", help="Windows Git Bash PATH 같은 호스트 보정 생략")
    args = ap.parse_args()

    flavors = available_flavors()
    if not flavors:
        sys.exit(f"[error] 템플릿이 없습니다: {TEMPLATES_DIR}")

    flavor = choose_flavor(args.flavor, flavors, interactive=args.interactive)
    template_dir = TEMPLATES_DIR / flavor
    target = choose_target(args.target, flavor)
    guard_target(target, template_dir)

    mode = "update" if (target.exists() and any(target.iterdir())) else "init"
    print()
    print(f"  flavor : {flavor}")
    print(f"  target : {target}")
    print(f"  mode   : {mode}  (update=시스템 파일만 갱신, tasks/·_local/ 사용자 데이터 보존)")
    if args.dry_run:
        print("  [dry-run] 실제 변경 없음")

    if not args.yes and not args.dry_run:
        if input("\n진행할까요? [y/N]: ").strip().lower() not in ("y", "yes"):
            sys.exit("취소됨")

    if not args.skip_host_fixes:
        ensure_windows_gitbash_path(dry=args.dry_run)

    written = copy_template(template_dir, target, dry=args.dry_run)
    prefix = "(dry) " if args.dry_run else ""
    print(f"\n  {prefix}{len(written)}개 파일 {'복사 예정' if args.dry_run else '복사 완료'}.")

    validate = SCRIPT_DIR / "validate.py"
    if not args.no_validate and not args.dry_run and validate.exists():
        print("\n  validate.py 실행...")
        rc = subprocess.run(
            [sys.executable, str(validate), "--flavor", flavor, "--target", str(target)]
        ).returncode
        if rc != 0:
            sys.exit(f"[warn] validate가 문제를 보고했습니다 (exit {rc})")

    print(f"\n  완료. 다음: cd {target} 후 해당 도구({flavor}) 실행.")


if __name__ == "__main__":
    main()
