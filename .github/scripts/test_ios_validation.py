import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest


SCRIPT = Path(__file__).with_name("ios-validation.py")
LONG_BUILD = """
from pathlib import Path
import signal
import subprocess
import sys
import time

def stop(*_args):
    print("graceful xcodebuild exit", flush=True)
    sys.exit(0)

signal.signal(signal.SIGINT, stop)
subprocess.Popen([sys.executable, "-c", '''
from pathlib import Path
import os, signal, sys, time
signal.signal(signal.SIGINT, signal.SIG_IGN)
ready = Path(sys.argv[1])
tmp = ready.with_suffix(".tmp")
tmp.write_text(f"{os.getpgrp()} {os.getpid()}")
tmp.replace(ready)
time.sleep(60)
''', sys.argv[1]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print("xcodebuild started", flush=True)
time.sleep(60)
"""
FAKE_XCRUN = """
import json
import os
from pathlib import Path
import sys

assert sys.argv[1] == "xcresulttool"
bundle = Path(sys.argv[sys.argv.index("--path") + 1])
assert bundle.is_dir()
if sys.argv[2] == "get":
    if (bundle / "Staging").is_dir():
        print("failed to read bundle metadata", file=sys.stderr)
        print("{", flush=True)
        sys.exit(1)
    print(json.dumps({"passedTests": int(os.environ.get("FAKE_PASSED_TESTS", "882"))}))
else:
    assert sys.argv[2:4] == ["export", "attachments"]
    output = Path(sys.argv[sys.argv.index("--output-path") + 1])
    output.mkdir()
    if not os.environ.get("FAKE_MISSING_SCREENSHOT"):
        (output / "hero.png").write_bytes(b"fake screenshot")
"""


class IOSValidationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.runner_temp = Path(temporary.name)
        self.artifacts = self.runner_temp / "CIArtifacts"
        self.bundle = self.runner_temp / "TestResults.xcresult"
        self.env = dict(
            os.environ,
            RUNNER_TEMP=temporary.name,
            TIER="full",
            SIMULATOR_CLASS="compact",
            GITHUB_STEP_SUMMARY=str(self.runner_temp / "summary.md"),
            PATH=f"{self.runner_temp}{os.pathsep}{os.environ['PATH']}",
        )

    def build_command(self, code, *arguments, timeout=10, grace=0.3, phase=None):
        return [
            sys.executable, SCRIPT, "run", "--timeout-seconds", str(timeout),
            "--grace-seconds", str(grace),
            *(["--phase", phase] if phase else []),
            "--", sys.executable, "-c", code, *arguments,
        ]

    def run_build(self, code, phase=None):
        return subprocess.run(
            self.build_command(code, phase=phase), env=self.env, capture_output=True, text=True, timeout=10
        )

    def status(self):
        return json.loads((self.artifacts / "validation-status.json").read_text())

    def start_long_build(self, timeout, grace):
        ready = self.runner_temp / "child"
        build = subprocess.Popen(
            self.build_command(LONG_BUILD, ready, timeout=timeout, grace=grace),
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )

        def cleanup():
            if build.poll() is None:
                build.terminate()
                try:
                    build.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    build.kill()
                    build.communicate(timeout=5)
            if ready.is_file():
                group, child = map(int, ready.read_text().split())
                if self.process_running(child):
                    try:
                        os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

        self.addCleanup(cleanup)
        return build, ready

    def process_running(self, pid):
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True, timeout=5
        )
        state = result.stdout.strip()
        return bool(state) and not state.startswith("Z")

    def fake_command(self, name, code):
        fake = self.runner_temp / name
        fake.write_text(f"#!{sys.executable}\n{code}")
        fake.chmod(0o755)

    def collect(self, phase=None):
        return subprocess.run(
            [sys.executable, SCRIPT, "collect", *(["--phase", phase] if phase else [])],
            env=self.env, capture_output=True, text=True, timeout=10,
        )

    def test_success_preserves_stdout_stderr_and_exit_status(self):
        result = self.run_build('import sys; print("stdout"); print("stderr", file=sys.stderr)')
        self.assertEqual(result.returncode, 0, result.stderr)
        log = (self.runner_temp / "xcodebuild.log").read_text()
        self.assertIn("stdout", log)
        self.assertIn("stderr", log)
        self.assertIn(log, result.stdout)
        self.assertEqual(self.status()["xcodebuild_exit_code"], 0)
        self.assertTrue(self.status()["processes_stopped"])

    def test_xcodebuild_failure_is_preserved(self):
        result = self.run_build('import sys; print("test failure"); sys.exit(65)')
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertEqual(self.status()["xcodebuild_exit_code"], 65)
        self.assertEqual(self.status()["validation_exit_code"], 65)
        self.assertIn("test failure", (self.runner_temp / "xcodebuild.log").read_text())

    def test_startup_failure_keeps_evidence_without_creating_full_results(self):
        result = self.run_build('import sys; print("app launch failed"); sys.exit(65)', phase="startup")
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertIn("full / compact / startup", result.stdout)
        startup_artifacts = self.artifacts / "startup"
        status = json.loads((startup_artifacts / "validation-status.json").read_text())
        self.assertEqual(status["validation_exit_code"], 65)
        self.assertTrue(status["processes_stopped"])

        self.fake_command("xcrun", FAKE_XCRUN)
        startup_bundle = self.runner_temp / "startup" / "TestResults.xcresult"
        startup_bundle.mkdir()
        (startup_bundle / "crash.txt").write_text("launch exception")
        self.env["FAKE_PASSED_TESTS"] = "0"
        self.env["FAKE_MISSING_SCREENSHOT"] = "1"
        evidence = self.collect(phase="startup")
        self.assertEqual(evidence.returncode, 1, evidence.stdout + evidence.stderr)
        self.assertEqual((startup_artifacts / "xcodebuild.log").read_text(), "app launch failed\n")
        with tarfile.open(startup_artifacts / "TestResults.xcresult.tar") as archive:
            self.assertEqual(archive.extractfile("TestResults.xcresult/crash.txt").read(), b"launch exception")
        self.assertEqual(json.loads((startup_artifacts / "test-summary.json").read_text())["passedTests"], 0)
        self.assertFalse((self.artifacts / "validation-status.json").exists())
        self.assertFalse(self.bundle.exists())

    def test_startup_and_full_validation_keep_independent_results(self):
        self.fake_command("xcrun", FAKE_XCRUN)
        self.env["FAKE_PASSED_TESTS"] = "1"
        self.assertEqual(self.run_build('print("startup passed")', phase="startup").returncode, 0)
        startup_bundle = self.runner_temp / "startup" / "TestResults.xcresult"
        startup_bundle.mkdir()
        (startup_bundle / "test.txt").write_text("startup")
        self.assertEqual(self.collect(phase="startup").returncode, 0)

        self.assertEqual(self.run_build('print("full suite passed")').returncode, 0)
        self.bundle.mkdir()
        (self.bundle / "test.txt").write_text("full")
        self.env["FAKE_PASSED_TESTS"] = "983"
        self.assertEqual(self.collect().returncode, 0)
        for phase, count, contents in [("startup", 1, b"startup"), ("", 983, b"full")]:
            with self.subTest(phase=phase):
                artifacts = self.artifacts / phase
                self.assertEqual(json.loads((artifacts / "test-summary.json").read_text())["passedTests"], count)
                with tarfile.open(artifacts / "TestResults.xcresult.tar") as archive:
                    self.assertEqual(archive.extractfile("TestResults.xcresult/test.txt").read(), contents)
                self.assertTrue((artifacts / "Screenshots" / "hero.png").is_file())
        self.assertEqual((self.artifacts / "startup" / "xcodebuild.log").read_text(), "startup passed\n")
        self.assertEqual((self.artifacts / "xcodebuild.log").read_text(), "full suite passed\n")

    def test_timeout_waits_for_child_and_fails_even_after_graceful_xcodebuild_exit(self):
        build, ready = self.start_long_build(timeout=2, grace=0.3)
        output, _ = build.communicate(timeout=8)
        self.assertEqual(build.returncode, 124, output)
        _, child = map(int, ready.read_text().split())
        self.assertFalse(self.process_running(child))
        self.assertEqual(self.status()["xcodebuild_exit_code"], 0)
        self.assertTrue(self.status()["processes_stopped"])
        self.assertIn("Validation interrupted: xcodebuild exceeded", output)
        self.assertIn("graceful xcodebuild exit", (self.runner_temp / "xcodebuild.log").read_text())

    def test_cancellation_waits_for_child_and_fails_validation(self):
        build, ready = self.start_long_build(timeout=30, grace=20)
        deadline = time.monotonic() + 5
        while not ready.is_file() and build.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(ready.is_file())
        _, child = map(int, ready.read_text().split())
        build.send_signal(signal.SIGINT)
        output, _ = build.communicate(timeout=7)
        self.assertEqual(build.returncode, 130, output)
        self.assertFalse(self.process_running(child))
        self.assertTrue(self.status()["processes_stopped"])
        self.assertIn("Validation interrupted: received SIGINT", output)

    def test_readable_bundle_is_archived_with_summary_and_screenshots(self):
        self.assertEqual(self.run_build('print("passed")').returncode, 0)
        self.fake_command("xcrun", FAKE_XCRUN)
        self.bundle.mkdir()
        (self.bundle / "Info.plist").write_text("result metadata")
        result = self.collect()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with tarfile.open(self.artifacts / "TestResults.xcresult.tar") as archive:
            self.assertIn("TestResults.xcresult/Info.plist", archive.getnames())
        self.assertEqual(json.loads((self.artifacts / "test-summary.json").read_text())["passedTests"], 882)
        self.assertTrue((self.artifacts / "Screenshots" / "hero.png").is_file())
        self.assertEqual((self.artifacts / "xcodebuild.log").read_text(), "passed\n")

    def test_incomplete_bundle_keeps_diagnostics_without_publishing_staging(self):
        self.assertEqual(self.run_build('import sys; print("interrupted build"); sys.exit(65)').returncode, 65)
        self.fake_command("xcrun", FAKE_XCRUN)
        staging = self.bundle / "Staging"
        staging.mkdir(parents=True)
        (staging / "temporary.txt").write_text("not finalized")
        result = self.collect()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual((self.artifacts / "xcodebuild.log").read_text(), "interrupted build\n")
        diagnostics = (self.artifacts / "result-collection.log").read_text()
        self.assertIn("failed to read bundle metadata", diagnostics)
        self.assertIn("Validation interrupted", diagnostics)
        for name in ("TestResults.xcresult", "TestResults.xcresult.tar", "test-summary.json", "Screenshots"):
            self.assertFalse((self.artifacts / name).exists())

    def test_archive_failure_keeps_logs_and_readable_summary(self):
        self.assertEqual(self.run_build('print("finished build")').returncode, 0)
        self.fake_command("xcrun", FAKE_XCRUN)
        self.fake_command("tar", """
import sys
from pathlib import Path
Path(sys.argv[2]).write_bytes(b"partial archive")
print("tar: result entry vanished", file=sys.stderr)
sys.exit(1)
""")
        self.bundle.mkdir()
        result = self.collect()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse((self.artifacts / "TestResults.xcresult.tar").exists())
        self.assertTrue((self.artifacts / "test-summary.json").is_file())
        self.assertEqual((self.artifacts / "xcodebuild.log").read_text(), "finished build\n")
        self.assertIn("result entry vanished", (self.artifacts / "result-collection.log").read_text())

    def test_missing_shutdown_status_keeps_logs_and_skips_result_collection(self):
        (self.runner_temp / "xcodebuild.log").write_text("output before the hard cutoff\n")
        self.fake_command("xcrun", FAKE_XCRUN)
        self.bundle.mkdir()
        result = self.collect()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual((self.artifacts / "xcodebuild.log").read_text(), "output before the hard cutoff\n")
        self.assertIn("process shutdown was not confirmed", result.stdout)
        self.assertFalse((self.artifacts / "test-summary.json").exists())
        self.assertFalse((self.artifacts / "TestResults.xcresult.tar").exists())

    def test_empty_summary_or_missing_screenshots_fails_collection(self):
        self.assertEqual(self.run_build("pass").returncode, 0)
        self.fake_command("xcrun", FAKE_XCRUN)
        self.bundle.mkdir()
        self.env["FAKE_MISSING_SCREENSHOT"] = "1"
        result = self.collect()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("exported no UI screenshots", result.stdout)
        self.assertFalse((self.artifacts / "Screenshots").exists())

        del self.env["FAKE_MISSING_SCREENSHOT"]
        self.env["FAKE_PASSED_TESTS"] = "0"
        result = self.collect()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("No passing tests recorded", result.stdout)


if __name__ == "__main__":
    unittest.main()
