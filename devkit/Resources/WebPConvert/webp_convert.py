#!/usr/bin/env python3
"""
WebP 批量转换工具
用法: python3 webp_convert.py <文件或目录路径...> [选项]
输出: 在同级目录生成 <原名>_webp_<时间戳> 的转换结果；--replace 时转换成功后替换原图
只有转换结果比原图更小时才保留 WebP，否则保留原文件

参数说明:
  --quality N      WebP 有损质量，默认 80（建议 75-85，性价比最高）
  --min-size-kb N  小于此大小（KB）的图片跳过转换，默认 100
  --max-side N     最长边超过 N 像素时按比例缩小，0 表示不限制，默认 0
  --replace        转换成功后替换原图；默认写入同级时间戳文件夹
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

# cwebp 原生支持 PNG/JPEG/TIFF/WebP；其余格式先经 sips 转成 PNG 再交给 cwebp
SUPPORTED_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif", ".heic", ".heif", ".webp"}
MAX_WORKERS = 8


def start_parent_watchdog():
    """在 DevKit 被强制结束时，让子进程也退出。"""
    raw_parent_pid = os.environ.get("DEVKIT_PARENT_PID")
    if not raw_parent_pid:
        return
    try:
        parent_pid = int(raw_parent_pid)
    except ValueError:
        return

    def monitor():
        while True:
            time.sleep(0.5)
            if os.getppid() != parent_pid:
                os.kill(os.getpid(), signal.SIGTERM)
                return

    threading.Thread(
        target=monitor,
        name="devkit-parent-watchdog",
        daemon=True,
    ).start()


def format_size(size_bytes: int) -> str:
    """格式化文件大小"""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    else:
        return f"{size_bytes / (1024 * 1024):.2f} MB"


def format_elapsed(seconds: float) -> str:
    """格式化耗时"""
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h > 0:
        return f"{h}h{m:02d}m{s:02d}s"
    elif m > 0:
        return f"{m}m{s:02d}s"
    else:
        return f"{s}s"


def emit_event(src: Path, dst: Path, before: int, after: int, ok: bool, skipped: bool, error: str):
    """输出单张图片的 JSON 事件行，供 DevKit 界面实时刷新"""
    print("EVENT " + json.dumps({
        "src": str(src),
        "dst": str(dst),
        "before": before,
        "after": after,
        "ok": ok,
        "skipped": skipped,
        "error": error,
    }, ensure_ascii=False, separators=(",", ":")), flush=True)


def run_command(arguments: list[str]) -> tuple[bool, str]:
    """运行外部命令，返回 (是否成功, 合并的输出)"""
    try:
        completed = subprocess.run(
            arguments,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, str(error)
    output = completed.stdout.decode("utf-8", errors="replace").strip()
    return completed.returncode == 0, output


def image_pixel_size(path: Path) -> tuple[int, int] | None:
    """用 sips 读取图片像素尺寸，读取失败返回 None"""
    ok, output = run_command(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)])
    if not ok:
        return None
    width = height = None
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "pixelWidth:":
            width = int(parts[-1])
        elif len(parts) >= 2 and parts[0] == "pixelHeight:":
            height = int(parts[-1])
    if width is None or height is None:
        return None
    return width, height


def cwebp_available() -> bool:
    return run_command(["cwebp", "-version"])[0]


def encode_webp(src: Path, temp_output: Path, quality: int, max_side: int) -> str:
    """
    把单张图片编码为 WebP 临时文件。
    返回错误信息，成功返回空字符串。
    """
    resize_arguments = []
    if max_side > 0:
        size = image_pixel_size(src)
        if size is not None:
            width, height = size
            longest = max(width, height)
            if longest > max_side:
                scale = max_side / longest
                resize_arguments = [
                    "-resize",
                    str(max(1, round(width * scale))),
                    str(max(1, round(height * scale))),
                ]

    ok, output = run_command(
        ["cwebp", "-quiet", "-q", str(quality), "-mt", *resize_arguments, str(src), "-o", str(temp_output)]
    )
    if ok and temp_output.exists() and temp_output.stat().st_size > 0:
        return ""

    # cwebp 读不了的格式（heic/bmp/gif 等）先经 sips 转 PNG 再编码
    png_bridge = temp_output.with_suffix(".bridge.png")
    ok, output = run_command(["sips", "-s", "format", "png", str(src), "--out", str(png_bridge)])
    if not ok or not png_bridge.exists():
        return f"cwebp 失败且 sips 无法读取该格式: {output[:120]}"
    ok, output = run_command(
        ["cwebp", "-quiet", "-q", str(quality), "-mt", *resize_arguments, str(png_bridge), "-o", str(temp_output)]
    )
    png_bridge.unlink(missing_ok=True)
    if ok and temp_output.exists() and temp_output.stat().st_size > 0:
        return ""
    temp_output.unlink(missing_ok=True)
    return f"cwebp 转换失败: {output[:120]}"


def convert_image(src_path: Path, dst_path: Path, quality: int, max_side: int, replace_source: bool = False) -> dict:
    """
    转换单张图片，只有结果更小时才落盘。
    替换模式在转换成功后删除原图。
    返回: {"src", "dst", "before", "after", "ok", "skipped", "error"}
    """
    result = {
        "src": str(src_path),
        "dst": str(dst_path),
        "before": src_path.stat().st_size,
        "after": 0,
        "ok": False,
        "skipped": False,
        "error": "",
    }

    temp_output = dst_path.parent / f".{src_path.stem}.webp.tmp"
    temp_output.parent.mkdir(parents=True, exist_ok=True)

    error = encode_webp(src_path, temp_output, quality, max_side)
    if error:
        temp_output.unlink(missing_ok=True)
        result["error"] = error
        return result

    new_size = temp_output.stat().st_size
    if new_size >= result["before"]:
        # WebP 没有更小，保留原文件
        temp_output.unlink(missing_ok=True)
        result["skipped"] = True
        result["after"] = result["before"]
        result["error"] = "WebP 未减小，已保留原文件"
        return result

    dst_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(temp_output, dst_path)
    if replace_source and src_path != dst_path:
        src_path.unlink(missing_ok=True)
    result["after"] = dst_path.stat().st_size
    result["ok"] = True
    return result


def collect_images(input_path: Path) -> list[Path]:
    """收集所有支持的图片文件"""
    if input_path.is_file():
        if input_path.suffix.lower() in SUPPORTED_EXTS:
            return [input_path]
        print(f"不支持的文件格式: {input_path.suffix}")
        return []

    images = []
    for root, _, files in os.walk(input_path):
        for fname in sorted(files):
            fpath = Path(root) / fname
            if fpath.suffix.lower() in SUPPORTED_EXTS:
                images.append(fpath)
    return images


def main():
    start_parent_watchdog()
    parser = argparse.ArgumentParser(
        description="WebP 批量转换工具：把图片转换为 WebP，仅当结果更小时替换/保留",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("paths", nargs="*", help="图片文件或文件夹路径，可传多个")
    parser.add_argument("--quality", type=int, default=80, help="WebP 有损质量 1-100，建议 75-85")
    parser.add_argument("--min-size-kb", type=int, default=100, help="小于此大小（KB）的图片跳过转换")
    parser.add_argument("--max-side", type=int, default=0, help="最长边超过该像素时按比例缩小，0 不限制")
    parser.add_argument("--replace", action="store_true", help="转换成功后替换原图；默认写入同级时间戳文件夹")
    args = parser.parse_args()

    raw_paths = args.paths
    if not raw_paths:
        try:
            raw = input("请拖入文件或目录路径: ").strip().strip("'\"")
        except (EOFError, KeyboardInterrupt):
            print("\n已取消")
            sys.exit(0)
        if not raw:
            print("未输入路径")
            sys.exit(1)
        raw_paths = raw.split()

    quality = min(max(1, args.quality), 100)
    max_side = max(0, args.max_side)
    minimum_bytes = max(0, args.min_size_kb) * 1024

    if not cwebp_available():
        print("未找到 cwebp 工具，请先安装：brew install webp")
        sys.exit(1)

    input_roots: list[Path] = []
    for raw in raw_paths:
        path = Path(raw.strip()).resolve()
        if not path.exists():
            print(f"路径不存在: {path}")
            sys.exit(1)
        if path not in input_roots:
            input_roots.append(path)

    root_images: list[tuple[Path, list[Path]]] = []
    seen_paths: set[Path] = set()
    total_images = 0
    for root in input_roots:
        unique_images = [
            image for image in collect_images(root)
            if image not in seen_paths and not seen_paths.add(image)
        ]
        if unique_images:
            root_images.append((root, unique_images))
            total_images += len(unique_images)
    if not total_images:
        print("未找到支持的图片文件")
        sys.exit(1)

    root_of = {image: root for root, images in root_images for image in images}

    # 输出目录：替换模式就地写入；单根目录写入同级时间戳文件夹；
    # 多根目录统一写入 <首个根的同级>/WebP_<时间戳>/，按根名分组保持结构。
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    if args.replace:
        output_dir = None
    elif len(input_roots) == 1:
        root = input_roots[0]
        base_name = root.stem if root.is_file() else root.name
        output_dir = root.parent / f"{base_name}_webp_{timestamp}"
    else:
        output_dir = input_roots[0].parent / f"WebP_{timestamp}"
    if output_dir is not None:
        output_dir.mkdir(parents=True, exist_ok=True)

    def relative_to_root(root: Path, image: Path) -> Path:
        relative = image.relative_to(root)
        # 单文件根目录时 image == root，relative_to 返回 '.'，直接取文件名
        return Path(image.name) if relative == Path(".") else relative

    def destination(root: Path, image: Path) -> Path:
        """计算单张图片的 WebP 输出路径"""
        if args.replace:
            return image.with_suffix(".webp")
        relative = relative_to_root(root, image).with_suffix(".webp")
        if len(input_roots) == 1:
            return output_dir / relative
        group = root.stem if root.is_file() else root.name
        return output_dir / group / relative

    def copy_unchanged(root: Path, image: Path):
        """文件夹输出模式下，把未转换的原图按结构复制到输出目录"""
        if args.replace or (len(input_roots) == 1 and root.is_file()):
            return
        relative = relative_to_root(root, image)
        if len(input_roots) == 1:
            unchanged_dst = output_dir / relative
        else:
            group = root.stem if root.is_file() else root.name
            unchanged_dst = output_dir / group / relative
        unchanged_dst.parent.mkdir(parents=True, exist_ok=True)
        if not unchanged_dst.exists():
            shutil.copy2(image, unchanged_dst)

    # 已是 WebP 的文件不重复编码
    tasks: list[tuple[Path, Path]] = []
    already_webp: list[tuple[Path, Path]] = []
    too_small: list[tuple[Path, Path]] = []
    for root, images in root_images:
        for image in images:
            if image.suffix.lower() == ".webp":
                already_webp.append((root, image))
            elif image.stat().st_size < minimum_bytes:
                too_small.append((root, image))
            else:
                tasks.append((image, destination(root, image)))

    report_dir = output_dir
    if report_dir is None:
        first_root = input_roots[0]
        report_dir = first_root.parent if first_root.is_file() else first_root

    print(f"{'=' * 60}")
    print(f"  WebP 批量转换工具")
    print(f"{'=' * 60}")
    for root in input_roots:
        print(f"  输入: {root}")
    print(f"  输出: {report_dir}")
    print(f"  模式: {'自动替换原图' if args.replace else '生成同级输出文件夹'}")
    print(f"  图片数量: {total_images}")
    print(f"  质量: {quality}")
    print(f"  最长边限制: {max_side if max_side > 0 else '不限制'}")
    print(f"  最低转换大小: {format_size(minimum_bytes)}")
    print(f"  并发数: {MAX_WORKERS}")
    print(f"{'=' * 60}\n", flush=True)

    def emit_status(index: int, total: int, result: dict):
        before = result["before"]
        after = result["after"]
        name = Path(result["src"]).name
        if result["ok"]:
            saved = (before - after) / before * 100 if before > 0 else 0
            status = f"✅ -{saved:.1f}% ({format_size(before)} → {format_size(after)})"
        elif result["skipped"]:
            status = f"⚠️ {result['error']}"
        else:
            status = f"❌ {result['error'][:60]}"
        print(f"  [{index}/{total}] {name}  {status}  ⏱ {format_elapsed(time.time() - start_time)}")
        emit_event(
            Path(result["src"]),
            Path(result["dst"]),
            before,
            after,
            result["ok"],
            result["skipped"],
            result["error"],
        )

    total_all = len(tasks) + len(already_webp) + len(too_small)
    completed = 0
    converted = 0
    skipped_count = len(already_webp) + len(too_small)
    grand_before = sum(image.stat().st_size for _, images in root_images for image in images)
    grand_after = sum(image.stat().st_size for _, image in already_webp + too_small)
    failures = 0

    start_time = time.time()
    if tasks:
        with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
            future_map = {
                executor.submit(convert_image, src, dst, quality, max_side, args.replace): (src, dst)
                for src, dst in tasks
            }
            for future in as_completed(future_map):
                completed += 1
                result = future.result()
                grand_after += result["after"]
                if result["ok"]:
                    converted += 1
                else:
                    if result["skipped"]:
                        skipped_count += 1
                    else:
                        failures += 1
                    source = Path(result["src"])
                    copy_unchanged(root_of[source], source)
                emit_status(completed, total_all, result)

    for _, image in already_webp + too_small:
        copy_unchanged(root_of[image], image)

    saved_total = grand_before - grand_after
    saved_pct = saved_total / grand_before * 100 if grand_before > 0 else 0

    print(f"\n{'=' * 60}")
    print(f"  转换完成!")
    print(f"  总数: {total_all}  转换: {converted}  跳过: {skipped_count}  失败: {failures}")
    print(f"  转换前: {format_size(grand_before)}")
    print(f"  转换后: {format_size(grand_after)}")
    print(f"  节省:   {format_size(saved_total)} ({saved_pct:.1f}%)")
    print(f"  总用时: {format_elapsed(time.time() - start_time)}")
    print(f"  输出目录: {report_dir}")
    print(f"{'=' * 60}")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
