#!/usr/bin/env python3
"""Prepare DevKit's isolated TinyPNG Python. Usage: image_python_runtime.py [--check]."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import venv


REQUIREMENTS = Path(__file__).resolve().with_name("image_requirements.txt")
RUNTIME_ROOT = Path.home() / "Library/Application Support/DevKit/Python"


def expected_versions(requirements: Path) -> dict[str, str]:
    versions = {}
    for line in requirements.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        requirement, _, marker = line.partition(";")
        if marker:
            variable, comparison, version = shlex.split(marker)
            if variable != "python_version" or comparison not in ("<", ">="):
                raise ValueError(f"Unsupported version marker: {marker}")
            minimum = tuple(map(int, version.split(".")))
            if (sys.version_info[:2] < minimum) != (comparison == "<"):
                continue
        name, version = requirement.strip().split("==")
        versions[name] = version
    return versions


def environment_directory(requirements: Path, runtime_root: Path) -> Path:
    interpreter = str(Path(getattr(sys, "_base_executable", sys.executable)).resolve())
    identity = requirements.read_bytes() + interpreter.encode() + str(sys.version_info[:2]).encode()
    return runtime_root / ("tinypng-" + hashlib.sha256(identity).hexdigest()[:16])


def environment_ready(python: Path, requirements: Path) -> bool:
    if not python.is_file():
        return False
    check = (
        "import importlib.metadata as m, json, os, sys; import requests, urllib3; "
        "assert os.path.realpath(sys.prefix) == os.path.realpath(sys.argv[1]); "
        "assert all(m.version(k) == v for k, v in json.loads(sys.argv[2]).items())"
    )
    try:
        result = subprocess.run(
            [str(python), "-I", "-c", check, str(python.parent.parent), json.dumps(expected_versions(requirements))],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return result.returncode == 0
    except OSError:
        return False


def ensure_environment(requirements: Path = REQUIREMENTS, runtime_root: Path = RUNTIME_ROOT) -> Path:
    directory = environment_directory(requirements, runtime_root)
    python = directory / "bin/python3"
    if environment_ready(python, requirements):
        return python
    runtime_root.mkdir(parents=True, exist_ok=True)
    # Startup preparation and the first compression may run concurrently.
    with (runtime_root / ".setup.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if environment_ready(python, requirements):
            return python
        print("正在准备 DevKit 的 TinyPNG 独立运行环境...", file=sys.stderr, flush=True)
        venv.EnvBuilder(with_pip=False).create(directory)
        for command in (
            [str(python), "-I", "-m", "ensurepip", "--upgrade"],
            [str(python), "-I", "-m", "pip", "--isolated", "install", "--require-virtualenv",
             "--disable-pip-version-check", "-r", str(requirements)],
        ):
            # Keep the setup lock held by an installer even if its parent is stopped.
            subprocess.run(command, check=True, stdout=sys.stderr, stderr=sys.stderr, pass_fds=(lock.fileno(),))
        if not environment_ready(python, requirements):
            raise RuntimeError("TinyPNG 独立环境校验失败，请重新运行依赖准备脚本。")
    return python


def main():
    parser = argparse.ArgumentParser(description="Prepare DevKit's isolated TinyPNG Python dependencies")
    parser.add_argument("--check", action="store_true", help="Check without creating or installing anything")
    parser.add_argument("--runtime-root", type=Path, default=RUNTIME_ROOT, help="Directory for DevKit-managed environments")
    args = parser.parse_args()
    if args.check:
        python = environment_directory(REQUIREMENTS, args.runtime_root) / "bin/python3"
        sys.exit(0 if environment_ready(python, REQUIREMENTS) else 1)
    print(ensure_environment(runtime_root=args.runtime_root))


if __name__ == "__main__":
    main()
