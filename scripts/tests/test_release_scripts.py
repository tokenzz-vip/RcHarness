"""Exercise architecture isolation with real Mach-O files and release metadata."""
import base64
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app_architecture import architectures, thin, verify
from validate_update_feed import read_dmg_info, validate


class ArchitectureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory()
        cls.root = Path(cls.fixtures.name)
        source = cls.root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        for arch in ("arm64", "x86_64"):
            subprocess.run(["xcrun", "clang", "-arch", arch, "-mmacosx-version-min=14.0",
                            str(source), "-o", str(cls.root / arch)], check=True)
        subprocess.run(["xcrun", "lipo", "-create", str(cls.root / "arm64"),
                        str(cls.root / "x86_64"), "-output", str(cls.root / "universal")], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.fixtures.cleanup()

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.app = Path(self.scratch.name) / "RcHarness.app"

    def bundle(self, arch):
        main = self.app / "Contents/MacOS/RcHarness"
        driver = self.app / "Contents/PlugIns/RcHarnessMicrophone.driver/Contents/MacOS/RcHarnessMicrophone"
        for binary in (main, driver):
            binary.parent.mkdir(parents=True)
            shutil.copy2(self.root / arch, binary)
        self.info = self.app / "Contents/Info.plist"
        self.info.write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "14.0",
                                            "SUFeedURL": f"https://example.com/appcast-{arch}.xml"}))

    def test_both_single_architecture_bundles_pass(self):
        for arch in ("arm64", "x86_64"):
            with self.subTest(arch=arch):
                self.bundle(arch)
                verify(self.app, arch)
                shutil.rmtree(self.app)

    def test_universal_helper_is_rejected_then_thinned_without_breaking_symlink(self):
        self.bundle("arm64")
        framework = self.app / "Contents/Frameworks/Sparkle.framework"
        helper = framework / "Versions/B/Autoupdate"
        helper.parent.mkdir(parents=True)
        shutil.copy2(self.root / "universal", helper)
        link = framework / "Autoupdate"
        link.symlink_to("Versions/B/Autoupdate")
        with self.assertRaisesRegex(ValueError, "Only arm64"):
            verify(self.app, "arm64")
        thin(framework, "arm64")
        self.assertTrue(link.is_symlink())
        self.assertEqual(architectures(link), ["arm64"])
        verify(self.app, "arm64")

    def test_wrong_feed_and_missing_driver_are_rejected(self):
        self.bundle("x86_64")
        with self.assertRaisesRegex(ValueError, "update feed"):
            verify(self.app, "arm64")
        shutil.rmtree(self.app / "Contents/PlugIns")
        with self.assertRaisesRegex(ValueError, "Missing application or HAL"):
            verify(self.app, "x86_64")

    def test_thinning_never_substitutes_a_missing_slice(self):
        self.bundle("arm64")
        with self.assertRaisesRegex(ValueError, "Missing x86_64 slice"):
            thin(self.app, "x86_64")


class DMGPackagingTests(unittest.TestCase):
    def test_application_notarization_submits_signed_dmg_and_rejects_failure(self):
        repository = Path(__file__).resolve().parents[2]
        workflow = (repository / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Notarize application and HAL driver\n", 1)[1]
        commands = textwrap.dedent(step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            app = root / "RcHarness.app"
            info = app / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "vip.tokenzz.rcharness"}))
            binaries = root / "bin"
            binaries.mkdir()
            # Build and mount real images; replace only signing and the Apple
            # service so acceptance and rejection need no credentials.
            tool = binaries / "notarization-tool"
            tool.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
                import json, os, sys
                from pathlib import Path
                name, args = Path(sys.argv[0]).name, sys.argv[1:]
                root = Path(os.environ["RUNNER_TEMP"])
                image = root / "notarization.dmg"
                signed = root / "image-signed"
                if name == "codesign":
                    assert Path(args[-1]) == image and image.is_file()
                    if "--sign" in args:
                        assert args[args.index("--sign") + 1] == os.environ["RC_HARNESS_SIGNING_IDENTITY"]
                        assert "--timestamp" in args
                        signed.touch()
                    else:
                        assert "--verify" in args and "--strict" in args and signed.exists()
                        (root / "image-verified").touch()
                elif args[:2] == ["notarytool", "submit"]:
                    assert Path(args[2]) == image and (root / "image-verified").exists()
                    print(json.dumps({"id": "test-submission", "status": os.environ["NOTARY_STATUS"]}))
                else:
                    assert args[:3] == ["notarytool", "log", "test-submission"]
                    Path(args[-1]).write_text(json.dumps({"issues": []}))
                '''))
            tool.chmod(0o755)
            for name in ("codesign", "xcrun"):
                (binaries / name).symlink_to(tool.name)
            for status in ("Accepted", "Invalid"):
                with self.subTest(status=status):
                    for marker in ("image-signed", "image-verified", "notarization-log.json"):
                        (root / marker).unlink(missing_ok=True)
                    result = subprocess.run(["/bin/bash", "-e", "-o", "pipefail", "-c", commands],
                        cwd=repository,
                        env={**os.environ, "PATH": str(binaries) + os.pathsep + os.defpath,
                             "RUNNER_TEMP": str(root), "APP_PATH": str(app),
                             "KEYCHAIN_PATH": str(root / "release.keychain-db"),
                             "RC_HARNESS_SIGNING_IDENTITY": "test-distribution-identity",
                             "NOTARY_STATUS": status},
                        capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0 if status == "Accepted" else 1,
                                     result.stdout + result.stderr)
                    self.assertTrue((root / "notarization-log.json").exists())
                    if status == "Accepted":
                        self.assertEqual(read_dmg_info(root / "notarization.dmg")["CFBundleIdentifier"],
                                         "vip.tokenzz.rcharness")
                    else:
                        self.assertIn("Notarization was not accepted", result.stdout)
                    self.assertEqual([path.name for path in root.glob("*.dmg")], ["notarization.dmg"])

    def test_release_signs_dmg_before_notarization_and_supplies_assessment_context(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Notarize and staple distribution DMG\n", 1)[1]
        commands = textwrap.dedent(step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            binaries = root / "bin"
            binaries.mkdir()
            # Exercise the actual workflow shell without Apple credentials or
            # changes to the host's Gatekeeper policy. Model the two DMG gates:
            # a signed image before submission, and context for open assessment.
            tool = binaries / "release-tool"
            tool.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
                import json, os, sys
                from pathlib import Path
                name, args = Path(sys.argv[0]).name, sys.argv[1:]
                root = Path(os.environ["RUNNER_TEMP"])
                signed = root / "dmg-signed"
                if name == "codesign":
                    if "--sign" in args:
                        assert args[args.index("--sign") + 1] == os.environ["RC_HARNESS_SIGNING_IDENTITY"]
                        assert "--timestamp" in args
                        signed.touch()
                    else:
                        assert "--verify" in args and signed.exists()
                elif name == "xcrun":
                    assert signed.exists(), "DMG must be signed before notarization"
                    if args[:2] == ["notarytool", "submit"]:
                        print(json.dumps({"status": "Accepted"}))
                    else:
                        assert args[:2] in (["stapler", "staple"], ["stapler", "validate"])
                elif name == "jq":
                    print(json.load(open(args[-1]))["status"])
                elif name == "spctl":
                    if "--context" not in args or args[args.index("--context") + 1] != "context:primary-signature":
                        sys.exit("source=Insufficient Context")
                    assert signed.exists()
                    (root / "dmg-assessed").touch()
                else:
                    assert name == "hdiutil" and args[0] == "verify"
                '''))
            tool.chmod(0o755)
            for name in ("codesign", "xcrun", "jq", "spctl", "hdiutil"):
                (binaries / name).symlink_to(tool.name)
            (root / "RcHarness-v1.2.3-macos-arm64.dmg").write_bytes(b"release fixture")
            result = subprocess.run(["/bin/bash", "-e", "-o", "pipefail", "-c", commands],
                env={**os.environ, "PATH": str(binaries) + os.pathsep + os.defpath,
                     "RUNNER_TEMP": str(root), "DIST_DIR": str(root), "RELEASE_TAG": "v1.2.3",
                     "RC_HARNESS_ARCH": "arm64", "KEYCHAIN_PATH": str(root / "release.keychain-db"),
                     "RC_HARNESS_SIGNING_IDENTITY": "test-distribution-identity"},
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((root / "dmg-assessed").exists())
            checksums = (root / "SHA256SUMS-arm64").read_text().splitlines()
            self.assertEqual({line.split()[1] for line in checksums},
                             {"RcHarness-v1.2.3-macos-arm64.dmg", "RcHarness-macos-arm64.dmg"})
            self.assertEqual(len({line.split()[0] for line in checksums}), 1)
            self.assertEqual((root / "RcHarness-macos-arm64.dmg").read_bytes(),
                             (root / "RcHarness-v1.2.3-macos-arm64.dmg").read_bytes())

    def test_package_script_keeps_application_bundle(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            app = root / "RcHarness.app"
            info = app / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "vip.tokenzz.rcharness",
                "CFBundleShortVersionString": "1.2.3",
            }))
            dmg = root / "RcHarness.dmg"
            subprocess.run([
                str(Path(__file__).resolve().parents[1] / "package_dmg.sh"),
                str(app), str(dmg), "RcHarness Test",
            ], check=True)
            self.assertEqual(read_dmg_info(dmg)["CFBundleIdentifier"], "vip.tokenzz.rcharness")

    def test_package_script_retries_only_temporary_verification_failures(self):
        for scenario, expected_attempts, succeeds in (
            ("temporary", 2, True),
            ("unavailable", 3, False),
            ("invalid", 1, False),
        ):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                info = root / "RcHarness.app/Contents/Info.plist"
                info.parent.mkdir(parents=True)
                info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "vip.tokenzz.rcharness"}))
                hdiutil = root / "hdiutil"
                hdiutil.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
                    import sys
                    from pathlib import Path

                    command, *args = sys.argv[1:]
                    image = Path(args[-1])
                    if command == "create":
                        image.touch(exist_ok=False)
                    else:
                        assert command == "verify" and image.is_file()
                        with image.with_suffix(".attempts").open("a+") as attempts:
                            attempts.seek(0)
                            previous_attempts = attempts.read().count("\\n")
                            attempts.write("verify\\n")
                        scenario = image.stem
                        if scenario == "invalid":
                            sys.exit("hdiutil: verify failed - image data corrupted")
                        if scenario == "unavailable" or previous_attempts == 0:
                            sys.exit("hdiutil: verify failed - Resource temporarily unavailable")
                    '''))
                hdiutil.chmod(0o755)
                sleep = root / "sleep"
                sleep.write_text("#!/bin/sh\nexit 0\n")
                sleep.chmod(0o755)

                dmg = root / f"{scenario}.dmg"
                packaged = subprocess.run([
                    str(Path(__file__).resolve().parents[1] / "package_dmg.sh"),
                    str(info.parent.parent), str(dmg),
                ], env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"]},
                    capture_output=True, text=True)
                self.assertEqual(packaged.returncode == 0, succeeds, packaged.stderr)
                self.assertEqual(dmg.with_suffix(".attempts").read_text().splitlines(),
                                 ["verify"] * expected_attempts)


class ReleasePublicationTests(unittest.TestCase):
    def test_publication_assets_and_failure_gates(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Publish GitHub Release\n", 1)[1]
        commands = textwrap.dedent(step.split("        run: |\n", 1)[1])
        expected = {"SHA256SUMS", "appcast-arm64.xml", "appcast-x86_64.xml",
                    "RcHarness-v1.2.3-macos-arm64.dmg", "RcHarness-v1.2.3-macos-x86_64.dmg",
                    "RcHarness-macos-arm64.dmg", "RcHarness-macos-x86_64.dmg"}
        for scenario in ("new", "draft", "published", "unexpected-assets", "upload-failure",
                         "missing-fixed-dmg", "mismatched-fixed-dmg"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                dist = root / "dist"
                dist.mkdir()
                for name in expected:
                    (dist / name).write_text("release fixture")
                if scenario == "missing-fixed-dmg":
                    (dist / "RcHarness-macos-x86_64.dmg").unlink()
                elif scenario == "mismatched-fixed-dmg":
                    (dist / "RcHarness-macos-x86_64.dmg").write_text("different release")
                state = None if scenario == "new" else {
                    "isDraft": scenario != "published",
                    "assets": [{"name": "unexpected.txt" if scenario == "unexpected-assets" else "SHA256SUMS"}],
                }
                (root / "state.json").write_text(json.dumps(state))
                binaries = root / "bin"
                binaries.mkdir()
                gh = binaries / "gh"
                gh.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
                    import json, os, sys
                    from pathlib import Path
                    root = Path(os.environ["RUNNER_TEMP"])
                    args = sys.argv[1:]
                    assert args[0] == "release" and args[2] == "v1.2.3"
                    action = args[1]
                    with (root / "calls.jsonl").open("a") as calls:
                        calls.write(json.dumps(args) + "\\n")
                    state_path = root / "state.json"
                    state = json.loads(state_path.read_text())
                    scenario = os.environ["SCENARIO"]
                    if action == "view":
                        if state is None:
                            sys.exit(1)
                        print(json.dumps(state))
                    elif action in ("create", "upload"):
                        if scenario == "upload-failure":
                            sys.exit(1)
                        if action == "create":
                            assert state is None and "--draft" in args
                            state = {"isDraft": True, "assets": []}
                        assert state["isDraft"]
                        names = {item["name"] for item in state["assets"]}
                        names.update(Path(arg).name for arg in args[3:] if Path(arg).is_file())
                        state["assets"] = [{"name": name} for name in sorted(names)]
                    else:
                        assert action == "edit" and "--draft=false" in args and state["isDraft"]
                        state["isDraft"] = False
                    state_path.write_text(json.dumps(state))
                    '''))
                gh.chmod(0o755)
                result = subprocess.run(["/bin/bash", "-e", "-o", "pipefail", "-c", commands],
                    env={**os.environ, "PATH": str(binaries) + os.pathsep + os.defpath,
                         "RUNNER_TEMP": str(root), "DIST_DIR": str(dist), "RELEASE_TAG": "v1.2.3",
                         "SCENARIO": scenario}, capture_output=True, text=True)
                state = json.loads((root / "state.json").read_text())
                call_log = root / "calls.jsonl"
                calls = [json.loads(line) for line in call_log.read_text().splitlines()] if call_log.exists() else []
                succeeds = scenario in ("new", "draft")
                self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
                if succeeds:
                    self.assertFalse(state["isDraft"])
                    self.assertEqual({item["name"] for item in state["assets"]}, expected)
                else:
                    self.assertFalse(any(call[1] == "edit" for call in calls))
                    if scenario in ("missing-fixed-dmg", "mismatched-fixed-dmg"):
                        self.assertEqual(calls, [])
                    elif scenario in ("published", "unexpected-assets"):
                        self.assertEqual([call[1] for call in calls], ["view"])
                    else:
                        self.assertTrue(state["isDraft"])


class UpdateFeedTests(unittest.TestCase):
    def fixture(self, root, arch, bundled_arch=None):
        repository, tag = "tokenzz-vip/RcHarness", "v1.2.3"
        archive = root / f"RcHarness-{tag}-macos-{arch}.dmg"
        feed = root / f"appcast-{arch}.xml"
        info = {"CFBundleVersion": "123", "CFBundleShortVersionString": "1.2.3",
                "LSMinimumSystemVersion": "14.0",
                "SUFeedURL": f"https://github.com/{repository}/releases/latest/download/appcast-{bundled_arch or arch}.xml"}
        stage = root / f"stage-{arch}"
        app_info = stage / "RcHarness.app/Contents/Info.plist"
        app_info.parent.mkdir(parents=True)
        app_info.write_bytes(plistlib.dumps(info))
        subprocess.run(["hdiutil", "create", "-quiet", "-srcfolder", str(stage),
                        "-format", "UDZO", "-ov", str(archive)], check=True)
        ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        rss = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(rss, "channel"), "item")
        for key, value in (("version", "123"), ("shortVersionString", "1.2.3"), ("minimumSystemVersion", "14.0")):
            ET.SubElement(item, f"{{{ns}}}{key}").text = value
        ET.SubElement(item, "enclosure", {"url": f"https://github.com/{repository}/releases/download/{tag}/{archive.name}",
                                         "length": str(archive.stat().st_size),
                                         f"{{{ns}}}edSignature": base64.b64encode(bytes(64)).decode()})
        ET.ElementTree(rss).write(feed)
        return feed, archive, tag, repository, arch

    def test_each_architecture_has_matching_release_metadata(self):
        with tempfile.TemporaryDirectory() as scratch:
            for arch in ("arm64", "x86_64"):
                with self.subTest(arch=arch):
                    validate(*self.fixture(Path(scratch), arch))

    def test_swapped_architecture_feed_inside_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as scratch:
            args = self.fixture(Path(scratch), "x86_64", bundled_arch="arm64")
            with self.assertRaisesRegex(ValueError, "Application update feed"):
                validate(*args)

    def test_mislabeled_release_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as scratch:
            args = self.fixture(Path(scratch), "arm64")
            with self.assertRaisesRegex(ValueError, "Archive name"):
                validate(*args[:-1], "x86_64")


if __name__ == "__main__":
    unittest.main()
