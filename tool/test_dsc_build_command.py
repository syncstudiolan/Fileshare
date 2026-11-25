"""Offline regression for the cargo-ndk command, not a native compilation test."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "android/dsc-rust/build-android.sh"


class DscBuildCommandTest(unittest.TestCase):
    def run_wrapper(self, produce_library=True):
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
                "assert args[:5] == ['ndk','--target','arm64-v8a','--platform','24'],args\n"
                "assert args[5] == '--output-dir' and args[7:] == ['build','--release'],args\n"
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
                       DSC_TEST_CREATE="1" if produce_library else "0")
            process = subprocess.run(["bash", str(SCRIPT), str(output)], env=env,
                                     capture_output=True, text=True)
            return process, json.loads(log.read_text())

    def test_platform_flag_not_cargo_package_and_ndk_paths_agree(self):
        result, args = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[3:5], ["--platform", "24"])

    def test_missing_native_library_fails_build(self):
        result, _ = self.run_wrapper(False)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
