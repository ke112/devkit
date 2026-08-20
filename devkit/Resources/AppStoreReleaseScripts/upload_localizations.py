#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
使用 Apple 官方 App Store Connect API 上传 iOS 多语种本地化元数据与截图。

支持内容：
1. App 信息里的副标题（`appInfoLocalizations.subtitle`）
2. 版本本地化里的推广文本、描述、此版本新增内容、关键词
3. 按文件名升序上传截图，最多 10 张，并按上传顺序在后台从左到右展示

目录约定：
localizations/
  en-US/
    metadata.json
    screenshots/
      APP_IPHONE_65/
        01_home.png
        02_chat.png
  ja/
    metadata.json
    screenshots/
      APP_IPHONE_65/
        01_home.png

DevKit 会通过 `--config` 传入独立配置。正式上传前需填入
`auth.issuer_id`、`auth.key_id`、`auth.private_key_path`、`app.app_id`。

用法示例：

# 预演（不改线上数据）
python3 upload_localizations.py --config app_store_connect.json --dry-run

# 正式上传
python3 upload_localizations.py --config app_store_connect.json

# 只传文案
python3 upload_localizations.py --config app_store_connect.json --skip-screenshots

# 只传截图
python3 upload_localizations.py --config app_store_connect.json --skip-metadata

# 指定本机截图根目录
python3 upload_localizations.py --config app_store_connect.json \
  --skip-metadata --screenshots-root /Users/kk/Downloads/ios \
  --locale id

# 只处理某个语种
python3 upload_localizations.py --config app_store_connect.json --locale ja

# 只处理多个语种
python3 upload_localizations.py --config app_store_connect.json --locale ja --locale en-US
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Iterable
from urllib import error, parse, request

API_BASE_URL = 'https://api.appstoreconnect.apple.com'
DEFAULT_PLATFORM = 'IOS'
DEFAULT_POLL_INTERVAL_SECONDS = 2
DEFAULT_POLL_TIMEOUT_SECONDS = 300
DEFAULT_MAX_CONCURRENT_LOCALES = 11
DEFAULT_UPLOAD_RETRY_COUNT = 3
IMAGE_SUFFIXES = {'.jpeg', '.jpg', '.png'}
SCREENSHOT_SIZE_ALLOWLIST = {
    # App Store Connect API uses APP_IPHONE_67 for the large iPhone screenshot slot.
    # For current 6.9" screenshots, Apple accepts several device-native sizes.
    'APP_IPHONE_67': {
        (1260, 2736),
        (2736, 1260),
        (1290, 2796),
        (2796, 1290),
        (1320, 2868),
        (2868, 1320),
    },
}
SCRIPT_DIR = Path(__file__).resolve().parent
LOCAL_CONFIG_PATH = SCRIPT_DIR / 'config' / 'app_store_connect.local.json'
EXAMPLE_CONFIG_PATH = SCRIPT_DIR / 'config' / 'app_store_connect.example.json'
DEFAULT_CONFIG_PATH = (
    LOCAL_CONFIG_PATH
    if LOCAL_CONFIG_PATH.is_file()
    else EXAMPLE_CONFIG_PATH
)
PLACEHOLDER_AUTH_VALUES = {
    '00000000-0000-0000-0000-000000000000',
    'ABC123DEFG',
    '~/.appstoreconnect/AuthKey_ABC123DEFG.p8',
}
LOCALE_LABEL_MAP = {
    # 常见 App Store Connect locale 显示名。
    'de-DE': '德语',
    'en-US': '英语',
    'es-ES': '西班牙',
    'fil-PH': '菲律宾语',
    'fr-FR': '法语',
    'id': '印度尼西亚语',
    'it': '意大利语',
    'ja': '日语',
    'ko': '韩语',
    'nl-NL': '荷兰语',
    'pl': '波兰语',
    'pt-PT': '葡萄牙语（葡萄牙）',
    'zh-Hans': '中文简体',
    'zh-Hant': '中文繁体',
    # Apple 常见支持 locale，可按需启用。
    # 'pt-BR': '葡萄牙语（巴西）',
    # 'ar-SA': '阿拉伯语',
    # 'ca': '加泰罗尼亚语',
    # 'cs': '捷克语',
    # 'da': '丹麦语',
    # 'el': '希腊语',
    # 'en-AU': '英文（澳大利亚）',
    # 'en-CA': '英文（加拿大）',
    # 'en-GB': '英文（英国）',
    # 'es-MX': '西班牙语（墨西哥）',
    # 'fi': '芬兰语',
    # 'fr-CA': '法文（加拿大）',
    # 'he': '希伯来语',
    # 'hi': '北印度语',
    # 'hr': '克罗地亚语',
    # 'hu': '匈牙利语',
    # 'id': '印度尼西亚语',
    # 'ms': '马来语',
    # 'no': '挪威语',
    # 'ro': '罗马尼亚语',
    # 'ru': '俄语',
    # 'sk': '斯洛伐克语',
    # 'sv': '瑞典语',
    # 'th': '泰语',
    # 'tr': '土耳其语',
    # 'uk': '乌克兰语',
    # 'vi': '越南语',
}
LOCALE_SCREENSHOT_DIR_ALIASES = {
    'id': {'印尼语', '印尼'},
}
EDITABLE_STATES = {
    'DEVELOPER_REJECTED',
    'INVALID_BINARY',
    'METADATA_REJECTED',
    'PREPARE_FOR_SUBMISSION',
    'READY_FOR_REVIEW',
    'REJECTED',
    'WAITING_FOR_REVIEW',
}


class AppStoreConnectApiError(RuntimeError):
    """App Store Connect API 请求失败。"""


@dataclass(frozen=True)
class AuthConfig:
    """官方 API 认证配置。"""

    issuer_id: str | None
    key_id: str | None
    private_key_path: Path | None


@dataclass(frozen=True)
class AppConfig:
    """App 目标配置。"""

    app_id: str
    bundle_id: str | None
    platform: str
    version_string: str | None


@dataclass(frozen=True)
class UploadConfig:
    """上传行为配置。"""

    localizations_root: Path
    screenshots_root: Path | None
    locale_screenshot_dir_map: dict[str, str]
    disabled_locales: set[str]
    default_screenshot_display_type: str | None
    allow_create_localizations: bool
    clear_existing_screenshots: bool
    continue_on_locale_error: bool
    poll_interval_seconds: int
    poll_timeout_seconds: int


@dataclass(frozen=True)
class LocalePlan:
    """单个语种目录的上传计划。"""

    locale: str
    directory: Path
    metadata: dict[str, Any]


@dataclass(frozen=True)
class ScreenshotSetPlan:
    """单个展示位截图上传计划。"""

    display_type: str
    directory: Path
    files: list[Path]
    clear_before_upload: bool


class ThreadAwareStdout:
    """按线程分流 stdout，避免并发日志互相穿插。"""

    def __init__(self, target: Any) -> None:
        self._target = target
        self._lock = threading.Lock()
        self._local = threading.local()

    def set_prefix(self, prefix: str) -> None:
        self._local.prefix = prefix
        self._local.is_at_line_start = True

    def write(self, data: str) -> int:
        prefix = str(getattr(self._local, 'prefix', ''))
        is_at_line_start = bool(
            getattr(self._local, 'is_at_line_start', True),
        )
        output_parts: list[str] = []

        for char in data:
            if is_at_line_start and char != '\n':
                output_parts.append(prefix)
                is_at_line_start = False
            output_parts.append(char)
            if char == '\n':
                is_at_line_start = True

        self._local.is_at_line_start = is_at_line_start
        output = ''.join(output_parts)
        with self._lock:
            return self._target.write(output)

    def flush(self) -> None:
        with self._lock:
            self._target.flush()

    def isatty(self) -> bool:
        return bool(getattr(self._target, 'isatty', lambda: False)())

    @property
    def encoding(self) -> str | None:
        return getattr(self._target, 'encoding', None)


class AppStoreConnectClient:
    """官方 App Store Connect API 客户端。"""

    def __init__(self, auth_config: AuthConfig, timeout_seconds: int = 120) -> None:
        self._auth_config = auth_config
        self._timeout_seconds = timeout_seconds
        self._token = ''
        self._token_expires_at = 0
        self._validate_environment()

    def _validate_environment(self) -> None:
        if self._auth_config.private_key_path is None:
            raise ValueError('auth.private_key_path 不能为空。')
        if not self._auth_config.private_key_path.is_file():
            raise FileNotFoundError(
                f'找不到私钥文件: {self._auth_config.private_key_path}',
            )
        result = subprocess.run(
            ['openssl', 'version'],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError('当前环境未安装 openssl，无法生成官方 API JWT。')

    def _encode_base64url(self, value: bytes) -> str:
        return base64.urlsafe_b64encode(value).rstrip(b'=').decode('utf-8')

    def _read_der_length(self, data: bytes, offset: int) -> tuple[int, int]:
        if offset >= len(data):
            raise RuntimeError('生成 JWT 失败: DER 签名缺少长度字段。')
        first_byte = data[offset]
        next_offset = offset + 1
        if first_byte < 0x80:
            return first_byte, next_offset
        length_size = first_byte & 0x7F
        if length_size == 0:
            raise RuntimeError('生成 JWT 失败: DER 签名长度字段无效。')
        end_offset = next_offset + length_size
        if end_offset > len(data):
            raise RuntimeError('生成 JWT 失败: DER 签名长度超出范围。')
        return int.from_bytes(data[next_offset:end_offset], 'big'), end_offset

    def _read_der_integer(self, data: bytes, offset: int) -> tuple[int, int]:
        if offset >= len(data) or data[offset] != 0x02:
            raise RuntimeError('生成 JWT 失败: DER 签名缺少整数节点。')
        value_length, value_offset = self._read_der_length(data, offset + 1)
        end_offset = value_offset + value_length
        if end_offset > len(data):
            raise RuntimeError('生成 JWT 失败: DER 整数长度超出范围。')
        return int.from_bytes(data[value_offset:end_offset], 'big'), end_offset

    def _convert_der_signature_to_raw(self, der_signature: bytes) -> bytes:
        if not der_signature or der_signature[0] != 0x30:
            raise RuntimeError('生成 JWT 失败: openssl 未返回合法的 DER 签名。')
        sequence_length, offset = self._read_der_length(der_signature, 1)
        sequence_end = offset + sequence_length
        if sequence_end != len(der_signature):
            raise RuntimeError('生成 JWT 失败: DER 签名长度与内容不一致。')
        r_value, offset = self._read_der_integer(der_signature, offset)
        s_value, offset = self._read_der_integer(der_signature, offset)
        if offset != len(der_signature):
            raise RuntimeError('生成 JWT 失败: DER 签名包含多余数据。')
        try:
            return (
                r_value.to_bytes(32, 'big')
                + s_value.to_bytes(32, 'big')
            )
        except OverflowError as exc:
            raise RuntimeError(
                '生成 JWT 失败: DER 签名超出 ES256 预期长度。',
            ) from exc

    def _generate_token(self) -> tuple[str, int]:
        issued_at = int(time.time())
        expires_at = issued_at + (19 * 60)
        header = {
            'alg': 'ES256',
            'kid': self._auth_config.key_id,
            'typ': 'JWT',
        }
        payload = {
            'iss': self._auth_config.issuer_id,
            'iat': issued_at,
            'exp': expires_at,
            'aud': 'appstoreconnect-v1',
        }
        header_segment = self._encode_base64url(
            json.dumps(header, separators=(',', ':')).encode('utf-8'),
        )
        payload_segment = self._encode_base64url(
            json.dumps(payload, separators=(',', ':')).encode('utf-8'),
        )
        signing_input = f'{header_segment}.{payload_segment}'.encode('utf-8')
        result = subprocess.run(
            [
                'openssl',
                'dgst',
                '-sha256',
                '-sign',
                str(self._auth_config.private_key_path),
            ],
            input=signing_input,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            stderr = result.stderr.decode('utf-8', errors='ignore').strip()
            raise RuntimeError(f'生成 JWT 失败: {stderr or "openssl 返回异常"}')
        # openssl 返回的是 ASN.1/DER 格式 ECDSA 签名，JWT 需要 r||s 原始格式。
        signature_segment = self._encode_base64url(
            self._convert_der_signature_to_raw(result.stdout),
        )
        token = f'{header_segment}.{payload_segment}.{signature_segment}'
        return token, expires_at

    def _get_token(self) -> str:
        now = int(time.time())
        if self._token and now < self._token_expires_at - 60:
            return self._token
        self._token, self._token_expires_at = self._generate_token()
        return self._token

    def _build_url(self, path: str, query: dict[str, Any] | None = None) -> str:
        if path.startswith('http://') or path.startswith('https://'):
            return path
        query_string = ''
        if query:
            filtered_query = {
                key: value
                for key, value in query.items()
                if value is not None and value != ''
            }
            if filtered_query:
                query_string = f'?{parse.urlencode(filtered_query, doseq=True)}'
        return f'{API_BASE_URL}{path}{query_string}'

    def _parse_error_message(self, body: str) -> str:
        if not body:
            return '未返回错误详情'
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            return body.strip()
        errors_data = data.get('errors')
        if not isinstance(errors_data, list):
            return body.strip()
        messages: list[str] = []
        for item in errors_data:
            status = item.get('status') or 'unknown'
            code = item.get('code') or 'unknown'
            detail = item.get('detail') or item.get('title') or '未知错误'
            messages.append(f'[{status}/{code}] {detail}')
        return '; '.join(messages) if messages else body.strip()

    def request_json(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, Any] | None = None,
        payload: dict[str, Any] | None = None,
        expected_statuses: Iterable[int] = (200, 201),
        authenticated: bool = True,
    ) -> dict[str, Any]:
        url = self._build_url(path, query)
        return self.request_json_url(
            method,
            url,
            payload=payload,
            expected_statuses=expected_statuses,
            authenticated=authenticated,
        )

    def request_json_url(
        self,
        method: str,
        url: str,
        *,
        payload: dict[str, Any] | None = None,
        expected_statuses: Iterable[int] = (200, 201),
        authenticated: bool = True,
    ) -> dict[str, Any]:
        headers = {
            'Accept': 'application/json',
        }
        body: bytes | None = None
        if authenticated:
            headers['Authorization'] = f'Bearer {self._get_token()}'
        if payload is not None:
            headers['Content-Type'] = 'application/json'
            body = json.dumps(payload, separators=(',', ':')).encode('utf-8')
        req = request.Request(
            url=url,
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with request.urlopen(req, timeout=self._timeout_seconds) as response:
                response_body = response.read().decode('utf-8')
                if response.status not in set(expected_statuses):
                    raise AppStoreConnectApiError(
                        f'接口返回了未预期状态码: {response.status}',
                    )
                if not response_body:
                    return {}
                return json.loads(response_body)
        except error.HTTPError as http_error:
            response_body = http_error.read().decode('utf-8', errors='ignore')
            message = self._parse_error_message(response_body)
            raise AppStoreConnectApiError(
                f'{method} {url} 失败: {message}',
            ) from http_error
        except error.URLError as url_error:
            raise AppStoreConnectApiError(
                f'{method} {url} 失败: {url_error.reason}',
            ) from url_error

    def upload_bytes(
        self,
        *,
        method: str,
        url: str,
        data: bytes,
        request_headers: list[dict[str, str]],
    ) -> None:
        headers = {
            item['name']: item['value']
            for item in request_headers
            if 'name' in item and 'value' in item
        }
        retryable_statuses = {408, 429, 500, 502, 503, 504}
        for attempt in range(1, DEFAULT_UPLOAD_RETRY_COUNT + 1):
            req = request.Request(
                url=url,
                data=data,
                headers=headers,
                method=method,
            )
            try:
                with request.urlopen(
                    req,
                    timeout=self._timeout_seconds,
                ) as response:
                    if response.status in {200, 201, 204}:
                        return
                    if (
                        response.status in retryable_statuses
                        and attempt < DEFAULT_UPLOAD_RETRY_COUNT
                    ):
                        self._sleep_before_retry(attempt)
                        continue
                    raise AppStoreConnectApiError(
                        f'上传分片失败，状态码: {response.status}',
                    )
            except error.HTTPError as http_error:
                response_body = http_error.read().decode(
                    'utf-8',
                    errors='ignore',
                )
                if (
                    http_error.code in retryable_statuses
                    and attempt < DEFAULT_UPLOAD_RETRY_COUNT
                ):
                    self._sleep_before_retry(attempt)
                    continue
                raise AppStoreConnectApiError(
                    f'上传分片失败: {self._parse_error_message(response_body)}',
                ) from http_error
            except (TimeoutError, error.URLError) as exc:
                if attempt < DEFAULT_UPLOAD_RETRY_COUNT:
                    self._sleep_before_retry(attempt)
                    continue
                reason = getattr(exc, 'reason', exc)
                raise AppStoreConnectApiError(
                    f'上传分片失败: {reason}',
                ) from exc

    def _sleep_before_retry(self, attempt: int) -> None:
        time.sleep(min(2 ** attempt, 10))

    def list_all(
        self,
        path: str,
        *,
        query: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        url = self._build_url(path, query)
        items: list[dict[str, Any]] = []
        while url:
            response = self.request_json_url('GET', url)
            items.extend(response.get('data', []))
            url = response.get('links', {}).get('next', '')
        return items


class AppStoreMetadataUploader:
    """上传元数据与截图的主流程。"""

    def __init__(
        self,
        client: AppStoreConnectClient,
        app_config: AppConfig,
        upload_config: UploadConfig,
        *,
        dry_run: bool,
        selected_locales: set[str],
        skip_metadata: bool,
        skip_screenshots: bool,
    ) -> None:
        self._client = client
        self._app_config = app_config
        self._upload_config = upload_config
        self._dry_run = dry_run
        self._selected_locales = selected_locales
        self._skip_metadata = skip_metadata
        self._skip_screenshots = skip_screenshots
        self._prepared_screenshots: dict[Path, tuple[str, bytes]] = {}
        self._stdout_router = ThreadAwareStdout(sys.stdout)

    def run(self) -> None:
        original_stdout = sys.stdout
        sys.stdout = self._stdout_router
        try:
            started_at = time.monotonic()
            self._print_header()
            app_data = self._read_app()
            self._validate_bundle_id(app_data)
            version = self._select_target_version()
            app_info = self._select_target_app_info(version)
            version_localizations = self._list_localizations(
                f'/v1/appStoreVersions/{version["id"]}/appStoreVersionLocalizations',
            )
            info_localizations = self._list_localizations(
                f'/v1/appInfos/{app_info["id"]}/appInfoLocalizations',
            )
            locale_plans = self._load_locale_plans(version_localizations)
            print('')
            print(f'🎯 目标 App: {app_data["attributes"].get("name", "未知应用")}')
            print(f'   App ID: {self._app_config.app_id}')
            print(
                f'   Version: {version["attributes"].get("versionString")} '
                f'({version["attributes"].get("appStoreState")})',
            )
            print(
                f'   当前版本状态: '
                f'{version["attributes"].get("appStoreState")}',
            )
            print(
                '   Locales: '
                + ', '.join(
                    self._format_locale_display(plan.locale)
                    for plan in locale_plans
                ),
            )
            print(
                '   并发语种数: '
                f'{min(DEFAULT_MAX_CONCURRENT_LOCALES, len(locale_plans))}',
            )
            if self._upload_config.disabled_locales:
                disabled_locale_text = ', '.join(
                    self._format_locale_display(locale)
                    for locale in sorted(self._upload_config.disabled_locales)
                )
                print(f'   Disabled locales: {disabled_locale_text}')

            completed_locales, failed_locales = self._run_locale_tasks(
                locale_plans=locale_plans,
                app_info_id=app_info['id'],
                version_id=version['id'],
                info_localizations=info_localizations,
                version_localizations=version_localizations,
                started_at=started_at,
            )

            print('')
            print('✅ 语种处理结束')
            print(f'   总耗时: {self._format_elapsed_time(started_at)}')
            if completed_locales:
                print(
                    '   成功: '
                    + ', '.join(
                        self._format_locale_display(locale)
                        for locale in completed_locales
                    ),
                )
            if failed_locales:
                print('   失败:')
                for locale, message in failed_locales:
                    print(f'   - {self._format_locale_display(locale)}: {message}')
        finally:
            sys.stdout = original_stdout

    def _run_locale_tasks(
        self,
        *,
        locale_plans: list[LocalePlan],
        app_info_id: str,
        version_id: str,
        info_localizations: dict[str, dict[str, Any]],
        version_localizations: dict[str, dict[str, Any]],
        started_at: float,
    ) -> tuple[list[str], list[tuple[str, str]]]:
        completed_locales: list[str] = []
        failed_locales: list[tuple[str, str]] = []
        total_locale_count = len(locale_plans)
        max_workers = min(DEFAULT_MAX_CONCURRENT_LOCALES, total_locale_count)
        first_failure: tuple[str, str] | None = None
        futures = []

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            for index, locale_plan in enumerate(locale_plans, start=1):
                future = executor.submit(
                    self._run_single_locale_task,
                    index=index,
                    total_locale_count=total_locale_count,
                    locale_plan=locale_plan,
                    app_info_id=app_info_id,
                    version_id=version_id,
                    info_localizations=info_localizations,
                    version_localizations=version_localizations,
                    started_at=started_at,
                )
                futures.append(future)
            for future in as_completed(futures):
                locale, error_message = future.result()
                if error_message is None:
                    completed_locales.append(locale)
                    continue
                failed_locales.append((locale, error_message))
                if first_failure is None:
                    first_failure = (locale, error_message)
                if not self._upload_config.continue_on_locale_error:
                    for pending_future in futures:
                        pending_future.cancel()

        if first_failure and not self._upload_config.continue_on_locale_error:
            locale, message = first_failure
            raise RuntimeError(
                f'语种 {self._format_locale_display(locale)} 处理失败: {message}',
            )
        return completed_locales, failed_locales

    def _run_single_locale_task(
        self,
        *,
        index: int,
        total_locale_count: int,
        locale_plan: LocalePlan,
        app_info_id: str,
        version_id: str,
        info_localizations: dict[str, dict[str, Any]],
        version_localizations: dict[str, dict[str, Any]],
        started_at: float,
    ) -> tuple[str, str | None]:
        self._stdout_router.set_prefix(f'[{locale_plan.locale}] ')
        error_message: str | None = None
        locale_label = self._get_locale_label(locale_plan.locale)
        print('')
        print(
            f'🌍 [{index}/{total_locale_count}] 处理语种: '
            f'{locale_plan.locale}（{locale_label}）',
        )
        try:
            worker_client = AppStoreConnectClient(
                self._client._auth_config,
                timeout_seconds=self._client._timeout_seconds,
            )
            worker_uploader = AppStoreMetadataUploader(
                worker_client,
                self._app_config,
                self._upload_config,
                dry_run=self._dry_run,
                selected_locales=set(),
                skip_metadata=self._skip_metadata,
                skip_screenshots=self._skip_screenshots,
            )
            worker_uploader._stdout_router = self._stdout_router
            app_info_localization = None
            version_localization = None
            if not self._skip_metadata:
                app_info_localization = worker_uploader._ensure_app_info_localization(
                    locale_plan,
                    app_info_id,
                    dict(info_localizations),
                )
                version_localization = worker_uploader._ensure_version_localization(
                    locale_plan,
                    version_id,
                    dict(version_localizations),
                )
                worker_uploader._update_app_info_localization(
                    locale_plan,
                    app_info_localization,
                )
                worker_uploader._update_version_localization(
                    locale_plan,
                    version_localization,
                )
            if not self._skip_screenshots:
                version_localization = (
                    version_localization
                    or version_localizations.get(locale_plan.locale)
                )
                worker_uploader._sync_screenshots(
                    locale_plan,
                    version_localization,
                )
        except Exception as exc:
            error_message = str(exc)
            if self._upload_config.continue_on_locale_error:
                print(
                    '  ⚠️ 语种 '
                    f'{self._format_locale_display(locale_plan.locale)} '
                    f'处理失败，继续后续语种: {exc}',
                )
            else:
                print(
                    '  ❌ 语种 '
                    f'{self._format_locale_display(locale_plan.locale)} '
                    f'处理失败: {exc}',
                )
        finally:
            print(f'  ⏱ 当前总耗时: {self._format_elapsed_time(started_at)}')
        return locale_plan.locale, error_message

    def _format_elapsed_time(self, started_at: float) -> str:
        elapsed_seconds = int(time.monotonic() - started_at)
        hours, remainder = divmod(elapsed_seconds, 3600)
        minutes, seconds = divmod(remainder, 60)
        if hours > 0:
            return f'{hours}h {minutes}m {seconds}s'
        if minutes > 0:
            return f'{minutes}m {seconds}s'
        return f'{seconds}s'

    def _get_locale_label(self, locale: str) -> str:
        locale_label = LOCALE_LABEL_MAP.get(locale)
        if locale_label:
            return locale_label
        configured_label = self._upload_config.locale_screenshot_dir_map.get(locale)
        if configured_label:
            return configured_label
        return locale

    def _format_locale_display(self, locale: str) -> str:
        return f'{self._get_locale_label(locale)}（{locale}）'

    def _print_header(self) -> None:
        mode_text = 'DRY RUN' if self._dry_run else 'EXECUTE'
        print('🚀 App Store Connect 多语种本地化上传')
        print(f'   模式: {mode_text}')
        print(f'   平台: {self._app_config.platform}')
        print(f'   目录: {self._upload_config.localizations_root}')
        if self._upload_config.screenshots_root:
            print(f'   截图目录: {self._upload_config.screenshots_root}')

    def _read_app(self) -> dict[str, Any]:
        response = self._client.request_json(
            'GET',
            f'/v1/apps/{self._app_config.app_id}',
        )
        return response['data']

    def _validate_bundle_id(self, app_data: dict[str, Any]) -> None:
        expected_bundle_id = self._app_config.bundle_id
        if not expected_bundle_id:
            return
        current_bundle_id = app_data.get('attributes', {}).get('bundleId')
        if current_bundle_id != expected_bundle_id:
            raise ValueError(
                '配置里的 bundle_id 与 App Store Connect 不一致: '
                f'{expected_bundle_id} != {current_bundle_id}',
            )

    def _select_target_version(self) -> dict[str, Any]:
        versions = self._client.list_all(
            f'/v1/apps/{self._app_config.app_id}/appStoreVersions',
        )
        target_versions = [
            item
            for item in versions
            if item.get('attributes', {}).get('platform') == self._app_config.platform
        ]
        if not target_versions:
            raise ValueError('找不到目标平台的 App Store 版本。')
        if self._app_config.version_string:
            for item in target_versions:
                if (
                    item.get('attributes', {}).get('versionString')
                    == self._app_config.version_string
                ):
                    self._ensure_version_is_editable(item)
                    return item
            raise ValueError(
                f'找不到 version_string={self._app_config.version_string} 的版本。',
            )
        editable_versions = [
            item
            for item in target_versions
            if item.get('attributes', {}).get('appStoreState') in EDITABLE_STATES
        ]
        if not editable_versions:
            available_states = ', '.join(
                sorted(
                    {
                        str(item.get('attributes', {}).get('appStoreState') or '未知状态')
                        for item in target_versions
                    },
                ),
            )
            raise ValueError(
                '当前没有可编辑的 App Store 版本。'
                f' 当前可见版本状态: {available_states}',
            )
        sortable_versions = editable_versions
        return sorted(
            sortable_versions,
            key=lambda item: item.get('attributes', {}).get('createdDate', ''),
            reverse=True,
        )[0]

    def _ensure_version_is_editable(self, version: dict[str, Any]) -> None:
        version_state = str(version.get('attributes', {}).get('appStoreState') or '')
        if version_state in EDITABLE_STATES:
            return
        version_string = str(version.get('attributes', {}).get('versionString') or '')
        raise ValueError(
            '当前选中的版本不可编辑: '
            f'{version_string} ({version_state})。'
            ' 请改为可编辑状态的版本，或先在 App Store Connect 中调整版本状态。',
        )

    def _select_target_app_info(self, version: dict[str, Any]) -> dict[str, Any]:
        app_infos = self._client.list_all(
            f'/v1/apps/{self._app_config.app_id}/appInfos',
        )
        if not app_infos:
            raise ValueError('找不到 App Info，无法处理副标题。')
        version_state = version.get('attributes', {}).get('appStoreState')
        matched_state_items = [
            item
            for item in app_infos
            if item.get('attributes', {}).get('appStoreState') == version_state
        ]
        if matched_state_items:
            return matched_state_items[0]
        editable_items = [
            item
            for item in app_infos
            if item.get('attributes', {}).get('appStoreState') in EDITABLE_STATES
        ]
        return (editable_items or app_infos)[0]

    def _list_localizations(self, path: str) -> dict[str, dict[str, Any]]:
        items = self._client.list_all(path)
        return {
            item.get('attributes', {}).get('locale'): item
            for item in items
            if item.get('attributes', {}).get('locale')
        }

    def _is_duplicate_locale_error(self, exc: AppStoreConnectApiError) -> bool:
        message = str(exc)
        return (
            'ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE' in message
            or 'already exists. Try updating.' in message
        )

    def _refresh_localization(
        self,
        path: str,
        locale: str,
        localizations: dict[str, dict[str, Any]],
    ) -> dict[str, Any]:
        refreshed_localizations = self._list_localizations(path)
        refreshed = refreshed_localizations.get(locale)
        if not refreshed:
            raise ValueError(f'重新拉取后仍找不到语种 {locale} 的本地化资源。')
        localizations[locale] = refreshed
        return refreshed

    def _load_locale_plans(
        self,
        version_localizations: dict[str, dict[str, Any]],
    ) -> list[LocalePlan]:
        if self._skip_metadata:
            return self._load_screenshot_only_locale_plans(version_localizations)
        root = self._upload_config.localizations_root
        if not root.is_dir():
            raise FileNotFoundError(f'找不到本地化目录: {root}')
        locale_plans: list[LocalePlan] = []
        for directory in sorted(root.iterdir()):
            if not directory.is_dir():
                continue
            metadata_path = directory / 'metadata.json'
            if not metadata_path.is_file():
                print(f'⚠️ 跳过 {directory.name}: 缺少 metadata.json')
                continue
            metadata = self._read_json_file(metadata_path)
            locale = str(metadata.get('locale') or directory.name)
            if locale in self._upload_config.disabled_locales:
                print(f'ℹ️ 跳过 {locale}: 命中 disabled_locales 配置')
                continue
            if self._selected_locales and locale not in self._selected_locales:
                continue
            locale_plans.append(
                LocalePlan(
                    locale=locale,
                    directory=directory,
                    metadata=metadata,
                ),
            )
        if not locale_plans:
            raise ValueError('没有找到可上传的语种目录。')
        return locale_plans

    def _load_screenshot_only_locale_plans(
        self,
        version_localizations: dict[str, dict[str, Any]],
    ) -> list[LocalePlan]:
        locales = sorted(self._selected_locales or version_localizations.keys())
        locale_plans: list[LocalePlan] = []
        for locale in locales:
            if locale in self._upload_config.disabled_locales:
                print(f'ℹ️ 跳过 {locale}: 命中 disabled_locales 配置')
                continue
            if locale not in version_localizations:
                raise ValueError(
                    f'App Store Connect 缺少版本本地化 {locale}，'
                    '只传截图时无法自动创建；请先上传该语种 metadata，'
                    '或在 App Store Connect 后台创建该语种。',
                )
            locale_plans.append(
                LocalePlan(
                    locale=locale,
                    directory=self._upload_config.localizations_root / locale,
                    metadata={'locale': locale},
                ),
            )
        if not locale_plans:
            raise ValueError('没有找到可上传截图的语种。')
        return locale_plans

    def _ensure_app_info_localization(
        self,
        locale_plan: LocalePlan,
        app_info_id: str,
        localizations: dict[str, dict[str, Any]],
    ) -> dict[str, Any] | None:
        existing = localizations.get(locale_plan.locale)
        if existing:
            return existing
        if not self._upload_config.allow_create_localizations:
            raise ValueError(
                f'App Info 缺少语种 {locale_plan.locale}，且配置禁止自动创建。',
            )
        create_attributes = self._build_app_info_attributes(locale_plan.metadata)
        create_attributes['locale'] = locale_plan.locale
        if 'name' not in create_attributes:
            raise ValueError(
                f'语种 {locale_plan.locale} 缺少 name，无法创建新的 App Info Localization。',
            )
        payload = {
            'data': {
                'type': 'appInfoLocalizations',
                'attributes': create_attributes,
                'relationships': {
                    'appInfo': {
                        'data': {
                            'type': 'appInfos',
                            'id': app_info_id,
                        },
                    },
                },
            },
        }
        if self._dry_run:
            print(f'  [DRY RUN] 将创建 App Info Localization: {locale_plan.locale}')
            return None
        try:
            response = self._client.request_json(
                'POST',
                '/v1/appInfoLocalizations',
                payload=payload,
            )
        except AppStoreConnectApiError as exc:
            if not self._is_duplicate_locale_error(exc):
                raise
            print(
                f'  ℹ️ App Info Localization 已存在，改为复用: '
                f'{locale_plan.locale}',
            )
            return self._refresh_localization(
                f'/v1/appInfos/{app_info_id}/appInfoLocalizations',
                locale_plan.locale,
                localizations,
            )
        created = response['data']
        localizations[locale_plan.locale] = created
        print(f'  ✅ 已创建 App Info Localization: {locale_plan.locale}')
        return created

    def _ensure_version_localization(
        self,
        locale_plan: LocalePlan,
        version_id: str,
        localizations: dict[str, dict[str, Any]],
    ) -> dict[str, Any] | None:
        existing = localizations.get(locale_plan.locale)
        if existing:
            return existing
        if not self._upload_config.allow_create_localizations:
            raise ValueError(
                f'版本本地化缺少语种 {locale_plan.locale}，且配置禁止自动创建。',
            )
        create_attributes = self._build_version_attributes(locale_plan.metadata)
        create_attributes['locale'] = locale_plan.locale
        payload = {
            'data': {
                'type': 'appStoreVersionLocalizations',
                'attributes': create_attributes,
                'relationships': {
                    'appStoreVersion': {
                        'data': {
                            'type': 'appStoreVersions',
                            'id': version_id,
                        },
                    },
                },
            },
        }
        if self._dry_run:
            print(
                f'  [DRY RUN] 将创建 App Store Version Localization: '
                f'{locale_plan.locale}',
            )
            return None
        try:
            response = self._client.request_json(
                'POST',
                '/v1/appStoreVersionLocalizations',
                payload=payload,
            )
        except AppStoreConnectApiError as exc:
            if not self._is_duplicate_locale_error(exc):
                raise
            print(
                f'  ℹ️ 版本本地化已存在，改为复用: '
                f'{locale_plan.locale}',
            )
            return self._refresh_localization(
                f'/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations',
                locale_plan.locale,
                localizations,
            )
        created = response['data']
        localizations[locale_plan.locale] = created
        print(f'  ✅ 已创建版本本地化: {locale_plan.locale}')
        return created

    def _update_app_info_localization(
        self,
        locale_plan: LocalePlan,
        localization: dict[str, Any] | None,
    ) -> None:
        attributes = self._build_app_info_attributes(locale_plan.metadata)
        # `name` 仅在首次创建语种时使用，已存在语种更新时跳过，
        # 避免触发 Apple 的跨账号重名校验。
        attributes.pop('name', None)
        if not attributes:
            print('  ℹ️ 未配置可更新的 App 信息字段，跳过 appInfoLocalizations')
            return
        if self._dry_run:
            print(
                f'  [DRY RUN] 将更新 App 信息字段: '
                f'{json.dumps(attributes, ensure_ascii=False)}',
            )
            return
        if not localization:
            raise ValueError('缺少 App Info Localization，无法执行更新。')
        payload = {
            'data': {
                'type': 'appInfoLocalizations',
                'id': localization['id'],
                'attributes': attributes,
            },
        }
        self._client.request_json(
            'PATCH',
            f'/v1/appInfoLocalizations/{localization["id"]}',
            payload=payload,
            expected_statuses=(200,),
        )
        print('  ✅ App 信息字段已更新')

    def _update_version_localization(
        self,
        locale_plan: LocalePlan,
        localization: dict[str, Any] | None,
    ) -> None:
        attributes = self._build_version_attributes(locale_plan.metadata)
        if not attributes:
            print('  ℹ️ 未配置版本说明字段，跳过 appStoreVersionLocalizations')
            return
        if self._dry_run:
            print(
                f'  [DRY RUN] 将更新版本文案: '
                f'{json.dumps(attributes, ensure_ascii=False)}',
            )
            return
        if not localization:
            raise ValueError('缺少版本本地化，无法执行更新。')
        payload = {
            'data': {
                'type': 'appStoreVersionLocalizations',
                'id': localization['id'],
                'attributes': attributes,
            },
        }
        self._client.request_json(
            'PATCH',
            f'/v1/appStoreVersionLocalizations/{localization["id"]}',
            payload=payload,
            expected_statuses=(200,),
        )
        print('  ✅ 推广文本/描述/新增内容/关键词已更新')

    def _sync_screenshots(
        self,
        locale_plan: LocalePlan,
        localization: dict[str, Any] | None,
    ) -> None:
        screenshot_plans = self._build_screenshot_plans(locale_plan)
        if not screenshot_plans:
            print('  ℹ️ 未找到截图目录，跳过截图上传')
            return
        self._validate_screenshot_plans(screenshot_plans)
        if self._dry_run:
            for screenshot_plan in screenshot_plans:
                filenames = ', '.join(
                    self._prepare_screenshot_for_upload(file_path)[0]
                    for file_path in screenshot_plan.files
                )
                print(
                    f'  [DRY RUN] 将上传 {screenshot_plan.display_type}: '
                    f'{filenames}',
                )
            return
        if not localization:
            raise ValueError('缺少版本本地化，无法上传截图。')
        planned_display_types = {
            screenshot_plan.display_type
            for screenshot_plan in screenshot_plans
        }
        self._cleanup_legacy_screenshot_sets(
            localization['id'],
            planned_display_types,
        )
        for screenshot_plan in screenshot_plans:
            screenshot_set = self._ensure_screenshot_set(
                localization['id'],
                screenshot_plan.display_type,
            )
            if screenshot_plan.clear_before_upload:
                self._clear_screenshot_set(screenshot_set['id'])
            for file_path in screenshot_plan.files:
                self._upload_single_screenshot(
                    screenshot_set_id=screenshot_set['id'],
                    file_path=file_path,
                )
            # 兜底检测：上传完成后验证截图数量是否一致
            self._verify_and_repair_screenshot_set(
                screenshot_set_id=screenshot_set['id'],
                screenshot_plan=screenshot_plan,
            )

    def _ensure_screenshot_set(
        self,
        localization_id: str,
        display_type: str,
    ) -> dict[str, Any]:
        screenshot_sets = self._client.list_all(
            f'/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets',
        )
        for item in screenshot_sets:
            current_display_type = item.get('attributes', {}).get(
                'screenshotDisplayType',
            )
            if current_display_type == display_type:
                return item
        payload = {
            'data': {
                'type': 'appScreenshotSets',
                'attributes': {
                    'screenshotDisplayType': display_type,
                },
                'relationships': {
                    'appStoreVersionLocalization': {
                        'data': {
                            'type': 'appStoreVersionLocalizations',
                            'id': localization_id,
                        },
                    },
                },
            },
        }
        response = self._client.request_json(
            'POST',
            '/v1/appScreenshotSets',
            payload=payload,
        )
        print(f'  ✅ 已创建截图展示位: {display_type}')
        return response['data']

    def _clear_screenshot_set(self, screenshot_set_id: str) -> None:
        screenshots = self._client.list_all(
            f'/v1/appScreenshotSets/{screenshot_set_id}/appScreenshots',
        )
        if not screenshots:
            return
        print(f'  🧹 清理旧截图 {len(screenshots)} 张')
        for item in screenshots:
            self._client.request_json(
                'DELETE',
                f'/v1/appScreenshots/{item["id"]}',
                expected_statuses=(204,),
            )

    def _verify_and_repair_screenshot_set(
        self,
        screenshot_set_id: str,
        screenshot_plan: ScreenshotSetPlan,
        retry_count: int = 0,
    ) -> None:
        """兜底检测：验证远程截图数量与本地上传数量是否一致，不一致则清除重传。"""
        remote_screenshots = self._client.list_all(
            f'/v1/appScreenshotSets/{screenshot_set_id}/appScreenshots',
        )
        # 统计状态为 COMPLETE 的截图（只有 COMPLETE 才是成功上传的）
        completed_count = sum(
            1
            for s in remote_screenshots
            if s.get('attributes', {})
            .get('assetDeliveryState', {})
            .get('state')
            == 'COMPLETE'
        )
        local_count = len(screenshot_plan.files)
        print(
            f'  🔍 [{screenshot_plan.display_type}] 远程已完成: {completed_count} 张, '
            f'本地上传: {local_count} 张',
        )
        if completed_count == local_count:
            return
        print(
            f'  ⚠️  截图数量不一致，正在修复（重试 {retry_count} 次）...',
        )
        if retry_count >= 2:
            print(
                f'  ❌  已达到最大重试次数 {retry_count}，跳过修复',
            )
            return
        # 清除并重新上传
        self._clear_screenshot_set(screenshot_set_id)
        for file_path in screenshot_plan.files:
            self._upload_single_screenshot(
                screenshot_set_id=screenshot_set_id,
                file_path=file_path,
            )
        # 递归验证下一次是否成功
        self._verify_and_repair_screenshot_set(
            screenshot_set_id=screenshot_set_id,
            screenshot_plan=screenshot_plan,
            retry_count=retry_count + 1,
        )

    def _cleanup_legacy_screenshot_sets(
        self,
        localization_id: str,
        planned_display_types: set[str],
    ) -> None:
        screenshot_sets = self._client.list_all(
            f'/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets',
        )
        for item in screenshot_sets:
            current_display_type = item.get('attributes', {}).get(
                'screenshotDisplayType',
            )
            if current_display_type in planned_display_types:
                continue
            self._client.request_json(
                'DELETE',
                f'/v1/appScreenshotSets/{item["id"]}',
                expected_statuses=(204,),
            )
            print(f'  🧹 已删除遗留截图展示位: {current_display_type}')

    def _upload_single_screenshot(
        self,
        *,
        screenshot_set_id: str,
        file_path: Path,
    ) -> None:
        upload_filename, file_bytes = self._prepare_screenshot_for_upload(
            file_path,
        )
        checksum = hashlib.md5(file_bytes).hexdigest()
        payload = {
            'data': {
                'type': 'appScreenshots',
                'attributes': {
                    'fileSize': len(file_bytes),
                    'fileName': upload_filename,
                },
                'relationships': {
                    'appScreenshotSet': {
                        'data': {
                            'type': 'appScreenshotSets',
                            'id': screenshot_set_id,
                        },
                    },
                },
            },
        }
        response = self._client.request_json(
            'POST',
            '/v1/appScreenshots',
            payload=payload,
        )
        screenshot = response['data']
        operations = screenshot.get('attributes', {}).get('uploadOperations', [])
        if not operations:
            raise AppStoreConnectApiError(
                f'{upload_filename} 未返回 uploadOperations，无法上传。',
            )
        for operation in operations:
            offset = int(operation.get('offset', 0))
            length = int(operation.get('length', 0))
            chunk = file_bytes[offset : offset + length]
            self._client.upload_bytes(
                method=operation['method'],
                url=operation['url'],
                data=chunk,
                request_headers=operation.get('requestHeaders', []),
            )
        commit_payload = {
            'data': {
                'type': 'appScreenshots',
                'id': screenshot['id'],
                'attributes': {
                    'uploaded': True,
                    'sourceFileChecksum': checksum,
                },
            },
        }
        self._client.request_json(
            'PATCH',
            f'/v1/appScreenshots/{screenshot["id"]}',
            payload=commit_payload,
            expected_statuses=(200,),
        )
        self._wait_for_screenshot_complete(screenshot['id'], upload_filename)
        print(f'  ✅ 截图上传完成: {upload_filename}')

    def _prepare_screenshot_for_upload(
        self,
        file_path: Path,
    ) -> tuple[str, bytes]:
        prepared_screenshot = self._prepared_screenshots.get(file_path)
        if prepared_screenshot:
            return prepared_screenshot
        if not self._image_has_alpha(file_path):
            return file_path.name, file_path.read_bytes()

        source_size = self._read_image_size(file_path)
        with tempfile.TemporaryDirectory(prefix='app-store-screenshot-') as directory:
            converted_path = Path(directory) / f'{file_path.stem}.jpg'
            try:
                result = subprocess.run(
                    [
                        '/usr/bin/sips',
                        '-s',
                        'format',
                        'jpeg',
                        '-s',
                        'formatOptions',
                        'best',
                        str(file_path),
                        '--out',
                        str(converted_path),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=60,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise ValueError(
                    f'自动移除截图 alpha 失败: {file_path}: {exc}',
                ) from exc
            if result.returncode != 0 or not converted_path.is_file():
                error_message = (
                    result.stderr.strip()
                    or result.stdout.strip()
                    or 'sips 未生成转换文件'
                )
                raise ValueError(
                    f'自动移除截图 alpha 失败: {file_path}: {error_message}',
                )
            if self._read_image_size(converted_path) != source_size:
                raise ValueError(f'自动移除 alpha 后截图尺寸发生变化: {file_path}')
            converted_bytes = converted_path.read_bytes()

        print(
            f'  ♻️ 已生成无 alpha 上传副本: '
            f'{file_path.name} -> {converted_path.name}',
        )
        prepared_screenshot = converted_path.name, converted_bytes
        self._prepared_screenshots[file_path] = prepared_screenshot
        return prepared_screenshot

    def _wait_for_screenshot_complete(
        self,
        screenshot_id: str,
        filename: str,
    ) -> None:
        start_time = time.time()
        while True:
            response = self._client.request_json(
                'GET',
                f'/v1/appScreenshots/{screenshot_id}',
            )
            screenshot = response['data']
            delivery_state = screenshot.get('attributes', {}).get(
                'assetDeliveryState',
                {},
            )
            state = delivery_state.get('state', '')
            if state == 'COMPLETE':
                return
            if state == 'FAILED':
                errors_data = delivery_state.get('errors', [])
                errors_text = json.dumps(errors_data, ensure_ascii=False)
                raise AppStoreConnectApiError(
                    f'截图处理失败 {filename}: {errors_text}',
                )
            elapsed = time.time() - start_time
            if elapsed >= self._upload_config.poll_timeout_seconds:
                raise TimeoutError(f'等待截图处理超时: {filename}')
            time.sleep(self._upload_config.poll_interval_seconds)

    def _build_app_info_attributes(
        self,
        metadata: dict[str, Any],
    ) -> dict[str, Any]:
        attributes = {
            'name': metadata.get('name'),
            'subtitle': metadata.get('subtitle'),
            'privacyPolicyUrl': metadata.get('privacyPolicyUrl'),
        }
        return self._strip_empty_values(attributes)

    def _build_version_attributes(
        self,
        metadata: dict[str, Any],
    ) -> dict[str, Any]:
        keywords = metadata.get('keywords')
        if isinstance(keywords, list):
            keywords = ','.join(item.strip() for item in keywords if item.strip())
        attributes = {
            'description': metadata.get('description'),
            'keywords': keywords,
            'marketingUrl': metadata.get('marketingUrl'),
            'promotionalText': metadata.get('promotionalText'),
            'supportUrl': metadata.get('supportUrl'),
            'whatsNew': metadata.get('whatsNew'),
        }
        return self._strip_empty_values(attributes)

    def _build_screenshot_plans(
        self,
        locale_plan: LocalePlan,
    ) -> list[ScreenshotSetPlan]:
        # A missing or invalid configured root is an explicit opt-out. Do not
        # fall back to per-locale material screenshots, especially when the
        # clear-existing-screenshots option is enabled.
        screenshots_root = self._upload_config.screenshots_root
        if not screenshots_root or not screenshots_root.is_dir():
            return []
        metadata = locale_plan.metadata
        configured_sets = metadata.get('screenshotSets')
        if isinstance(configured_sets, list) and configured_sets:
            return self._build_configured_screenshot_plans(
                locale_plan,
                configured_sets,
            )
        screenshot_root = locale_plan.directory / 'screenshots'
        if screenshot_root.is_dir():
            sub_dirs = [path for path in sorted(screenshot_root.iterdir()) if path.is_dir()]
            if sub_dirs:
                plans: list[ScreenshotSetPlan] = []
                for path in sub_dirs:
                    files = self._read_sorted_images(path)
                    if not files:
                        continue
                    plans.append(
                        ScreenshotSetPlan(
                            display_type=path.name,
                            directory=path,
                            files=files,
                            clear_before_upload=self._upload_config.clear_existing_screenshots,
                        ),
                    )
                return plans
            if self._upload_config.default_screenshot_display_type:
                files = self._read_sorted_images(screenshot_root)
                if files:
                    return [
                        ScreenshotSetPlan(
                            display_type=self._upload_config.default_screenshot_display_type,
                            directory=screenshot_root,
                            files=files,
                            clear_before_upload=self._upload_config.clear_existing_screenshots,
                        ),
                    ]
        mapped_plan = self._build_mapped_screenshot_plan(locale_plan.locale)
        if mapped_plan:
            return [mapped_plan]
        return []

    def _build_mapped_screenshot_plan(
        self,
        locale: str,
    ) -> ScreenshotSetPlan | None:
        screenshots_root = self._upload_config.screenshots_root
        if not screenshots_root or not self._upload_config.default_screenshot_display_type:
            return None
        screenshot_directory = self._find_screenshot_directory(locale)
        if screenshot_directory is None:
            return None
        files = self._read_sorted_images(screenshot_directory)
        if not files:
            return None
        return ScreenshotSetPlan(
            display_type=self._upload_config.default_screenshot_display_type,
            directory=screenshot_directory,
            files=files,
            clear_before_upload=self._upload_config.clear_existing_screenshots,
        )

    def _find_screenshot_directory(self, locale: str) -> Path | None:
        screenshots_root = self._upload_config.screenshots_root
        if not screenshots_root:
            return None
        for directory_name in self._build_screenshot_directory_names(locale):
            screenshot_directory = screenshots_root / directory_name
            if screenshot_directory.is_dir():
                return screenshot_directory
        return None

    def _build_screenshot_directory_names(self, locale: str) -> list[str]:
        labels = [
            locale,
            self._upload_config.locale_screenshot_dir_map.get(locale, ''),
            LOCALE_LABEL_MAP.get(locale, ''),
            *sorted(LOCALE_SCREENSHOT_DIR_ALIASES.get(locale, set())),
        ]
        directory_names: list[str] = []
        seen: set[str] = set()
        for label in labels:
            stripped_label = label.strip()
            if not stripped_label:
                continue
            for directory_name in (
                stripped_label,
                f'ios-{stripped_label}',
                f'iOS-{stripped_label}',
                f'IOS-{stripped_label}',
            ):
                if directory_name in seen:
                    continue
                seen.add(directory_name)
                directory_names.append(directory_name)
        return directory_names

    def _build_configured_screenshot_plans(
        self,
        locale_plan: LocalePlan,
        configured_sets: list[dict[str, Any]],
    ) -> list[ScreenshotSetPlan]:
        plans: list[ScreenshotSetPlan] = []
        for item in configured_sets:
            display_type = str(item.get('displayType') or '').strip()
            if not display_type:
                raise ValueError(
                    f'{locale_plan.locale} 的 screenshotSets 缺少 displayType。',
                )
            directory_value = str(item.get('directory') or '').strip()
            if not directory_value:
                directory = locale_plan.directory / 'screenshots' / display_type
            else:
                directory = locale_plan.directory / directory_value
            files = self._read_sorted_images(directory)
            if not files:
                print(f'  ⚠️ 跳过 {display_type}: 目录没有截图 {directory}')
                continue
            clear_before_upload = bool(
                item.get(
                    'clearBeforeUpload',
                    self._upload_config.clear_existing_screenshots,
                ),
            )
            plans.append(
                ScreenshotSetPlan(
                    display_type=display_type,
                    directory=directory,
                    files=files,
                    clear_before_upload=clear_before_upload,
                ),
            )
        return plans

    def _read_sorted_images(self, directory: Path) -> list[Path]:
        if not directory.is_dir():
            return []
        files = [
            path
            for path in sorted(directory.iterdir(), key=self._build_natural_sort_key)
            if path.is_file()
            and not path.name.startswith('.')
            and path.suffix.lower() in IMAGE_SUFFIXES
        ]
        if len(files) > 10:
            raise ValueError(f'{directory} 的截图数量超过 10 张。')
        return files

    def _validate_screenshot_plans(
        self,
        screenshot_plans: list[ScreenshotSetPlan],
    ) -> None:
        for screenshot_plan in screenshot_plans:
            allowed_sizes = SCREENSHOT_SIZE_ALLOWLIST.get(
                screenshot_plan.display_type,
            )
            if allowed_sizes:
                for file_path in screenshot_plan.files:
                    image_size = self._read_image_size(file_path)
                    if image_size not in allowed_sizes:
                        expected = ' 或 '.join(
                            f'{width}x{height}'
                            for width, height in sorted(allowed_sizes)
                        )
                        raise ValueError(
                            f'{file_path} 尺寸为 '
                            f'{image_size[0]}x{image_size[1]}，'
                            f'{screenshot_plan.display_type} 需要 {expected}。',
                        )
            alpha_files = [
                file_path
                for file_path in screenshot_plan.files
                if self._image_has_alpha(file_path)
            ]
            if alpha_files:
                print(
                    '  ℹ️ 以下截图含 alpha，上传时将自动转换为无 alpha JPEG: '
                    + ', '.join(file_path.name for file_path in alpha_files),
                )
                for file_path in alpha_files:
                    self._prepare_screenshot_for_upload(file_path)

    def _read_image_size(self, path: Path) -> tuple[int, int]:
        suffix = path.suffix.lower()
        data = path.read_bytes()
        if suffix == '.png':
            if len(data) < 24 or data[:8] != b'\x89PNG\r\n\x1a\n':
                raise ValueError(f'PNG 文件格式无效: {path}')
            return struct.unpack('>II', data[16:24])
        if suffix in {'.jpg', '.jpeg'}:
            return self._read_jpeg_size(path, data)
        raise ValueError(f'不支持的截图格式: {path}')

    def _read_jpeg_size(self, path: Path, data: bytes) -> tuple[int, int]:
        if len(data) < 4 or data[:2] != b'\xff\xd8':
            raise ValueError(f'JPEG 文件格式无效: {path}')
        offset = 2
        while offset + 9 <= len(data):
            if data[offset] != 0xFF:
                offset += 1
                continue
            marker = data[offset + 1]
            offset += 2
            while marker == 0xFF and offset < len(data):
                marker = data[offset]
                offset += 1
            if marker in {0xD8, 0xD9}:
                continue
            if offset + 2 > len(data):
                break
            segment_length = int.from_bytes(data[offset:offset + 2], 'big')
            if segment_length < 2 or offset + segment_length > len(data):
                break
            if marker in {
                0xC0,
                0xC1,
                0xC2,
                0xC3,
                0xC5,
                0xC6,
                0xC7,
                0xC9,
                0xCA,
                0xCB,
                0xCD,
                0xCE,
                0xCF,
            }:
                height = int.from_bytes(data[offset + 3:offset + 5], 'big')
                width = int.from_bytes(data[offset + 5:offset + 7], 'big')
                return width, height
            offset += segment_length
        raise ValueError(f'无法读取 JPEG 尺寸: {path}')

    def _image_has_alpha(self, path: Path) -> bool:
        suffix = path.suffix.lower()
        if suffix not in {'.png'}:
            return False
        data = path.read_bytes()
        if len(data) < 33 or data[:8] != b'\x89PNG\r\n\x1a\n':
            raise ValueError(f'PNG 文件格式无效: {path}')
        color_type = data[25]
        if color_type in {4, 6}:
            return True
        offset = 8
        while offset + 12 <= len(data):
            chunk_length = int.from_bytes(data[offset:offset + 4], 'big')
            chunk_type = data[offset + 4:offset + 8]
            if chunk_type == b'tRNS':
                return True
            offset += 12 + chunk_length
        return False

    def _build_natural_sort_key(self, path: Path) -> list[Any]:
        parts = re.split(r'(\d+)', path.name.lower())
        sort_key: list[Any] = []
        for part in parts:
            if part.isdigit():
                sort_key.append(int(part))
            else:
                sort_key.append(part)
        return sort_key

    def _read_json_file(self, path: Path) -> dict[str, Any]:
        try:
            return json.loads(path.read_text(encoding='utf-8'))
        except json.JSONDecodeError as exc:
            raise ValueError(f'JSON 解析失败 {path}: {exc}') from exc

    def _strip_empty_values(self, payload: dict[str, Any]) -> dict[str, Any]:
        return {
            key: value
            for key, value in payload.items()
            if value is not None and value != ''
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='通过官方 App Store Connect API 上传多语种元数据与截图。',
    )
    parser.add_argument(
        '--config',
        default=str(DEFAULT_CONFIG_PATH),
        help='配置文件路径；DevKit 运行时会显式传入独立配置。',
    )
    parser.add_argument(
        '--locale',
        action='append',
        default=[],
        help='只处理指定语种，可重复传入，例如 --locale en-US --locale ja',
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='只解析配置与语种目录，不真正写入 App Store Connect。',
    )
    parser.add_argument(
        '--skip-metadata',
        action='store_true',
        help='跳过元数据上传，只处理截图。',
    )
    parser.add_argument(
        '--skip-screenshots',
        action='store_true',
        help='跳过截图上传，只处理元数据。',
    )
    parser.add_argument(
        '--screenshots-root',
        default='',
        help=(
            '覆盖配置里的 upload.screenshots_root，例如 '
            '/Users/kk/Downloads/ios。'
        ),
    )
    return parser.parse_args()


def load_config(
    config_path: Path,
) -> tuple[AuthConfig, AppConfig, UploadConfig]:
    data = json.loads(config_path.read_text(encoding='utf-8'))
    auth_data = data.get('auth', {})
    app_data = data.get('app', {})
    upload_data = data.get('upload', {})
    private_key_path: Path | None = None
    private_key_value = str(auth_data.get('private_key_path') or '').strip()
    if private_key_value:
        private_key_path = Path(private_key_value).expanduser()
        if not private_key_path.is_absolute():
            private_key_path = (config_path.parent / private_key_path).resolve()
    localizations_root = Path(upload_data['localizations_root']).expanduser()
    if not localizations_root.is_absolute():
        localizations_root = (config_path.parent / localizations_root).resolve()
    screenshots_root: Path | None = None
    if upload_data.get('screenshots_root'):
        screenshots_root = Path(upload_data['screenshots_root']).expanduser()
        if not screenshots_root.is_absolute():
            screenshots_root = (config_path.parent / screenshots_root).resolve()
    auth_config = AuthConfig(
        issuer_id=str(auth_data.get('issuer_id') or '').strip() or None,
        key_id=str(auth_data.get('key_id') or '').strip() or None,
        private_key_path=private_key_path,
    )
    app_config = AppConfig(
        app_id=str(app_data['app_id']).strip(),
        bundle_id=str(app_data['bundle_id']).strip()
        if app_data.get('bundle_id')
        else None,
        platform=str(app_data.get('platform') or DEFAULT_PLATFORM).strip().upper(),
        version_string=str(app_data['version_string']).strip()
        if app_data.get('version_string')
        else None,
    )
    upload_config = UploadConfig(
        localizations_root=localizations_root,
        screenshots_root=screenshots_root,
        locale_screenshot_dir_map={
            str(key): str(value)
            for key, value in upload_data.get(
                'locale_screenshot_dir_map',
                {},
            ).items()
        },
        disabled_locales={
            str(item).strip()
            for item in upload_data.get('disabled_locales', [])
            if str(item).strip()
        },
        default_screenshot_display_type=str(
            upload_data['default_screenshot_display_type'],
        ).strip()
        if upload_data.get('default_screenshot_display_type')
        else None,
        allow_create_localizations=bool(
            upload_data.get('allow_create_localizations', True),
        ),
        clear_existing_screenshots=bool(
            upload_data.get('clear_existing_screenshots', True),
        ),
        continue_on_locale_error=bool(
            upload_data.get('continue_on_locale_error', False),
        ),
        poll_interval_seconds=int(
            upload_data.get(
                'poll_interval_seconds',
                DEFAULT_POLL_INTERVAL_SECONDS,
            ),
        ),
        poll_timeout_seconds=int(
            upload_data.get(
                'poll_timeout_seconds',
                DEFAULT_POLL_TIMEOUT_SECONDS,
            ),
        ),
    )
    return auth_config, app_config, upload_config


def validate_config(
    auth_config: AuthConfig,
    app_config: AppConfig,
    upload_config: UploadConfig,
) -> None:
    if not auth_config.issuer_id:
        raise ValueError('auth.issuer_id 不能为空。')
    if not auth_config.key_id:
        raise ValueError('auth.key_id 不能为空。')
    if auth_config.private_key_path is None:
        raise ValueError('auth.private_key_path 不能为空。')
    if (
        auth_config.issuer_id in PLACEHOLDER_AUTH_VALUES
        or auth_config.key_id in PLACEHOLDER_AUTH_VALUES
        or str(auth_config.private_key_path) in {
            str(Path(value).expanduser())
            for value in PLACEHOLDER_AUTH_VALUES
        }
    ):
        raise ValueError(
            'App Store Connect auth 仍是示例占位值，请填写真实的 '
            'auth.issuer_id、auth.key_id、auth.private_key_path。',
        )
    if not app_config.app_id:
        raise ValueError('app.app_id 不能为空。')
    if upload_config.poll_interval_seconds <= 0:
        raise ValueError('upload.poll_interval_seconds 必须大于 0。')
    if upload_config.poll_timeout_seconds <= 0:
        raise ValueError('upload.poll_timeout_seconds 必须大于 0。')


def default_selected_locales(config_path: Path) -> set[str]:
    """Use import.locale_map as the default upload allowlist when present."""
    data = json.loads(config_path.read_text(encoding='utf-8'))
    locale_map = (data.get('import') or {}).get('locale_map') or {}
    return {
        str(locale).strip()
        for locale in locale_map.values()
        if str(locale).strip()
    }


def main() -> int:
    args = parse_args()
    config_path = Path(args.config).expanduser().resolve()
    if config_path == EXAMPLE_CONFIG_PATH.resolve():
        local_config_path = config_path.with_name('app_store_connect.local.json')
        raise FileNotFoundError(
            '上传 App Store Connect 需要本机配置文件: '
            f'{local_config_path}\n'
            '请先复制示例配置并填入 auth/app 信息:\n'
            f'cp {config_path} {local_config_path}',
        )
    if not config_path.is_file():
        raise FileNotFoundError(f'找不到配置文件: {config_path}')
    auth_config, app_config, upload_config = load_config(config_path)
    if args.screenshots_root:
        screenshots_root = Path(args.screenshots_root).expanduser().resolve()
        upload_config = replace(upload_config, screenshots_root=screenshots_root)
    validate_config(auth_config, app_config, upload_config)
    selected_locales = set(args.locale) or default_selected_locales(config_path)
    client = AppStoreConnectClient(auth_config)
    uploader = AppStoreMetadataUploader(
        client,
        app_config,
        upload_config,
        dry_run=bool(args.dry_run),
        selected_locales=selected_locales,
        skip_metadata=bool(args.skip_metadata),
        skip_screenshots=bool(args.skip_screenshots),
    )
    uploader.run()
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\n⚠️ 用户主动中断执行')
        sys.exit(130)
    except Exception as exc:  # pylint: disable=broad-except
        print(f'❌ 执行失败: {exc}')
        sys.exit(1)
