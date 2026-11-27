"""Offline regression for the cargo-ndk command, not a native compilation test."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from verify_dsc_cargo_graph import REVISION, verify

SCRIPT = Path(__file__).resolve().parents[1] / "android/dsc-rust/build-android.sh"


class DscBuildCommandTest(unittest.TestCase):
    def run_wrapper(self, produce_library=True, patched=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ndk = root / "ndk"
            (ndk / "toolchains/llvm").mkdir(parents=True)
            output = root / "jni libs"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            log = root / "args.json"
            cargo = fake_bin / "cargo"
            cargo.write_text(
                "#!/usr/bin/env python3\n"
                "import os,sys,json,pathlib\n"
                "args=sys.argv[1:]\n"
                "if args == ['ndk','--version']: sys.exit(0)\n"
                "if args == ['metadata','--format-version','1','--filter-platform','aarch64-linux-android']:\n"
                " src='git+https://github.com/storytold/craft-libs?rev='+os.environ['DSC_TEST_REV']+'#'+os.environ['DSC_TEST_REV'] if os.environ['DSC_TEST_PATCHED']=='1' else 'registry+https://github.com/rust-lang/crates.io-index'\n"
                " print(json.dumps({'packages':[{'name':'hayro-syntax','version':'0.7.2','source':src}]})); sys.exit(0)\n"
                "assert args[:5] == ['ndk','--target','arm64-v8a','--platform','24'],args\n"
                "assert args[5] == '--output-dir' and args[7:] == ['build','--release','--locked'],args\n"
                "assert os.environ['ANDROID_NDK_HOME']==os.environ['ANDROID_NDK_ROOT']==os.environ['ANDROID_NDK']\n"
                "pathlib.Path(os.environ['DSC_TEST_LOG']).write_text(json.dumps(args))\n"
                "if os.environ['DSC_TEST_CREATE']=='1':\n"
                " p=pathlib.Path(args[6])/'arm64-v8a/libfileshare_dsc.so'\n"
                " p.parent.mkdir(parents=True,exist_ok=True)\n"
                " p.write_bytes(b'test-only placeholder')\n"
            )
            cargo.chmod(0o755)
            env = dict(os.environ, PATH=str(fake_bin)+os.pathsep+os.environ["PATH"],
                       ANDROID_NDK_HOME=str(ndk), ANDROID_NDK_ROOT="/old-ndk",
                       ANDROID_NDK="/other-ndk", DSC_TEST_LOG=str(log),
                       DSC_TEST_CREATE="1" if produce_library else "0",
                       DSC_TEST_REV=REVISION, DSC_TEST_PATCHED="1" if patched else "0")
            process = subprocess.run(["bash", str(SCRIPT), str(output)], env=env,
                                     capture_output=True, text=True)
            return process, json.loads(log.read_text()) if log.exists() else None

    def test_platform_flag_not_cargo_package_and_ndk_paths_agree(self):
        result, args = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[3:5], ["--platform", "24"])

    def test_missing_native_library_fails_build(self):
        result, _ = self.run_wrapper(False)
        self.assertNotEqual(result.returncode, 0)

    def test_wrong_parser_stops_before_compilation(self):
        result, args = self.run_wrapper(patched=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(args)
        self.assertIn("Incompatible parser dependency", result.stderr)

    def test_duplicate_registry_parser_is_rejected(self):
        pinned = "git+https://github.com/storytold/craft-libs?rev=" + REVISION + "#" + REVISION
        with self.assertRaisesRegex(ValueError, "Incompatible parser dependency"):
            verify({"packages": [
                {"name":"hayro-syntax","version":"0.7.2","source":pinned},
                {"name":"hayro-syntax","version":"0.7.2","source":"registry+https://github.com/rust-lang/crates.io-index"}
            ]})

    def test_cart_picker_callback_remains_last(self):
        root = SCRIPT.parents[2] / "android/app/src/main/kotlin/com/sammyi57/pdftools"
        signature = (root / "PdfSendPicker.kt").read_text().split("fun PdfSendPicker(", 1)[1].split("\n) {", 1)[0]
        self.assertTrue(signature.strip().endswith("onClose: () -> Unit,"))
        self.assertIn("preserveSigned: Boolean = false", signature)
        self.assertIn("expectedSignedHash: String? = null", signature)

    def test_existing_cart_callers_explicitly_bind_close_callback(self):
        root = SCRIPT.parents[2] / "android/app/src/main/kotlin/com/sammyi57/pdftools"
        for name in ("Scanner.kt", "ToolScreen.kt", "Viewer.kt"):
            source = (root / name).read_text()
            call = source.split("PdfSendPicker(", 1)[1]
            self.assertIn("onClose = {", call[:500], name)
        self.assertIn("expectedSignedHash = dsc?", (root / "Viewer.kt").read_text())


if __name__ == "__main__":
    unittest.main()
