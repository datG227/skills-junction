"""Validate the release ZIP contract with a temporary published app folder."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[1]
REQUIRED = [
    "SkillsJunction.WebView2.exe", "SkillsJunction.WebView2.dll",
    "SkillsJunction.WebView2.deps.json", "SkillsJunction.WebView2.runtimeconfig.json",
    "Microsoft.Web.WebView2.Core.dll", "Microsoft.Web.WebView2.WinForms.dll",
    "WebView2Loader.dll", "backend/SkillsJunction.WebView2.ps1",
    "web/index.html", "web/app.js", "web/styles.css", "README.md", "LICENSE",
]


@unittest.skipUnless(os.name == "nt", "Windows PowerShell required")
class PackageTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="skills-junction-package-")).resolve()
        self.publish = self.root / "publish"
        self.output = self.root / "output"
        for name in REQUIRED:
            target = self.publish / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(name.encode("utf-8"))
        for name in ["UserData/pairs.json", "WebView2/profile.json", "debug.log", "local.pdb", "tests/private.txt"]:
            target = self.publish / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("must not be packaged", encoding="utf-8")

    def tearDown(self):
        assert self.root.parent == Path(tempfile.gettempdir()).resolve()
        assert self.root.name.startswith("skills-junction-package-")
        shutil.rmtree(self.root)

    def package(self, version="1.0.1"):
        return subprocess.run([
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            str(REPO / "scripts/package.ps1"), "-Version", version,
            "-PublishDirectory", str(self.publish), "-OutputDirectory", str(self.output),
        ], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)

    def test_zip_contains_app_files_without_local_profiles_and_matches_checksum(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archive = self.output / "SkillsJunction-v1.0.1-win-x64.zip"
        with zipfile.ZipFile(archive) as package:
            self.assertIsNone(package.testzip())
            self.assertEqual(set(package.namelist()), {"SkillsJunction-v1.0.1/" + name for name in REQUIRED})
            for name in REQUIRED:
                self.assertEqual(package.read("SkillsJunction-v1.0.1/" + name), name.encode("utf-8"))
        checksum = (self.output / "SHA256SUMS.txt").read_text(encoding="utf-8").split()
        self.assertEqual(checksum, [hashlib.sha256(archive.read_bytes()).hexdigest(), archive.name])

    def test_missing_backend_is_rejected_before_creating_an_archive(self):
        (self.publish / "backend/SkillsJunction.WebView2.ps1").unlink()
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.output.glob("*.zip")), [])

    def test_default_paths_are_relative_to_the_script_not_the_callers_directory(self):
        script_dir = self.root / "scripts"
        script_dir.mkdir()
        script = script_dir / "package.ps1"
        shutil.copyfile(REPO / "scripts/package.ps1", script)
        shutil.copytree(self.publish, self.root / "artifacts" / "publish")
        result = subprocess.run([
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script),
            "-Version", "1.0.1",
        ], cwd=tempfile.gettempdir(), capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "artifacts/releases/SkillsJunction-v1.0.1-win-x64.zip").is_file())

    def test_version_cannot_escape_the_output_directory(self):
        result = self.package("../bad")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.root.rglob("*.zip")), [])
