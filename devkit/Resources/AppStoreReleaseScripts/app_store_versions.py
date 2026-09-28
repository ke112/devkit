#!/usr/bin/env python3
"""List apps and manage iOS App Store versions through Apple's official API."""

from __future__ import annotations

import argparse
import json
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from upload_localizations import (
    EDITABLE_STATES,
    AppStoreConnectClient,
    AppConfig,
    AuthConfig,
    load_config,
)


VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){0,2}$")
CREATE_VISIBILITY_TIMEOUT_SECONDS = 60
CREATE_VISIBILITY_POLL_INTERVAL_SECONDS = 2
APP_VERSION_WORKERS = 16


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="管理 App Store Connect 的 App 信息与 iOS 版本。")
    parser.add_argument("--config", required=True, help="DevKit App Store Connect 配置文件。")
    parser.add_argument("--output", required=True, help="结构化结果输出路径。")
    parser.add_argument("command", choices=("list", "create", "apps"))
    parser.add_argument("--version-string", default="", help="要创建的版本号，例如 2.2.0。")
    parser.add_argument(
        "--skip-versions",
        action="store_true",
        help="apps 命令专用：只读取 App 基础信息，跳过逐个 App 的版本查询。",
    )
    return parser.parse_args()


def version_payload(app_id: str, version_string: str, platform: str) -> dict[str, object]:
    return {
        "data": {
            "type": "appStoreVersions",
            "attributes": {
                "platform": platform,
                "versionString": version_string,
            },
            "relationships": {
                "app": {
                    "data": {
                        "type": "apps",
                        "id": app_id,
                    },
                },
            },
        },
    }


def serialize_version(item: dict[str, object]) -> dict[str, object]:
    attributes = item.get("attributes") or {}
    if not isinstance(attributes, dict):
        attributes = {}
    return {
        "id": str(item.get("id") or ""),
        "versionString": str(attributes.get("versionString") or ""),
        "platform": str(attributes.get("platform") or ""),
        "appStoreState": str(attributes.get("appStoreState") or ""),
        "createdDate": attributes.get("createdDate"),
        "releaseType": attributes.get("releaseType"),
        "earliestReleaseDate": attributes.get("earliestReleaseDate"),
    }


def list_versions(client: AppStoreConnectClient, app_config: AppConfig) -> list[dict[str, object]]:
    versions = client.list_all(
        f"/v1/apps/{app_config.app_id}/appStoreVersions",
        query={"filter[platform]": app_config.platform, "limit": 200},
    )
    return sorted(
        (serialize_version(item) for item in versions),
        key=lambda item: str(item.get("createdDate") or ""),
        reverse=True,
    )


def suggested_version_string(versions: list[dict[str, object]]) -> str:
    """Pick the newest editable version, the same fallback the upload flow uses."""
    for item in versions:
        if item.get("appStoreState") in EDITABLE_STATES:
            return str(item.get("versionString") or "")
    return ""


def list_apps(
    client: AppStoreConnectClient,
    auth_config: AuthConfig,
    *,
    include_versions: bool = True,
) -> list[dict[str, object]]:
    apps = client.list_all(
        "/v1/apps",
        query={
            "limit": 200,
            "fields[apps]": "name,bundleId,primaryLocale",
        },
    )
    summaries = []
    for item in apps:
        attributes = item.get("attributes") or {}
        if not isinstance(attributes, dict):
            attributes = {}
        app_id = str(item.get("id") or "")
        if not app_id:
            continue
        summaries.append(
            {
                "id": app_id,
                "name": str(attributes.get("name") or ""),
                "bundleId": str(attributes.get("bundleId") or ""),
                "primaryLocale": str(attributes.get("primaryLocale") or ""),
                "suggestedVersion": "",
            }
        )
    if not include_versions or not summaries:
        return summaries

    # 每个工作线程持有独立客户端，避免并发刷新共享 JWT 产生竞态。
    thread_local = threading.local()
    failed_ids: list[str] = []

    def client_for_thread() -> AppStoreConnectClient:
        instance = getattr(thread_local, "client", None)
        if instance is None:
            instance = AppStoreConnectClient(auth_config)
            thread_local.client = instance
        return instance

    def fetch_suggested_version(summary: dict[str, object]) -> dict[str, object]:
        versions: list[dict[str, object]] = []
        for attempt in (1, 2):
            try:
                versions = list_versions(
                    client_for_thread(),
                    AppConfig(
                        app_id=str(summary["id"]),
                        bundle_id=None,
                        platform="IOS",
                        version_string=None,
                    ),
                )
                break
            except Exception:
                # 网络抖动（如连接被重置）不应影响整体结果；重试一次后仍失败则留空。
                if attempt == 2:
                    failed_ids.append(str(summary["id"]))
                else:
                    time.sleep(0.5)
        summary["suggestedVersion"] = suggested_version_string(versions)
        return summary

    print(f"开始并行读取 {len(summaries)} 个 App 的版本信息…")
    with ThreadPoolExecutor(max_workers=APP_VERSION_WORKERS) as pool:
        for index, summary in enumerate(pool.map(fetch_suggested_version, summaries), 1):
            print(f"已读取 {index}/{len(summaries)} 个 App 的版本信息。")

    if failed_ids:
        print(f"有 {len(failed_ids)} 个 App 的版本信息读取失败，其可编辑版本将留空。")
    return summaries


def validate_access(client: AppStoreConnectClient, app_config: AppConfig) -> None:
    if not app_config.app_id:
        raise ValueError("app.app_id 不能为空。")
    app = client.request_json("GET", f"/v1/apps/{app_config.app_id}")["data"]
    actual_bundle_id = app.get("attributes", {}).get("bundleId")
    if app_config.bundle_id and actual_bundle_id != app_config.bundle_id:
        raise ValueError(
            "配置里的 bundle_id 与 App Store Connect 不一致: "
            f"{app_config.bundle_id} != {actual_bundle_id}",
        )


def wait_for_created_version(
    client: AppStoreConnectClient,
    app_config: AppConfig,
    version_string: str,
    *,
    timeout_seconds: int = CREATE_VISIBILITY_TIMEOUT_SECONDS,
    poll_interval_seconds: int = CREATE_VISIBILITY_POLL_INTERVAL_SECONDS,
) -> list[dict[str, object]]:
    """Wait for Apple's version list to expose a just-created version.

    The create endpoint can acknowledge before the collection endpoint reflects
    the new resource. Never report success until the later upload lookup can see
    the version as well.
    """
    deadline = time.monotonic() + timeout_seconds
    while True:
        versions = list_versions(client, app_config)
        if any(item["versionString"] == version_string for item in versions):
            return versions
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(
                f"版本 {version_string} 的创建请求已提交，但在 {timeout_seconds} 秒内仍未出现在 App Store Connect 版本列表。"
                " 请稍后点击刷新确认，不要重复创建。",
            )
        time.sleep(min(poll_interval_seconds, remaining))


def main() -> int:
    args = parse_args()
    config_path = Path(args.config).expanduser().resolve()
    auth_config, app_config, _ = load_config(config_path)
    if not auth_config.issuer_id or not auth_config.key_id:
        raise ValueError("auth.issuer_id 和 auth.key_id 不能为空。")
    client = AppStoreConnectClient(auth_config)
    output_path = Path(args.output).expanduser().resolve()

    if args.command == "apps":
        apps = list_apps(client, auth_config, include_versions=not args.skip_versions)
        output_path.write_text(
            json.dumps({"apps": apps}, ensure_ascii=False),
            encoding="utf-8",
        )
        print(f"已读取 {len(apps)} 个可访问的 App。")
        return 0

    validate_access(client, app_config)

    if args.command == "create":
        version_string = args.version_string.strip()
        if not VERSION_PATTERN.fullmatch(version_string) or len(version_string) > 18:
            raise ValueError("版本号必须是最多 18 个字符的数字版本，例如 2.2.0。")
        existing = list_versions(client, app_config)
        if any(item["versionString"] == version_string for item in existing):
            raise ValueError(f"版本 {version_string} 已存在，不能重复创建。")
        client.request_json(
            "POST",
            "/v1/appStoreVersions",
            payload=version_payload(app_config.app_id, version_string, app_config.platform),
        )
        versions = wait_for_created_version(client, app_config, version_string)
    else:
        versions = list_versions(client, app_config)

    response = {"versions": versions}
    output_path.write_text(json.dumps(response, ensure_ascii=False), encoding="utf-8")
    print(f"已读取 {len(response['versions'])} 个 iOS 版本。")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False))
        raise SystemExit(1)
