#!/usr/bin/env python3
"""Run Home icon regressions and capture the simulator matrix on macOS.

Run from the repository root. Each run creates two test simulators and records
its Git revision, command statuses, and evidence in a temporary results folder.
"""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile


PROJECT = "BabySleepTracker.xcodeproj"
SCHEME = "BabySleepTracker"
DEVICES = {
    "iphone-16-pro": "iPhone-16-Pro",
    "iphone-se-3": "iPhone-SE-3rd-generation",
}
CAPTURE_TESTS = [
    "BabySleepTrackerUITests/TodayPlanUITests/testHomeIconWakeScreenshots",
    "BabySleepTrackerUITests/HomeDashboardCardUITests/testHomeIconDaysAndCoachScreenshots",
]
FOCUSED_TESTS = [
    "BabySleepTrackerTests/HomeDashboardCardTests",
    "BabySleepTrackerUITests/TodayPlanUITests",
    "BabySleepTrackerUITests/HomeDashboardCardUITests",
    "BabySleepTrackerUITests/TodaySleepHeroUITests/testNapEndRequiresSaveAndBreakKeepsParentRoute",
    "BabySleepTrackerUITests/TodaySleepHeroUITests/testFinishNapSheetRemainsUsableInDarkModeAtAccessibilitySize",
    "BabySleepTrackerUITests/PrivacyUITests/testLaunchShowsHome",
]
PHASES = {
    "focused": ("NO", FOCUSED_TESTS),
    "full": ("YES", []),
    "capture": ("NO", CAPTURE_TESTS),
}
SCREENSHOTS = {
    f"HOME-ICONS-{scene}-{appearance}-{size}"
    for scene in (
        "completed-event-icons", "reference", "overnight-routine", "overnight-estimate", "carryover",
        "days-staleNight", "coach-fallback", "coach-loading", "coach-response",
    )
    for appearance in ("light", "dark")
    for size in ("default", "accessibility-xxxl")
}
ARGUMENTS_FOR_SIGNING = [
    "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES",
    "CODE_SIGNING_REQUIRED=NO", "AD_HOC_CODE_SIGNING_ALLOWED=YES",
    "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE_SPECIFIER=",
]


def run_logged(command, log_path, *, stdout_path=None, env=None):
    print(f"Çalışıyor {log_path}", flush=True)
    with log_path.open("w", encoding="utf-8") as log, ExitStack() as handles:
        print(shlex.join(command), file=log, flush=True)
        output = handles.enter_context(stdout_path.open("wb")) if stdout_path else log
        try:
            code = subprocess.run(command, stdout=output, stderr=log, env=env, check=False).returncode
        except OSError as error:
            print(error, file=log)
            code = 127
        print(f"exit_status={code}", file=log)
    print(f"Çıkış {code} · {log_path.name}", flush=True)
    return code


def export_results(bundle, folder, phase):
    summary_path = folder / "test-summary.json"
    phase["summary_exit"] = run_logged(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
        folder / "summary.log", stdout_path=summary_path,
    )
    phase["attachments_exit"] = run_logged(
        ["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
         "--output-path", str(folder / "attachments")],
        folder / "attachments.log",
    )
    if phase["xcodebuild_exit"]:
        phase["diagnostics_exit"] = run_logged(
            ["xcrun", "xcresulttool", "export", "diagnostics", "--path", str(bundle),
             "--output-path", str(folder / "diagnostics")],
            folder / "diagnostics.log",
        )
    if phase["summary_exit"] == 0:
        try:
            summary = json.loads(summary_path.read_text())
            phase["passed_tests"] = summary["passedTests"]
            phase["failed_tests"] = summary["failedTests"]
        except (ValueError, KeyError, TypeError) as error:
            phase["summary_error"] = str(error)


def copy_screenshots(attachments, destination):
    missing = set(SCREENSHOTS)
    manifest = attachments / "manifest.json"
    if not manifest.is_file():
        return sorted(missing)
    entries = json.loads(manifest.read_text())
    for test in entries:
        for attachment in test.get("attachments", []):
            title = attachment.get("suggestedHumanReadableName") or ""
            filename = attachment.get("exportedFileName") or ""
            if not filename or Path(filename).name != filename:
                continue
            source = attachments / filename
            if source.suffix.lower() != ".png" or not source.is_file():
                continue
            name = next((stem for stem in sorted(missing)
                         if title in (stem, f"{stem}.png") or title.startswith(f"{stem}_")), None)
            if name:
                with source.open("rb") as image:
                    if image.read(8) != b"\x89PNG\r\n\x1a\n":
                        continue
                destination.mkdir(exist_ok=True)
                shutil.copyfile(source, destination / f"{name}.png")
                missing.remove(name)
    return sorted(missing)


def run_tests(phase_name, folder, destination, project_args, phase):
    folder.mkdir()
    coverage, selection = PHASES[phase_name]
    bundle = folder / "Tests.xcresult"
    env = os.environ.copy()
    env.pop("TEST_RUNNER_HOME_ICON_SCREENSHOTS", None)
    if phase_name == "capture":
        env["TEST_RUNNER_HOME_ICON_SCREENSHOTS"] = "1"
    phase["xcodebuild_exit"] = run_logged(
        ["xcodebuild", "test", *project_args, "-configuration", "Debug", "-sdk", "iphonesimulator",
         "-destination", f"platform=iOS Simulator,id={destination}", "-parallel-testing-enabled", "NO",
         "-disableAutomaticPackageResolution", "-enableCodeCoverage", coverage, "-resultBundlePath", str(bundle),
         *(f"-only-testing:{test}" for test in selection), *ARGUMENTS_FOR_SIGNING],
        folder / "xcodebuild.log", env=env,
    )
    if bundle.is_dir():
        export_results(bundle, folder, phase)
    phase["status"] = "failed"
    if (phase["xcodebuild_exit"] == 0 and type(phase.get("passed_tests")) is int
            and phase["passed_tests"] > 0 and phase.get("failed_tests") == 0):
        phase["status"] = "passed"


def validate(args, output, report):
    setup = report["setup_exit_codes"]
    project = ["-project", PROJECT, "-scheme", SCHEME]
    project_args = [
        *project, "-derivedDataPath", str(output / "DerivedData"),
        "-clonedSourcePackagesDirPath", str(output / "SourcePackages"),
        "-onlyUsePackageVersionsFromResolvedFile",
    ]
    setup["xcodebuild_version"] = run_logged(["xcodebuild", "-version"], output / "toolchain.log")
    setup["simulator_runtimes"] = run_logged(
        ["xcrun", "simctl", "list", "runtimes", "--json"],
        output / "runtimes.log", stdout_path=output / "runtimes.json",
    )
    setup["package_resolution"] = run_logged(
        ["xcodebuild", "-resolvePackageDependencies", *project_args], output / "packages.log",
    )
    setup["xcodebuild_list"] = run_logged(
        ["xcodebuild", "-list", "-project", PROJECT, "-disableAutomaticPackageResolution"],
        output / "schemes.log",
    )
    setup["xcodebuild_showdestinations"] = run_logged(
        ["xcodebuild", "-showdestinations", *project_args, "-disableAutomaticPackageResolution"],
        output / "destinations.log",
    )
    if setup["xcodebuild_version"] or setup["package_resolution"]:
        return False

    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-" + args.runtime.replace(".", "-")
    success = all(code == 0 for code in setup.values())
    for key, device in DEVICES.items():
        folder = output / key
        folder.mkdir()
        status = report["devices"][key]
        # These launches reseed app records. Allocate a simulator owned by this run.
        id_path = folder / "simulator-udid.txt"
        status["create_exit"] = run_logged(
            ["xcrun", "simctl", "create", f"SleepCoach Home Icons {device} {output.name}",
             f"com.apple.CoreSimulator.SimDeviceType.{device}", runtime],
            folder / "create.log", stdout_path=id_path,
        )
        udid = id_path.read_text().strip()
        if status["create_exit"] or not udid:
            success = False
            continue
        status["simulator_udid"] = udid
        try:
            status["boot_exit"] = run_logged(
                ["xcrun", "simctl", "bootstatus", udid, "-b"], folder / "boot.log",
            )
            if status["boot_exit"]:
                success = False
                continue
            for phase_name in PHASES:
                phase = status["native_tests"][phase_name]
                run_tests(phase_name, folder / phase_name, udid, project_args, phase)
                if phase["status"] != "passed" or phase.get("attachments_exit") != 0:
                    success = False
            try:
                missing = copy_screenshots(folder / "capture" / "attachments", folder / "screenshots")
            except (OSError, ValueError, AttributeError, TypeError) as error:
                status["screenshots"]["error"] = str(error)
                missing = sorted(SCREENSHOTS)
            status["screenshots"].update(
                status="pending" if missing else "captured",
                captured_count=len(SCREENSHOTS) - len(missing), missing=missing,
            )
            if missing:
                success = False
        finally:
            status["shutdown_exit"] = run_logged(["xcrun", "simctl", "shutdown", udid], folder / "shutdown.log")
    return success


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", default="18.5", help="Installed iOS Simulator version (default: 18.5)")
    args = parser.parse_args()
    if platform.system() != "Darwin" or not shutil.which("xcodebuild") or not shutil.which("xcrun"):
        print("Native testler, ekran görüntüleri ve manuel VoiceOver kontrolü bekliyor. macOS ve Xcode gerekli.")
        return 2
    if not Path(PROJECT).is_dir():
        parser.error("Betiği depo kökünden çalıştırın.")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()

    output = Path(tempfile.mkdtemp(prefix="sleepcoach-home-icons-"))
    print(f"Sonuçlar {output}", flush=True)
    (output / "git-status.txt").write_bytes(subprocess.check_output(
        ["git", "--no-optional-locks", "status", "--porcelain=v2", "--branch", "--untracked-files=all"],
    ))
    report = {
        "git_head": head,
        "ios_runtime": args.runtime,
        "setup_exit_codes": {},
        "devices": {
            key: {
                "native_tests": {phase: {"status": "pending", "xcodebuild_exit": None} for phase in PHASES},
                "screenshots": {"status": "pending", "captured_count": 0, "missing": sorted(SCREENSHOTS)},
            }
            for key in DEVICES
        },
        "manual_voiceover": {"status": "pending"},
    }
    success = False
    try:
        success = validate(args, output, report)
    finally:
        report["overall_exit"] = 0 if success else 1
        (output / "validation-status.json").write_text(json.dumps(report, indent=2) + "\n")
        for device, state in report["devices"].items():
            phases = ", ".join(f"{name}={phase['status']}" for name, phase in state["native_tests"].items())
            count = state["screenshots"]["captured_count"]
            print(f"{device} · {phases} · ekran görüntüsü {count}/{len(SCREENSHOTS)}")
        print(f"Manuel VoiceOver kontrolü bekliyor. Sonuç dosyası {output / 'validation-status.json'}")
    return report["overall_exit"]


if __name__ == "__main__":
    raise SystemExit(main())
