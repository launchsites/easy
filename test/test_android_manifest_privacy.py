import unittest
from pathlib import Path
from xml.etree import ElementTree


APP = Path(__file__).resolve().parents[1] / "android/app/src/main"
ANDROID = "{http://schemas.android.com/apk/res/android}"


class AndroidManifestPrivacyTest(unittest.TestCase):
    def setUp(self):
        self.application = ElementTree.parse(APP / "AndroidManifest.xml").find(
            "application"
        )

    def resource(self, attribute):
        name = self.application.attrib[ANDROID + attribute]
        self.assertTrue(name.startswith("@xml/"))
        return ElementTree.parse(APP / "res/xml" / (name[5:] + ".xml")).getroot()

    def test_cleartext_uses_exact_loopback_addresses(self):
        policy = self.resource("networkSecurityConfig")
        self.assertEqual(policy.find("base-config").get("cleartextTrafficPermitted"), "false")
        cleartext = policy.findall(".//domain-config[@cleartextTrafficPermitted='true']")
        self.assertEqual(len(cleartext), 1)
        self.assertEqual(
            {(domain.text, domain.get("includeSubdomains")) for domain in cleartext[0]},
            {("127.0.0.1", "false"), ("::1", "false")},
        )

    def test_system_backups_and_transfers_exclude_workspace_storage(self):
        self.assertEqual(self.application.get(ANDROID + "allowBackup"), "false")
        rules = self.resource("dataExtractionRules")
        excluded_domains = {
            "root", "file", "database", "sharedpref", "external", "device_root",
            "device_file", "device_database", "device_sharedpref",
        }
        for mode in ("cloud-backup", "device-transfer"):
            with self.subTest(mode=mode):
                rule = rules.find(mode)
                self.assertEqual(rule.findall("include"), [])
                self.assertEqual(
                    {(item.attrib["domain"], item.attrib["path"]) for item in rule},
                    {(domain, ".") for domain in excluded_domains},
                )


if __name__ == "__main__":
    unittest.main()
