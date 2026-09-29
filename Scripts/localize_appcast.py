#!/usr/bin/env python3
"""把五语种更新说明嵌入 generate_appcast 生成的新版本条目。"""

import argparse
import os
import plistlib
import re
import tempfile
from pathlib import Path
from xml.etree import ElementTree


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
XML = "http://www.w3.org/XML/1998/namespace"
LANGUAGES = ("zh-Hans", "zh-Hant", "en", "ja", "ko")
ElementTree.register_namespace("sparkle", SPARKLE)


def version_notes(path: Path, version: str) -> str:
    if not path.is_file():
        raise ValueError(f"缺少更新说明：{path}")
    lines = path.read_text(encoding="utf-8").splitlines()
    heading = re.compile(rf"^## {re.escape(version)}(?:\s|$)")
    start = next((index + 1 for index, line in enumerate(lines) if heading.match(line)), None)
    if start is None:
        raise ValueError(f"更新说明缺少版本 {version}：{path}")
    end = next((index for index in range(start, len(lines)) if lines[index].startswith("## ")), len(lines))
    notes = "\n".join(lines[start:end]).strip()
    if not any(line.startswith("- ") for line in notes.splitlines()):
        raise ValueError(f"更新说明没有条目：{path}")
    return notes


def localize_appcast(xml_text: str, version: str, resources: Path) -> str:
    descriptions = {}
    for language in LANGUAGES:
        path = resources / "ReleaseNotes.md" if language == "zh-Hans" else resources / f"{language}.lproj" / "ReleaseNotes.md"
        descriptions[language] = version_notes(path, version)

    root = ElementTree.fromstring(xml_text)
    item = next(
        (
            candidate for candidate in root.findall("./channel/item")
            if candidate.findtext(f"{{{SPARKLE}}}version") == version
        ),
        None,
    )
    if item is None:
        raise ValueError(f"appcast 缺少版本 {version}")

    for old in item.findall("description"):
        item.remove(old)
    for language, notes in descriptions.items():
        element = ElementTree.SubElement(
            item,
            "description",
            {f"{{{XML}}}lang": language, f"{{{SPARKLE}}}format": "markdown"},
        )
        element.text = notes

    ElementTree.indent(root, space="    ")
    return '<?xml version="1.0" encoding="utf-8"?>\n' + ElementTree.tostring(root, encoding="unicode") + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--info-plist", type=Path, required=True)
    args = parser.parse_args()

    with args.info_plist.open("rb") as stream:
        if plistlib.load(stream).get("SURequireSignedFeed"):
            raise ValueError("已启用 SURequireSignedFeed，不能在 generate_appcast 签名后修改 feed")

    updated = localize_appcast(args.appcast.read_text(encoding="utf-8"), args.version, args.resources)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=args.appcast.parent, delete=False) as stream:
        temp_path = Path(stream.name)
        stream.write(updated)
    try:
        os.replace(temp_path, args.appcast)
    finally:
        temp_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
