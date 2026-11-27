#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
按文档规则，从飞书链接指定的子表导入 App Store 多语种 metadata.json。
文档映射保存在 --config 旁的 feishu-profiles/<文档标识>.json，同名本地规则优先于内置规则。

示例：
python3 import_feishu_store_localizations.py --config app_store_connect.json --dry-run
python3 import_feishu_store_localizations.py --config app_store_connect.json --locale en-US
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from io import StringIO
from itertools import zip_longest
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
LOCAL_CONFIG_PATH = SCRIPT_DIR / 'config' / 'app_store_connect.local.json'
EXAMPLE_CONFIG_PATH = SCRIPT_DIR / 'app_store_connect.example.json'
DEFAULT_CONFIG_PATH = (
    LOCAL_CONFIG_PATH
    if LOCAL_CONFIG_PATH.is_file()
    else EXAMPLE_CONFIG_PATH
)
DEFAULT_LARK_IDENTITY = 'auto'
DEFAULT_SHEET_RANGE = 'A1:U200'
METADATA_FIELDS = {
    'name', 'whatsNew', 'subtitle', 'promotionalText', 'description',
    'keywords', 'supportUrl', 'marketingUrl', 'privacyPolicyUrl',
}
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


@dataclass(frozen=True)
class DocumentProfile:
    language_header: str
    fields: dict[str, str]
    locale_map: dict[str, str]
    layout: str
    sheet_range: str


def document_target(url: str) -> tuple[str, str]:
    parsed = urlparse(url)
    document = re.fullmatch(r'/(?:wiki|sheets|spreadsheets)/([A-Za-z0-9_-]+)/?', parsed.path)
    if parsed.scheme != 'https' or not parsed.hostname or not document:
        raise ValueError('请粘贴飞书 Wiki 或电子表格的完整 HTTPS 链接')
    sheet_ids = parse_qs(parsed.query, keep_blank_values=True).get('sheet', [])
    if len(sheet_ids) != 1 or not re.fullmatch(r'[A-Za-z0-9_-]+', sheet_ids[0]):
        raise ValueError('请打开发版子表并复制带 ?sheet=子表标识 的链接')
    return document[1], sheet_ids[0]


def string_map(value: Any, key: str) -> dict[str, str]:
    if not isinstance(value, dict) or not value:
        raise ValueError(f'{key} 需要至少一组映射')
    result = {}
    for label, target in value.items():
        header = normalize_header(label)
        if not header or not isinstance(target, str) or not target.strip() or header in result:
            raise ValueError(f'{key} 中的映射无效或重复: {label!r}')
        result[header] = target.strip()
    return result


def locale_mapping(value: Any) -> dict[str, str]:
    mapping = string_map(value, 'locale_map')
    for locale in mapping.values():
        if not re.fullmatch(r'[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*', locale):
            raise ValueError(f'locale_map 中的 locale 无效: {locale}')
    return mapping


def parse_profile(data: Any) -> DocumentProfile:
    if not isinstance(data, dict) or not isinstance(data.get('language_header'), str):
        raise ValueError('缺少语种表头（language_header）')
    language_header = normalize_header(data['language_header'])
    fields = string_map(data.get('fields'), 'fields')
    if not language_header or language_header in fields:
        raise ValueError('语种表头不能为空或与物料表头相同')
    for target in fields.values():
        if target not in METADATA_FIELDS:
            raise ValueError(f'不支持的 App Store 字段: {target}')
    if len(set(fields.values())) != len(fields):
        raise ValueError('多个表头不能映射到同一 App Store 字段')
    layout = data.get('layout', 'languages_in_rows')
    if layout not in ('languages_in_rows', 'languages_in_columns'):
        raise ValueError(f'不支持的 layout: {layout}')
    sheet_range = data.get('range', DEFAULT_SHEET_RANGE)
    if not isinstance(sheet_range, str) or not re.fullmatch(r'[A-Z]+[1-9]\d*:[A-Z]+[1-9]\d*', sheet_range):
        raise ValueError('读取范围请填写 A1:H200 形式的子表范围')
    return DocumentProfile(language_header, fields, locale_mapping(data.get('locale_map')), layout, sheet_range)


def load_profile(directory: Path, document: str) -> DocumentProfile:
    local = directory / 'feishu-profiles' / f'{document}.json'
    path = local if local.exists() else SCRIPT_DIR / f'feishu-profile-{document}.json'
    if not path.is_file():
        guide = SCRIPT_DIR / 'feishu-import-guide.md'
        raise ValueError(f'此飞书文档尚无字段映射，请配置 {local}。填表说明见 {guide}')
    try:
        return parse_profile(json.loads(path.read_text(encoding='utf-8')))
    except ValueError as exc:
        raise ValueError(f'导入规则 {path} 有误: {exc}') from exc


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


def parse_csv_rows(data: dict[str, Any]) -> list[list[str]]:
    rows = data.get('rows')
    if isinstance(rows, list):
        columns = data.get('col_indices') or sorted(
            {column for row in rows for column in row['values']},
            key=lambda column: (len(column), column),
        )
        return [[clean_cell(row['values'].get(column)) for column in columns] for row in rows]

    annotated_csv = data.get('annotated_csv')
    if not isinstance(annotated_csv, str):
        raise ValueError('lark-cli +csv-get 未返回 rows 或 annotated_csv')

    return list(csv.reader(StringIO(annotated_csv), skipinitialspace=True))


def fetch_sheet_rows(url: str, sheet_id: str, sheet_range: str, identity: str) -> list[list[str]]:
    result = run_lark_cli([
        'sheets',
        '+csv-get',
        *(['--as', identity] if identity != 'auto' else []),
        '--url',
        url,
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
            '子表读取结果被截断，请用 --range 指定完整的物料区域后重试',
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


def parse_store_metadata(
    rows: list[list[str]],
    profile: DocumentProfile,
    configured_locales: dict[str, str],
) -> dict[str, dict[str, Any]]:
    records = zip_longest(*rows, fillvalue='') if profile.layout == 'languages_in_columns' else iter(rows)
    for record in records:
        headers = [normalize_header(value) for value in record]
        if profile.language_header in headers:
            break
    else:
        raise ValueError(f'当前子表缺少语种表头: {profile.language_header}')

    for label in [profile.language_header, *profile.fields]:
        if label not in headers:
            raise ValueError(f'当前子表缺少规则指定的表头: {label}')
        if headers.count(label) > 1:
            raise ValueError(f'当前子表包含重复表头: {label}')

    language_column = headers.index(profile.language_header)
    field_columns = {headers.index(label): target for label, target in profile.fields.items()}
    locale_map = configured_locales or profile.locale_map
    payload: dict[str, dict[str, Any]] = {}
    for record in records:
        metadata = {}
        for column, field_name in field_columns.items():
            value = clean_cell(record[column]) if column < len(record) else ''
            if not value:
                continue
            metadata[field_name] = split_keywords(value) if field_name == 'keywords' else value
        if not metadata:
            continue
        language = normalize_header(record[language_column]) if language_column < len(record) else ''
        if not language:
            raise ValueError(f'发现已填写物料但缺少「{profile.language_header}」的记录')
        locale = locale_map.get(language)
        if not locale:
            if configured_locales:
                print(f'跳过发版配置未选用的语言: {language}', file=sys.stderr)
                continue
            raise ValueError(f'导入规则缺少语言映射: {language}')
        if locale in payload:
            raise ValueError(f'当前子表的 {locale} 有多条物料，请为每个语种只保留一条')
        payload[locale] = {'locale': locale, **metadata}
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
    default_name: str | None,
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
        if default_name and not after.get('name'):
            after['name'] = default_name
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
        or '',
    ).strip()
    disabled_locales = {
        str(item).strip()
        for item in import_data.get('disabled_locales', [])
        if str(item).strip()
    }
    configured_locale_map = import_data.get('locale_map') or {}
    locale_map = locale_mapping(configured_locale_map) if configured_locale_map else {}
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
        help='带 ?sheet= 的飞书 Wiki 或电子表格链接，默认读取配置 import.feishu_sheet_url',
    )
    parser.add_argument(
        '--range',
        help='临时覆盖导入规则的 A1 范围',
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

    document, sheet_id = document_target(feishu_sheet_url)
    profile = load_profile(config_path.parent, document)
    print(f'读取飞书文档 {document} 的子表 {sheet_id}，导入字段: {", ".join(profile.fields)}')
    rows = fetch_sheet_rows(feishu_sheet_url, sheet_id, args.range or profile.sheet_range, lark_identity)
    payload = parse_store_metadata(rows, profile, config.locale_map)
    print(f'解析到 {len(payload)} 个语种，输出目录: {output_dir}')

    write_metadata_files(
        payload=payload,
        root=output_dir,
        disabled_locales=config.disabled_locales,
        selected_locales=set(args.locale),
        dry_run=bool(args.dry_run),
        default_name=config.default_name if 'name' in profile.fields.values() else None,
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
