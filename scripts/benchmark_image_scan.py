#!/usr/bin/env python3
"""Compile and time the actual native image selection pipeline without modifying inputs."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile


SWIFT_MAIN = r'''
import Foundation
import CryptoKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let gitOnly = CommandLine.arguments[2] == "git"
let started = Date()
let batch = try GitChangedImageScanner.scanSelection(
    [root], onlyGitChangedImages: gitOnly, supportedExtensions: ["png", "jpg", "jpeg", "webp"],
    scanImage: { ImageTaskScanner.scan($0, supportedExtensions: ["png", "jpg", "jpeg", "webp"]) }
)
let elapsed = Date().timeIntervalSince(started)
let paths = batch.scans.flatMap(\.images).map { $0.url.resolvingSymlinksInPath().path }.sorted()
let digest = SHA256.hash(data: try JSONEncoder().encode(paths)).map { String(format: "%02x", $0) }.joined()
let result: [String: Any] = ["seconds": elapsed, "images": paths.count, "paths_sha256": digest,
    "git_filter_available": batch.gitFilterAvailable, "uses_git_filter": batch.usesGitFilter]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
FileHandle.standardOutput.write(Data("\n".utf8))
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="Image or directory to scan read-only")
    parser.add_argument("--git-changes", action="store_true", help="Enable the uncommitted-image filter")
    parser.add_argument("--iterations", type=int, default=1, help="Number of sequential measured scans (default: 1)")
    parser.add_argument("--max-seconds", type=float, help="Fail if any scan exceeds this runtime budget")
    parser.add_argument("--expected-images", type=int, help="Fail if the number of matched images changes")
    parser.add_argument("--expected-sha256", help="Fail if the matched path set changes")
    parser.add_argument("--timeout", type=float, default=30, help="Per-process timeout in seconds (default: 30)")
    args = parser.parse_args()
    if args.iterations < 1 or args.timeout <= 0 or (args.max_seconds is not None and args.max_seconds <= 0):
        parser.error("iterations, timeout and max-seconds must be positive")
    source = args.path.expanduser().absolute()
    if not source.exists():
        parser.error(f"input does not exist: {source}")
    repository = Path(__file__).resolve().parent.parent
    shared = repository / "devkit/Features/Shared"
    try:
        with tempfile.TemporaryDirectory(prefix="DevKit-Scan-Benchmark-") as temporary:
            work = Path(temporary)
            main_file = work / "main.swift"
            main_file.write_text(SWIFT_MAIN)
            executable = work / "benchmark"
            subprocess.run(
                ["/usr/bin/swiftc", "-Onone", str(shared / "ImageTaskScanner.swift"),
                 str(shared / "ImageCompressionInputRules.swift"), str(shared / "GitChangedImageScanner.swift"),
                 str(main_file), "-o", str(executable)],
                check=True, timeout=args.timeout, capture_output=True, text=True,
            )
            runs = []
            for _ in range(args.iterations):
                completed = subprocess.run(
                    [str(executable), str(source), "git" if args.git_changes else "ordinary"],
                    check=True, timeout=args.timeout, capture_output=True, text=True,
                )
                runs.append(json.loads(completed.stdout))
            passed = args.max_seconds is None or all(run["seconds"] <= args.max_seconds for run in runs)
            matches = all(
                (args.expected_images is None or run["images"] == args.expected_images)
                and (args.expected_sha256 is None or run["paths_sha256"] == args.expected_sha256)
                for run in runs
            )
            print(json.dumps({"runs": runs, "budget_seconds": args.max_seconds,
                              "budget_pass": passed, "matches_expected": matches}, sort_keys=True))
            return 0 if passed and matches else 2
    except subprocess.TimeoutExpired:
        print(json.dumps({"error": "scan or compilation timed out", "timeout_seconds": args.timeout}))
        return 2
    except subprocess.CalledProcessError as error:
        print(json.dumps({"error": error.stderr.strip(), "exit_code": error.returncode}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
