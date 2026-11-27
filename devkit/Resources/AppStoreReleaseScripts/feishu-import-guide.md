# 飞书发版物料导入

## 每次发版怎么填

在发版文档里按原习惯填写本次物料。例如 GameWave 的子表：

| 语言 | 更新描述 |
| --- | --- |
| 英语 | Bug fixes and performance improvements. |
| 印尼语 | Perbaikan bug dan peningkatan performa. |

打开这张子表，复制带 `?sheet=…` 的链接，粘贴到 DevKit「iOS App 发版」的「飞书表格」，点「导入物料」。下个版本只需换成新子表的链接。DevKit 从目标子表读取「更新描述」，写入 `localizations/<locale>/metadata.json` 的 `whatsNew`。多行文案可直接填在同一单元格。其余列和空白文案会跳过，已有本地字段会保留。

## 表头改名时改哪里

在「iOS App 发版」右上角点「示例配置」，选择「GameWave 物料规则」，点「编辑本地规则」。DevKit 用“文本编辑”打开实际导入时使用的 JSON。第一次打开会按内置示例创建文件，以后打开的是你已保存的版本。

例如列名从「更新描述」改为「版本亮点」，在 `fields` 里把 `"更新描述": "whatsNew"` 改成 `"版本亮点": "whatsNew"`。按 ⌘S 保存，再点「导入物料」就会读取新列。同一文档换新子表或调整列顺序时，继续使用同一份配置。

## 接入另一份文档

1. 从链接的 `/wiki/` 或 `/sheets/` 后取出文档标识。例如 `https://example.feishu.cn/wiki/Abc123?sheet=Xy456` 的文档标识是 `Abc123`，子表标识是 `Xy456`。
2. 在 Finder 按 `⌘⇧G` 前往 `~/Library/Application Support/DevKit/AppStoreRelease`，新建 `feishu-profiles` 文件夹。把规则保存为 `feishu-profiles/Abc123.json`。使用独立脚本时，该文件夹放在 `--config` 指定的配置文件旁。
3. 将规则文件和填表示例发给使用这份文档的同事。每台 Mac 放一次，以后新增子表都能复用。本地同名规则优先于内置规则，保存后再次点「导入物料」即可生效。

假设另一份文档这样填：

| Language | Release notes | Store subtitle |
| --- | --- | --- |
| English (US) | Improved search. | Find your next game |

对应的 `Abc123.json` 为：

```json
{
  "layout": "languages_in_rows",
  "range": "A1:H300",
  "language_header": "Language",
  "fields": {
    "Release notes": "whatsNew",
    "Store subtitle": "subtitle"
  },
  "locale_map": {
    "English (US)": "en-US"
  }
}
```

- `layout` 选择语种排列方式。每行一个语种用 `languages_in_rows`。若首行是 `Language | English (US) | …`，下方每行是一个字段，则用 `languages_in_columns`，其余配置相同。
- `range` 指定当前子表中包含完整表头和所有语种的矩形区域，省略时读取 `A1:U200`。
- `language_header` 和 `fields` 左侧填写实际表头。只列本次要导入的字段。规则列出的表头必须出现且唯一。可用目标字段为 `whatsNew`、`name`、`subtitle`、`promotionalText`、`description`、`keywords`、`supportUrl`、`marketingUrl`、`privacyPolicyUrl`。关键词支持英文逗号或换行分隔。
- `locale_map` 写明表内的语言名称及其 App Store locale。DevKit 的「语种映射（可选）」留空即使用文档规则；已有发版配置填了语种映射时，按发版配置中的语言名称和范围导入。「跳过语种」仍然生效。

首次接入的 Mac 需要已安装 `lark-cli`，且使用的飞书身份能读取目标文档。导入只写本地物料。线上发布继续使用独立的「确认上传」操作。
