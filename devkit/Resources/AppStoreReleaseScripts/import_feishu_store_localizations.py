#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从飞书 Wiki 表格导入 App Store 多语种 metadata.json。

表格模板：
- 第一行是字段名。
- 每个语种一行，通过“语言”列映射到 App Store locale。
- DevKit 会通过 `--config` 传入独立配置，物料默认写入配置文件旁的
  `localizations/<locale>/metadata.json`。

示例：
python3 import_feishu_store_localizations.py --config app_store_connect.json --dry-run
python3 import_feishu_store_localizations.py --config app_store_connect.json --locale en-US
"""

from __future__ import annotations

import argparse
import csv
import json
import subprocess
import sys
import time
from dataclasses import dataclass
from io import StringIO
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
LOCAL_CONFIG_PATH = SCRIPT_DIR / 'config' / 'app_store_connect.local.json'
EXAMPLE_CONFIG_PATH = SCRIPT_DIR / 'config' / 'app_store_connect.example.json'
DEFAULT_CONFIG_PATH = (
    LOCAL_CONFIG_PATH
    if LOCAL_CONFIG_PATH.is_file()
    else EXAMPLE_CONFIG_PATH
)
DEFAULT_FEISHU_SHEET_URL = (
    'https://example.feishu.cn/wiki/example-sheet'
)
DEFAULT_SHEET_RANGE = 'A1:U200'
DEFAULT_LARK_IDENTITY = 'auto'
DEFAULT_LOCALE_MAP = {
    '英语': 'en-US',
    '英文': 'en-US',
    '印尼语': 'id',
    '印度尼西亚语': 'id',
    '菲律宾语': 'fil-PH',
}
FIELD_MAP = {
    'App名': 'name',
    '更新描述': 'whatsNew',
    '副标题': 'subtitle',
    '推广文本': 'promotionalText',
    '描述': 'description',
    '关键词': 'keywords',
    '技术支持网址 (URL)': 'supportUrl',
    '营销网址 (URL)': 'marketingUrl',
}
REQUIRED_COLUMNS = {'语言'}
RETRYABLE_ERROR_MARKERS = (
    '"subtype": "timeout"',
    'TLS handshake timeout',
    'Client.Timeout',
    'connection reset by peer',
    'i/o timeout',
    'net/http: timeout',
)


@dataclass(frozen=True)
class ImportConfig:
    localizations_root: Path
    feishu_sheet_url: str
    disabled_locales: set[str]
    locale_map: dict[str, str]
    default_name: str | None
    lark_identity: str


def is_retryable_lark_error(output: str) -> bool:
    return any(marker in output for marker in RETRYABLE_ERROR_MARKERS)


def run_lark_cli(args: list[str], max_attempts: int = 3) -> dict[str, Any]:
    stdout = ''
    for attempt in range(1, max_attempts + 1):
        result = subprocess.run(
            ['lark-cli', *args],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            stdout = result.stdout
            break

        output = f'{result.stdout}\n{result.stderr}'
        if attempt >= max_attempts or not is_retryable_lark_error(output):
            raise subprocess.CalledProcessError(
                result.returncode,
                ['lark-cli', *args],
                output=result.stdout,
                stderr=result.stderr,
            )

        delay_seconds = 2 ** (attempt - 1)
        print(
            f'lark-cli 网络超时，{delay_seconds}s 后重试 '
            f'({attempt + 1}/{max_attempts})...',
            file=sys.stderr,
        )
        time.sleep(delay_seconds)
    else:
        raise RuntimeError('lark-cli 未执行')

    json_start = stdout.find('{')
    if json_start < 0:
        raise ValueError(f'lark-cli 未返回 JSON: {stdout}')
    return json.loads(stdout[json_start:])


def sheet_id_from_url(url_or_token: str) -> str | None:
    parsed = urlparse(url_or_token)
    values = parse_qs(parsed.query).get('sheet')
    if values:
        sheet_id = values[0].strip()
        if sheet_id:
            return sheet_id
    return None


def resolve_wiki_sheet(url_or_token: str, identity: str) -> tuple[str, str]:
    requested_sheet_id = sheet_id_from_url(url_or_token)
    node_result = run_lark_cli([
        'wiki',
        '+node-get',
        '--as',
        identity,
        '--node-token',
        url_or_token,
        '--format',
        'json',
    ])
    node = node_result.get('data') or {}
    obj_type = node.get('obj_type')
    if obj_type != 'sheet':
        raise ValueError(f'飞书节点不是表格: {obj_type}')

    spreadsheet_token = str(node.get('obj_token') or '').strip()
    if not spreadsheet_token:
        raise ValueError('飞书节点缺少 obj_token')

    workbook_result = run_lark_cli([
        'sheets',
        '+workbook-info',
        '--as',
        identity,
        '--spreadsheet-token',
        spreadsheet_token,
        '--format',
        'json',
    ])
    sheets = (workbook_result.get('data') or {}).get('sheets') or []
    if not sheets:
        raise ValueError('飞书表格没有工作表')

    if requested_sheet_id:
        sheet_ids = {
            str(sheet.get('sheet_id') or '').strip()
            for sheet in sheets
            if str(sheet.get('sheet_id') or '').strip()
        }
        if requested_sheet_id not in sheet_ids:
            available = ', '.join(sorted(sheet_ids))
            raise ValueError(
                f'URL 指定的 sheet 不存在: {requested_sheet_id}'
                f'；可用 sheet_id: {available}',
            )
        return spreadsheet_token, requested_sheet_id

    sheet_id = str(sheets[0].get('sheet_id') or '').strip()
    if not sheet_id:
        raise ValueError('飞书工作表缺少 sheet_id')
    return spreadsheet_token, sheet_id


def spreadsheet_column_name(index: int) -> str:
    name = ''
    value = index + 1
    while value > 0:
        value, remainder = divmod(value - 1, 26)
        name = chr(ord('A') + remainder) + name
    return name


def parse_csv_rows(data: dict[str, Any]) -> list[dict[str, Any]]:
    rows = data.get('rows')
    if isinstance(rows, list):
        return rows

    annotated_csv = data.get('annotated_csv')
    if not isinstance(annotated_csv, str):
        raise ValueError('lark-cli +csv-get 未返回 rows 或 annotated_csv')

    col_indices = data.get('col_indices') or []
    if not col_indices:
        col_count = int(data.get('col_count') or 0)
        col_indices = [spreadsheet_column_name(index) for index in range(col_count)]

    parsed_rows: list[dict[str, Any]] = []
    for row_values in csv.reader(StringIO(annotated_csv)):
        values = {
            str(column): value
            for column, value in zip(col_indices, row_values)
        }
        parsed_rows.append({'values': values})
    return parsed_rows


def fetch_sheet_rows(url_or_token: str, sheet_range: str, identity: str) -> list[dict[str, Any]]:
    spreadsheet_token, sheet_id = resolve_wiki_sheet(url_or_token, identity)
    result = run_lark_cli([
        'sheets',
        '+csv-get',
        '--as',
        identity,
        '--spreadsheet-token',
        spreadsheet_token,
        '--sheet-id',
        sheet_id,
        '--range',
        sheet_range,
        '--include-row-prefix=false',
        '--format',
        'json',
    ])
    data = result.get('data') or {}
    if data.get('has_more'):
        raise ValueError(
            f'读取范围 {sheet_range} 被截断，请扩大 --range 后重试',
        )
    return parse_csv_rows(data)


def normalize_header(value: str) -> str:
    return ' '.join(value.strip().split())


def clean_cell(value: Any) -> str:
    if value is None:
        return ''
    text = str(value).replace('\r\n', '\n').replace('\r', '\n')
    lines = [line.rstrip() for line in text.split('\n')]
    return '\n'.join(lines).strip()


def split_keywords(value: str) -> list[str]:
    parts: list[str] = []
    for chunk in value.replace('\n', ',').split(','):
        keyword = chunk.strip()
        if keyword:
            parts.append(keyword)
    return parts


def find_header_row(rows: list[dict[str, Any]]) -> tuple[dict[str, str], int]:
    for row_index, row in enumerate(rows):
        values = {
            column: normalize_header(clean_cell(value))
            for column, value in (row.get('values') or {}).items()
        }
        headers = {header: column for column, header in values.items() if header}
        if REQUIRED_COLUMNS.issubset(headers):
            return headers, row_index
    raise ValueError(f'飞书表格缺少表头列: {", ".join(sorted(REQUIRED_COLUMNS))}')


def parse_store_metadata(
    rows: list[dict[str, Any]],
    locale_map: dict[str, str],
    default_name: str | None,
) -> dict[str, dict[str, Any]]:
    headers, header_row_index = find_header_row(rows)
    language_column = headers['语言']
    field_columns = {
        field_name: headers[header]
        for header, field_name in FIELD_MAP.items()
        if header in headers
    }

    payload: dict[str, dict[str, Any]] = {}
    for row in rows[header_row_index + 1:]:
        values = row.get('values') or {}
        language = clean_cell(values.get(language_column))
        if not language:
            continue

        locale = locale_map.get(language)
        if not locale:
            print(f'warning: 跳过未映射语言 {language}', file=sys.stderr)
            continue

        metadata = payload.setdefault(locale, {'locale': locale})
        for field_name, column in field_columns.items():
            value = clean_cell(values.get(column))
            if not value:
                continue
            if field_name == 'keywords':
                metadata[field_name] = split_keywords(value)
            else:
                metadata[field_name] = value

        if default_name and not metadata.get('name'):
            metadata['name'] = default_name

    return payload


def merge_metadata(
    existing_data: dict[str, Any],
    imported_data: dict[str, Any],
) -> dict[str, Any]:
    merged = dict(existing_data)
    merged['locale'] = imported_data['locale']
    for key, value in imported_data.items():
        if key == 'locale':
            continue
        if value:
            merged[key] = value
    return merged


def changed_fields(
    before: dict[str, Any],
    after: dict[str, Any],
) -> list[str]:
    keys = sorted(set(before) | set(after))
    return [key for key in keys if before.get(key) != after.get(key)]


def write_metadata_files(
    payload: dict[str, dict[str, Any]],
    root: Path,
    disabled_locales: set[str],
    selected_locales: set[str],
    dry_run: bool,
) -> None:
    target_locales = sorted(
        locale
        for locale in payload
        if locale not in disabled_locales
        and (not selected_locales or locale in selected_locales)
    )
    if not target_locales:
        raise ValueError('没有可导入的语种')

    for locale in target_locales:
        locale_dir = root / locale
        metadata_path = locale_dir / 'metadata.json'
        before: dict[str, Any] = {}
        if metadata_path.is_file():
            before = json.loads(metadata_path.read_text(encoding='utf-8'))

        after = merge_metadata(before, payload[locale])
        changes = changed_fields(before, after)

        if dry_run:
            if changes:
                print(f'[{locale}] 将更新字段: {", ".join(changes)}')
            else:
                print(f'[{locale}] 无变化')
            continue

        if not changes:
            print(f'跳过 {metadata_path}: 无变化')
            continue

        locale_dir.mkdir(parents=True, exist_ok=True)
        metadata_path.write_text(
            json.dumps(after, ensure_ascii=False, indent=2) + '\n',
            encoding='utf-8',
        )
        print(f'已更新 {metadata_path} ({", ".join(changes)})')


def resolve_path(base: Path, raw_path: str) -> Path:
    path = Path(raw_path).expanduser()
    if path.is_absolute():
        return path
    return (base / path).resolve()


def load_config(config_path: Path) -> ImportConfig:
    data = json.loads(config_path.read_text(encoding='utf-8'))
    app_data = data.get('app') or {}
    import_data = data.get('import') or data.get('upload') or {}

    raw_root = str(import_data.get('localizations_root') or '../localizations')
    localizations_root = resolve_path(config_path.parent, raw_root)

    raw_url = str(
        import_data.get('feishu_sheet_url')
        or import_data.get('doc')
        or DEFAULT_FEISHU_SHEET_URL,
    ).strip()
    if not raw_url:
        raise ValueError('配置缺少 import.feishu_sheet_url')

    disabled_locales = {
        str(item).strip()
        for item in import_data.get('disabled_locales', [])
        if str(item).strip()
    }
    configured_locale_map = import_data.get('locale_map')
    if configured_locale_map:
        locale_map = {
            str(label).strip(): str(locale).strip()
            for label, locale in configured_locale_map.items()
            if str(label).strip() and str(locale).strip()
        }
    else:
        locale_map = dict(DEFAULT_LOCALE_MAP)
    default_name = str(app_data.get('default_name') or '').strip() or None
    lark_identity = str(import_data.get('lark_identity') or DEFAULT_LARK_IDENTITY).strip()
    if lark_identity not in {'auto', 'user', 'bot'}:
        raise ValueError('import.lark_identity 只能是 auto、user 或 bot')

    return ImportConfig(
        localizations_root=localizations_root,
        feishu_sheet_url=raw_url,
        disabled_locales=disabled_locales,
        locale_map=locale_map,
        default_name=default_name,
        lark_identity=lark_identity,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='从飞书 Wiki 表格更新 App Store metadata.json。',
    )
    parser.add_argument(
        '--config',
        type=Path,
        default=DEFAULT_CONFIG_PATH,
        help='配置文件路径',
    )
    parser.add_argument(
        '--doc',
        help='飞书 Wiki 表格 URL 或 token；默认读取配置 import.feishu_sheet_url',
    )
    parser.add_argument(
        '--range',
        default=DEFAULT_SHEET_RANGE,
        help='读取的 A1 范围，默认 A1:U200',
    )
    parser.add_argument(
        '--output-dir',
        type=Path,
        help='metadata.json 输出根目录；默认读取配置 import.localizations_root',
    )
    parser.add_argument(
        '--locale',
        action='append',
        default=[],
        help='只导入指定 locale，可重复传入',
    )
    parser.add_argument(
        '--as',
        dest='lark_identity',
        choices=['auto', 'user', 'bot'],
        help='lark-cli 身份，默认读取配置 import.lark_identity 或 auto',
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='只打印将更新的字段，不写入文件',
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_path = args.config.expanduser().resolve()
    config = load_config(config_path)
    feishu_sheet_url = args.doc or config.feishu_sheet_url
    output_dir = (
        args.output_dir.expanduser().resolve()
        if args.output_dir
        else config.localizations_root
    )
    lark_identity = args.lark_identity or config.lark_identity

    print(f'读取飞书表格: {feishu_sheet_url}')
    rows = fetch_sheet_rows(feishu_sheet_url, args.range, lark_identity)
    payload = parse_store_metadata(rows, config.locale_map, config.default_name)
    print(f'解析到 {len(payload)} 个语种，输出目录: {output_dir}')

    write_metadata_files(
        payload=payload,
        root=output_dir,
        disabled_locales=config.disabled_locales,
        selected_locales=set(args.locale),
        dry_run=bool(args.dry_run),
    )
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\n用户中断执行', file=sys.stderr)
        sys.exit(130)
    except subprocess.CalledProcessError as exc:
        print(f'lark-cli 执行失败: {exc.stderr or exc.stdout}', file=sys.stderr)
        sys.exit(exc.returncode or 1)
    except Exception as exc:
        print(f'执行失败: {exc}', file=sys.stderr)
        sys.exit(1)
