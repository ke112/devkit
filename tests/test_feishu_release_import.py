"""飞书发版物料规则回归。运行 python3 -B tests/test_feishu_release_import.py"""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'devkit/Resources/AppStoreReleaseScripts'
sys.path.insert(0, str(SCRIPTS))
import import_feishu_store_localizations as importer


class FeishuImportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.config = self.root / 'config.json'
        self.config.write_text(json.dumps({'import': {'localizations_root': 'materials'}}))
        self.materials = self.root / 'materials'
        self.example_url = json.loads((SCRIPTS / 'app_store_connect.example.json').read_text())['import']['feishu_sheet_url']
        self.document, self.sheet = importer.document_target(self.example_url)

    def run_import(self, url, csv_text, *extra):
        with patch.object(sys, 'argv', ['import', '--config', str(self.config), '--doc', url, *extra]), \
             patch.object(importer, 'run_lark_cli', return_value={'data': {'annotated_csv': csv_text}}) as read:
            self.assertEqual(importer.main(), 0)
        read.assert_called_once()
        args = read.call_args.args[0]
        self.assertEqual(args[:2], ['sheets', '+csv-get'])
        self.assertEqual(args[args.index('--url') + 1], url)
        self.assertEqual(args[args.index('--sheet-id') + 1], importer.document_target(url)[1])
        return args

    def test_new_sheet_uses_same_profile_and_merges_only_current_column(self):
        destination = self.materials / 'en-US/metadata.json'
        destination.parent.mkdir(parents=True)
        destination.write_text(json.dumps({'locale': 'en-US', 'name': 'Local name', 'whatsNew': 'old'}))
        url = self.example_url.replace('sheet=' + self.sheet, 'sheet=NextRelease')
        csv_text = '上次更新,更新描述,语言,App名\nold,"First line,\nsecond line",英语,Other\nold,,印尼语,Other'
        args = self.run_import(url, csv_text, '--dry-run')
        self.assertEqual(args[args.index('--range') + 1], 'A1:U200')
        self.assertEqual(json.loads(destination.read_text())['whatsNew'], 'old')
        self.run_import(url, csv_text)
        self.assertEqual(json.loads(destination.read_text()), {
            'locale': 'en-US', 'name': 'Local name', 'whatsNew': 'First line,\nsecond line',
        })
        self.assertFalse((self.materials / 'id').exists())

    def test_another_document_with_language_columns(self):
        directory = self.root / 'feishu-profiles'
        directory.mkdir()
        (directory / 'OtherDoc.json').write_text(json.dumps({
            'layout': 'languages_in_columns', 'language_header': 'Field', 'range': 'B2:Z90',
            'fields': {'Copy': 'subtitle', 'Tags': 'keywords'}, 'locale_map': {'English': 'en-US', 'German': 'de-DE'},
        }))
        args = self.run_import('https://example.feishu.cn/sheets/OtherDoc?sheet=current',
                               'Field,English,German\nTags,"games, fun",Spiele\nCopy,New,Neu')
        self.assertEqual(args[args.index('--range') + 1], 'B2:Z90')
        self.assertEqual(json.loads((self.materials / 'en-US/metadata.json').read_text()), {
            'locale': 'en-US', 'subtitle': 'New', 'keywords': ['games', 'fun'],
        })
        self.assertEqual(json.loads((self.materials / 'de-DE/metadata.json').read_text())['subtitle'], 'Neu')

    def test_missing_sheet_or_document_profile_stops_before_reading_material(self):
        with patch.object(importer, 'run_lark_cli') as read, \
             patch.object(sys, 'argv', ['import', '--config', str(self.config), '--doc', self.example_url.split('?')[0]]):
            with self.assertRaisesRegex(ValueError, 'sheet='):
                importer.main()
            read.assert_not_called()
        with self.assertRaisesRegex(ValueError, 'OtherDoc.json'):
            self.run_import('https://example.feishu.cn/wiki/OtherDoc?sheet=New', '')
        self.assertFalse(self.materials.exists())

    def test_local_profile_picks_up_renamed_header_on_next_import(self):
        directory = self.root / 'feishu-profiles'
        directory.mkdir()
        path = directory / f'{self.document}.json'
        profile = json.loads((SCRIPTS / f'feishu-profile-{self.document}.json').read_text())
        path.write_text(json.dumps(profile))
        self.run_import(self.example_url, '语言,更新描述\n英语,Old copy')
        profile['fields'] = {'版本亮点': 'whatsNew'}
        path.write_text(json.dumps(profile))
        self.run_import(self.example_url, '版本亮点,语言,更新描述\nNew copy,英语,Ignore\nBaru,印尼语,Ignore')
        self.assertEqual(json.loads((self.materials / 'en-US/metadata.json').read_text())['whatsNew'], 'New copy')
        self.assertEqual(json.loads((self.materials / 'id/metadata.json').read_text())['whatsNew'], 'Baru')

    def test_invalid_local_override_never_falls_back_to_bundled_rule(self):
        directory = self.root / 'feishu-profiles'
        directory.mkdir()
        (directory / f'{self.document}.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'language_header'):
            importer.load_profile(self.root, self.document)

    def test_invalid_sheet_stops_before_writing_any_locale(self):
        for csv_text, message in [
            ('语言,上次更新\n英语,old', '缺少规则指定的表头'),
            ('语言,更新描述,更新描述\n英语,first,second', '重复表头'),
            ('语言,更新描述\n英语,first\n英文,second', '多条物料'),
            ('语言,更新描述\n英语,first\n未知语种,second', '缺少语言映射'),
            ('语言,更新描述\n英语,first\n,second', '缺少「语言」'),
        ]:
            with self.subTest(csv_text=csv_text), self.assertRaisesRegex(ValueError, message):
                self.run_import(self.example_url, csv_text)
        self.assertFalse(self.materials.exists())


if __name__ == '__main__':
    unittest.main()
