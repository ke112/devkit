import argparse
import csv
from datetime import date
from html import unescape
from io import StringIO
from pathlib import Path
import re
from urllib.request import Request, urlopen


REVIEWED_DATES = {
    2004080: "2004-09-23",
    2004113: "2004-12-09",
    2004114: "2004-12-12",
    2005017: "2005-02-08",
    2005064: "2005-06-05",
    2006050: "2006-05-02",
    2006084: "2006-07-20",
}


def fetch(url):
    with urlopen(Request(url, headers={"User-Agent": "Mozilla/5.0"}), timeout=30) as response:
        return response.read().decode("utf-8")


def primary_archive():
    html = fetch("https://datachart.500.com/ssq/history/newinc/history.php?start=03001&end=19151")
    rows = {}
    for row in re.findall(r"<tr\b[^>]*>(.*?)</tr>", re.sub(r"<!--.*?-->", "", html, flags=re.S), re.S):
        cells = [unescape(value).strip() for value in re.findall(r"<td\b[^>]*>(.*?)</td>", row, re.S)]
        if not cells or not re.fullmatch(r"\d{5}", cells[0]):
            continue
        issue = int("20" + cells[0])
        if issue in rows or len(cells) != 16:
            raise ValueError(f"Unexpected archive row for {issue}")
        reds = sorted(map(int, cells[1:7]))
        blue = int(cells[7])
        drawn = date.fromisoformat(cells[-1])
        if drawn.year != issue // 1000 or len(set(reds)) != 6 or not 1 <= reds[0] <= reds[-1] <= 33 or not 1 <= blue <= 16:
            raise ValueError(f"Invalid draw for {issue}")
        bonuses = [int(cells[index].replace(",", "")) for index in (11, 13)]
        rows[issue] = (drawn, *reds, blue, *bonuses)
    return rows


def verify_year(year, rows):
    html = fetch(f"https://h5.wcssq.cn/list/shuangseqiu/{year}")
    verified = set()
    for row in re.findall(r"<tr\b[^>]*>(.*?)</tr>", html, re.S):
        issue_match = re.search(r'/detail/shuangseqiu/(\d{7})', row)
        if not issue_match:
            continue
        issue = int(issue_match[1])
        drawn = re.search(r"(\d{4})年(\d+)月(\d+)日", row)
        reds = sorted(map(int, re.findall(r'class="ball ball--red">(\d+)<', row)))
        blues = list(map(int, re.findall(r'class="ball ball--blue">(\d+)<', row)))
        if not drawn or issue in verified or issue // 1000 != year:
            raise ValueError(f"Invalid verification row for {issue}")
        if (*reds, *blues) != rows[issue][1:8]:
            raise ValueError(f"Sources disagree for {issue}")
        alternate_date = date(*map(int, drawn.groups()))
        if alternate_date != rows[issue][0]:
            reviewed = REVIEWED_DATES.get(issue)
            if reviewed not in (str(rows[issue][0]), str(alternate_date)):
                raise ValueError(f"Review conflicting dates for {issue}")
            rows[issue] = (date.fromisoformat(reviewed), *rows[issue][1:])
        verified.add(issue)
    expected = {issue for issue in rows if issue // 1000 == year}
    if not expected or verified != expected or expected != set(range(year * 1000 + 1, max(expected) + 1)):
        raise ValueError(f"Incomplete archive for {year}")


def main():
    parser = argparse.ArgumentParser(description="Build the verified 2003–2019 SSQ historical draw archive.")
    parser.add_argument("output", type=Path, help="Destination CSV file")
    args = parser.parse_args()
    rows = primary_archive()
    for year in range(2003, 2020):
        verify_year(year, rows)
    if len(rows) != 2510 or min(rows) != 2003001 or max(rows) != 2019151:
        raise ValueError("Unexpected archive boundaries")
    output = StringIO()
    writer = csv.writer(output, lineterminator="\n")
    for issue, row in sorted(rows.items()):
        writer.writerow((issue, *row))
    args.output.write_text(output.getvalue(), encoding="utf-8")
    print(f"Verified {len(rows)} draws ({min(rows)}–{max(rows)})")


if __name__ == "__main__":
    main()
