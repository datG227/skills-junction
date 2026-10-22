"""Windows integration tests using real junctions and an isolated backend profile.

Run: python -m unittest discover -s tests -v
"""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "SkillsJunction.WebView2.ps1"


@unittest.skipUnless(os.name == "nt", "Windows junctions required")
class SkillToggleTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="skills-junction-test-")).resolve()
        self.source = self.root / "source"
        self.target = self.root / "target"
        for name in ("alpha", "beta", "gamma"):
            folder = self.source / name
            folder.mkdir(parents=True)
            (folder / "SKILL.md").write_text(name, encoding="utf-8")
        self.proc = None
        self.start_backend()
        result = self.call("add", name="Test", group="Tests", source=str(self.source), target=str(self.target))
        self.assertTrue(result["ok"], result)
        self.pair_id = result["pairs"][0]["id"]

    def start_backend(self):
        env = os.environ.copy()
        env["LOCALAPPDATA"] = str(self.root / "profile")
        script_path = str(SCRIPT).replace("'", "''")
        command = "& ([scriptblock]::Create([IO.File]::ReadAllText('" + script_path + "', [Text.Encoding]::UTF8))) -BackendServer"
        self.proc = subprocess.Popen(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, encoding="utf-8", env=env)
        self.responses = queue.Queue()
        self.reader = threading.Thread(target=self.read_responses, args=(self.proc, self.responses), daemon=True)
        self.reader.start()

    @staticmethod
    def read_responses(proc, responses):
        for line in proc.stdout:
            responses.put(line)

    def stop_backend(self):
        if self.proc and self.proc.poll() is None:
            self.call("quit")
            self.proc.wait(timeout=10)
        if self.proc:
            for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
                stream.close()
            self.reader.join(timeout=2)
            self.proc = None

    def tearDown(self):
        try:
            self.stop_backend()
        finally:
            # Verify the exact generated temporary root before recursive cleanup.
            assert self.root.parent == Path(tempfile.gettempdir()).resolve()
            assert self.root.name.startswith("skills-junction-test-")
            # Python 3.8+ removes Windows junction entries without following them.
            shutil.rmtree(self.root)

    def call(self, action, **fields):
        self.proc.stdin.write(json.dumps({"requestId": "test", "action": action, **fields}) + "\n")
        self.proc.stdin.flush()
        try:
            return json.loads(self.responses.get(timeout=20))
        except queue.Empty:
            self.proc.kill()
            self.fail("Backend did not return JSON: " + self.proc.stderr.read())

    def toggle(self, name, enabled):
        return self.call("toggle-skill", id=self.pair_id, skill=name, enabled=enabled)

    def test_disabled_skill_is_unlinked_and_group_enable_does_not_recreate_it(self):
        result = self.toggle("alpha", False)
        self.assertTrue(result["ok"], result)
        self.assertFalse((self.target / "alpha").exists())
        self.assertEqual((self.source / "alpha" / "SKILL.md").read_text(), "alpha")
        self.assertTrue((self.target / "beta" / "SKILL.md").is_file())
        self.assertTrue(self.call("toggle", id=self.pair_id, enabled=False)["ok"])
        self.assertTrue(self.call("toggle", id=self.pair_id, enabled=True)["ok"])
        self.assertFalse((self.target / "alpha").exists())
        self.assertTrue((self.target / "beta").exists())

    def test_disabled_choice_survives_backend_restart(self):
        self.assertTrue(self.toggle("alpha", False)["ok"])
        self.stop_backend()
        self.start_backend()
        result = self.call("toggle", id=self.pair_id, enabled=True)
        self.assertTrue(result["ok"], result)
        self.assertFalse((self.target / "alpha").exists())
        self.assertTrue(self.toggle("alpha", True)["ok"])
        self.assertTrue((self.target / "alpha" / "SKILL.md").is_file())

    def test_enabling_one_skill_does_not_enable_other_skills(self):
        self.assertTrue(self.call("toggle", id=self.pair_id, enabled=False)["ok"])
        result = self.toggle("beta", True)
        self.assertTrue(result["ok"], result)
        self.assertTrue((self.target / "beta" / "SKILL.md").is_file())
        self.assertFalse((self.target / "alpha").exists())
        self.assertFalse((self.target / "gamma").exists())

    def test_existing_destination_folder_is_preserved(self):
        os.rmdir(self.target / "alpha")  # Remove only our test junction.
        (self.target / "alpha").mkdir()
        marker = self.target / "alpha" / "keep.txt"
        marker.write_text("keep")
        for enabled in (False, True):
            self.assertFalse(self.toggle("alpha", enabled)["ok"])
            self.assertEqual(marker.read_text(), "keep")
        items = self.call("skills", id=self.pair_id)["skills"]
        self.assertFalse(next(item for item in items if item["name"] == "alpha")["canToggle"])

    def test_changed_junction_is_preserved(self):
        os.rmdir(self.target / "alpha")
        other = self.root / "other"
        other.mkdir()
        (other / "keep.txt").write_text("keep")
        subprocess.run(["powershell.exe", "-NoProfile", "-Command",
                        f"New-Item -ItemType Junction -Path '{self.target / 'alpha'}' -Target '{other}' | Out-Null"], check=True)
        self.assertFalse(self.toggle("alpha", False)["ok"])
        self.assertEqual((self.target / "alpha" / "keep.txt").read_text(), "keep")

    def test_invalid_names_cannot_modify_paths_outside_the_source(self):
        for name in ("..", "../alpha", "..\\alpha", str(self.root), "missing", "alpha\\..\\beta"):
            with self.subTest(name=name):
                self.assertFalse(self.toggle(name, False)["ok"])
                self.assertFalse(self.toggle(name, True)["ok"])
        self.assertTrue((self.target / "alpha" / "SKILL.md").is_file())

    def test_all_skills_can_be_disabled_without_group_enable_recreating_them(self):
        for name in ("alpha", "beta", "gamma"):
            self.assertTrue(self.toggle(name, False)["ok"])
        result = self.call("toggle", id=self.pair_id, enabled=True)
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["pairs"][0]["on"])
        for item in self.call("skills", id=self.pair_id)["skills"]:
            self.assertFalse(item["enabled"])
            self.assertTrue(item["canToggle"])

    def test_failed_enable_does_not_clear_the_disabled_choice(self):
        self.assertTrue(self.toggle("alpha", False)["ok"])
        account = subprocess.check_output(["whoami"], text=True).strip()
        subprocess.run(["icacls", str(self.target), "/deny", account + ":(AD)"],
                       check=True, stdout=subprocess.DEVNULL)
        try:
            result = self.toggle("alpha", True)
            self.assertFalse(result["ok"], result)
            self.assertFalse((self.target / "alpha").exists())
        finally:
            subprocess.run(["icacls", str(self.target), "/remove:d", account],
                           check=True, stdout=subprocess.DEVNULL)
        self.assertTrue(self.call("toggle", id=self.pair_id, enabled=True)["ok"])
        self.assertFalse((self.target / "alpha").exists())

    def test_legacy_config_without_disabled_skills_remains_compatible(self):
        self.stop_backend()
        config_path = self.root / "profile" / "SkillsJunction" / "pairs.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        for pair in config["pairs"]:
            pair.pop("disabledSkills", None)
        config_path.write_text(json.dumps(config), encoding="utf-8")
        self.start_backend()
        self.assertTrue(self.toggle("alpha", False)["ok"])
        self.assertTrue(self.toggle("alpha", True)["ok"])
        self.assertTrue((self.target / "alpha" / "SKILL.md").is_file())

    def test_locked_config_prevents_unlinking_and_reports_failure(self):
        config_path = self.root / "profile" / "SkillsJunction" / "pairs.json"
        with config_path.open("rb"):
            result = self.toggle("alpha", False)
            self.assertFalse(result["ok"], result)
            self.assertTrue((self.target / "alpha" / "SKILL.md").is_file())
        self.assertTrue(self.call("toggle", id=self.pair_id, enabled=False)["ok"])
        self.assertTrue(self.call("toggle", id=self.pair_id, enabled=True)["ok"])
        self.assertTrue((self.target / "alpha" / "SKILL.md").is_file())


if __name__ == "__main__":
    unittest.main()
