"""回归：新版本 appcast 必须包含五语种说明，缺翻译时不得发布。"""

import tempfile
import unittest
import plistlib
import subprocess
import sys
from pathlib import Path
from xml.etree import ElementTree

from localize_appcast import localize_appcast


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
XML = "http://www.w3.org/XML/1998/namespace"
SAMPLE = f"""<rss xmlns:sparkle="{SPARKLE}"><channel>
<item><sparkle:version>1.1.6</sparkle:version><enclosure sparkle:edSignature="signed-archive" length="123" /></item>
<item><sparkle:version>1.1.5</sparkle:version></item>
</channel></rss>"""


class LocalizedAppcastTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.resources = Path(self.temp.name)
        self.write_note(None, "简体 & <说明>")
        for language in ("zh-Hant", "en", "ja", "ko"):
            self.write_note(language, f"{language} notes")

    def tearDown(self):
        self.temp.cleanup()

    def write_note(self, language, text):
        directory = self.resources if language is None else self.resources / f"{language}.lproj"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "ReleaseNotes.md").write_text(
            f"# Notes\n\n## 1.1.6 — 2026-09-29\n\n- {text}\n",
            encoding="utf-8",
        )

    def test_adds_five_localized_descriptions_to_current_item_only(self):
        result = localize_appcast(SAMPLE, "1.1.6", self.resources)
        root = ElementTree.fromstring(result)
        current, previous = root.findall("./channel/item")
        descriptions = current.findall("description")
        self.assertEqual(len(descriptions), 5)
        self.assertEqual(
            {item.attrib[f"{{{XML}}}lang"] for item in descriptions},
            {"zh-Hans", "zh-Hant", "en", "ja", "ko"},
        )
        self.assertTrue(all(item.attrib[f"{{{SPARKLE}}}format"] == "markdown" for item in descriptions))
        self.assertIn("简体 & <说明>", descriptions[0].text)
        self.assertEqual(current.find("enclosure").attrib[f"{{{SPARKLE}}}edSignature"], "signed-archive")
        self.assertEqual(current.find("enclosure").attrib["length"], "123")
        self.assertEqual(previous.findall("description"), [])
        self.assertEqual(localize_appcast(result, "1.1.6", self.resources).count("<description"), 5)

    def test_missing_translation_fails_before_writing(self):
        (self.resources / "ko.lproj" / "ReleaseNotes.md").unlink()
        with self.assertRaisesRegex(ValueError, "ko"):
            localize_appcast(SAMPLE, "1.1.6", self.resources)

    def test_signed_feed_mode_refuses_post_generation_edits(self):
        appcast = self.resources / "appcast.xml"
        appcast.write_text(SAMPLE, encoding="utf-8")
        info = self.resources / "Info.plist"
        info.write_bytes(plistlib.dumps({"SURequireSignedFeed": True}))
        result = subprocess.run(
            [
                sys.executable, str(Path(__file__).with_name("localize_appcast.py")),
                "--appcast", str(appcast), "--version", "1.1.6",
                "--resources", str(self.resources), "--info-plist", str(info),
            ],
            capture_output=True, text=True, check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SURequireSignedFeed", result.stderr)
        self.assertEqual(appcast.read_text(encoding="utf-8"), SAMPLE)


if __name__ == "__main__":
    unittest.main()
