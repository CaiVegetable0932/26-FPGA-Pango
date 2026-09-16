"""Static resource/link checks; deliberately not a browser visual test."""
import argparse
from collections import Counter
from datetime import datetime, timezone
from html.parser import HTMLParser
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids, self.assets, self.panels = [], [], []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.append(attrs["id"])
        if tag in ("link", "script"):
            self.assets.append(attrs.get("src",attrs.get("href","")))
        if tag == "article" and "video-panel" in attrs.get("class","").split():
            self.panels.append(attrs["class"])


def main():
    parser = argparse.ArgumentParser(description="Check local Web assets and documentation links.")
    parser.add_argument("--report", type=Path, default=ROOT/"reports/webui-records-static-checks.json")
    args = parser.parse_args()
    page = Page()
    page.feed((ROOT/"web/index.html").read_text(encoding="utf-8"))
    assert not [key for key,value in Counter(page.ids).items() if value>1], "duplicate HTML ids"
    references = set()
    for filename in ("app.js", "records.js", "video-input-ui.js"):
        script = (ROOT/"web"/filename).read_text(encoding="utf-8")
        references.update(re.findall(r'\$\("([^"]+)"\)', script))
        references.update(re.findall(r'(?<![\w$])text\("([^"]+)"\s*,', script))
    assert references.issubset(set(page.ids)), references-set(page.ids)
    assert len(page.panels)==2
    assert all((ROOT/"web"/asset.lstrip("/")).is_file() for asset in page.assets)
    css = (ROOT/"web/app.css").read_text(encoding="utf-8")
    assert "grid-template-columns:repeat(2,minmax(0,1fr))" in css
    assert "aspect-ratio:16/9" in css
    docs = [ROOT/"README.md", ROOT/"docs/Web界面与核心接入说明.md",
            ROOT/"reports/Web_UI记录管理更新验证.md", ROOT/"docs/视频采集设备接入说明.md"]
    broken = []
    for path in docs:
        for target in re.findall(r'\]\(([^)]+)\)',path.read_text(encoding="utf-8")):
            if target.startswith(("http:","https:","#","mailto:")):
                continue
            target = target.split("#")[0].strip("<>")
            # This script's output is created after the checks.
            if target == "webui-records-static-checks.json":
                continue
            if target and not (path.parent/target).exists():
                broken.append((str(path),target))
    assert not broken, broken
    files = [p for folder in ("web", "src/pango_video") for p in sorted((ROOT/folder).glob("*")) if p.is_file()]
    report = dict(utc=datetime.now(timezone.utc).isoformat(),passed=True,
        html_ids=len(page.ids),ui_references=len(references),video_panels=len(page.panels),
        assets=len(page.assets),documents=len(docs),broken_links=broken,browser_ui_qa="not_performed",
        source_sha256={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({k:v for k,v in report.items() if k!="source_sha256"}))


if __name__ == "__main__":
    main()
