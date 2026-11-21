import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time


def signal_group(process, sig):
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        return False
    return True


def group_running(process):
    if process.poll() is None:
        return True
    if not signal_group(process, 0):
        return False
    # Orphaned children can be zombies until the system reaps them.
    try:
        listing = subprocess.check_output(
            ["ps", "-axo", "pgid=,stat="], text=True, timeout=0.5
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return True
    for line in listing.splitlines():
        group, state = line.split()
        if int(group) == process.pid and not state.startswith("Z"):
            return True
    return False


def stop_group(process, grace_seconds, cancellation_deadline):
    if not group_running(process):
        return True
    signal_group(process, signal.SIGINT)
    grace_deadline = time.monotonic() + grace_seconds
    kill_deadline = None
    while group_running(process):
        now = time.monotonic()
        if kill_deadline is None and now >= min(grace_deadline, cancellation_deadline()):
            signal_group(process, signal.SIGKILL)
            kill_deadline = now + 2
        elif kill_deadline is not None and now >= kill_deadline:
            return False
        time.sleep(0.1)
    return True


def finish_log(tee):
    try:
        return tee.wait(timeout=1)
    except subprocess.TimeoutExpired:
        # A writer may still hold the pipe outside the process group.
        tee.kill()
        tee.wait(timeout=1)
        return None


def run_validation(args, runner_temp, artifacts):
    cancelled_by = None
    cancel_deadline = float("inf")

    def cancel(signum, _frame):
        nonlocal cancelled_by, cancel_deadline
        if cancelled_by is None:
            cancelled_by = signal.Signals(signum)
            # Actions sends SIGTERM 7.5 seconds after SIGINT if the step is still running.
            cancel_deadline = time.monotonic() + 3
        else:
            cancel_deadline = time.monotonic()

    signal.signal(signal.SIGINT, cancel)
    signal.signal(signal.SIGTERM, cancel)
    started = time.monotonic()
    deadline = started + args.timeout_seconds
    command = args.command
    if command[0] == "--":
        command = command[1:]
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True
    )
    tee = None
    timed_out = False
    try:
        with process.stdout:
            tee = subprocess.Popen(
                ["tee", runner_temp / "xcodebuild.log"],
                stdin=process.stdout,
                start_new_session=True,
            )
        while cancelled_by is None and process.poll() is None:
            if time.monotonic() >= deadline:
                timed_out = True
                break
            time.sleep(0.1)
    finally:
        try:
            stopped = stop_group(process, args.grace_seconds, lambda: cancel_deadline)
        finally:
            log_exit = finish_log(tee) if tee is not None else None

    xcodebuild_exit = process.returncode
    interruption = None
    if cancelled_by is not None:
        status = 128 + cancelled_by
        interruption = f"received {cancelled_by.name}"
    elif timed_out:
        status = 124
        interruption = f"xcodebuild exceeded {args.timeout_seconds:g} seconds"
    elif xcodebuild_exit is None:
        status = 1
    elif xcodebuild_exit < 0:
        status = 128 - xcodebuild_exit
        interruption = f"xcodebuild received {signal.Signals(-xcodebuild_exit).name}"
    else:
        status = xcodebuild_exit
    processes_stopped = stopped and log_exit is not None
    if not processes_stopped:
        interruption = interruption or "process shutdown was not confirmed"
        status = status or 1
    elif log_exit != 0:
        interruption = interruption or f"log capture exited with {log_exit}"
        status = status or 1

    state = {
        "xcodebuild_exit_code": xcodebuild_exit,
        "validation_exit_code": status,
        "processes_stopped": processes_stopped,
        "interruption": interruption,
    }
    staging_status = runner_temp / "validation-status.json"
    staging_status.write_text(json.dumps(state, indent=2) + "\n")
    staging_status.replace(artifacts / staging_status.name)
    label = f"{os.environ['TIER']} / {os.environ['SIMULATOR_CLASS']}"
    if args.phase:
        label += f" / {args.phase}"
    summary = f"{label} build and test: {time.monotonic() - started:.0f} seconds (exit {status})"
    if interruption:
        summary += f"\nValidation interrupted: {interruption} (xcodebuild exit {xcodebuild_exit})"
    print(summary, flush=True)
    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary_path, "a") as output:
            print(summary, file=output)
    return status


def report(log, message):
    print(message, file=log, flush=True)
    print(message, flush=True)


def collect_evidence(runner_temp, artifacts):
    bundle = runner_temp / "TestResults.xcresult"
    status_path = artifacts / "validation-status.json"
    with (
        (artifacts / "result-collection.log").open("w") as log,
        tempfile.TemporaryDirectory(prefix="ios-evidence-", dir=runner_temp) as temporary,
    ):
        stage = Path(temporary)
        build_log = runner_temp / "xcodebuild.log"
        if build_log.is_file():
            # Publish a stable copy, including when Actions cut the build step short.
            snapshot = stage / build_log.name
            shutil.copyfile(build_log, snapshot)
            snapshot.replace(artifacts / snapshot.name)

        if not status_path.is_file() or not json.loads(status_path.read_text())["processes_stopped"]:
            report(log, "Validation interrupted: xcodebuild process shutdown was not confirmed.")
            return 1
        if not bundle.is_dir():
            report(log, "Validation interrupted: no result bundle was produced. See the setup and build logs.")
            return 1
        try:
            raw_summary = subprocess.check_output(
                ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle],
                stderr=log,
            )
            summary = json.loads(raw_summary)
        except (subprocess.CalledProcessError, ValueError) as error:
            report(log, f"Validation interrupted: result bundle summary is unreadable. {error}")
            return 1
        if not isinstance(summary, dict):
            report(log, "Validation interrupted: result bundle summary is not a JSON object.")
            return 1

        summary_path = stage / "test-summary.json"
        summary_path.write_bytes(raw_summary)
        summary_path.replace(artifacts / summary_path.name)
        try:
            # Archive outside the upload directory and publish only after tar finishes.
            archive = stage / (bundle.name + ".tar")
            subprocess.run(
                ["tar", "-cf", archive, "-C", bundle.parent, bundle.name],
                check=True, stdout=log, stderr=subprocess.STDOUT,
            )
            archive.replace(artifacts / archive.name)
            if os.environ["TIER"] != "fast":
                screenshots = stage / "Screenshots"
                subprocess.run(
                    ["xcrun", "xcresulttool", "export", "attachments", "--path", bundle,
                     "--output-path", screenshots],
                    check=True, stdout=log, stderr=subprocess.STDOUT,
                )
                if not any(path.is_file() for path in screenshots.rglob("*.png")):
                    report(log, "Result bundle exported no UI screenshots.")
                    return 1
                screenshots.replace(artifacts / screenshots.name)
        except (OSError, subprocess.CalledProcessError) as error:
            report(log, f"Validation interrupted while staging result evidence. {error}")
            return 1

        passed = summary.get("passedTests", 0)
        if not isinstance(passed, int) or passed < 1:
            report(log, "No passing tests recorded. Refusing empty validation.")
            return 1
        return 0


def main():
    parser = argparse.ArgumentParser()
    modes = parser.add_subparsers(dest="mode", required=True)
    run = modes.add_parser("run")
    run.add_argument("--timeout-seconds", type=float, required=True)
    run.add_argument("--grace-seconds", type=float, required=True)
    run.add_argument("--phase", choices=["startup"])
    run.add_argument("command", nargs=argparse.REMAINDER)
    collect = modes.add_parser("collect")
    collect.add_argument("--phase", choices=["startup"])
    args = parser.parse_args()
    runner_temp = Path(os.environ["RUNNER_TEMP"])
    artifacts = runner_temp / "CIArtifacts"
    if args.phase:
        runner_temp /= args.phase
        artifacts /= args.phase
        runner_temp.mkdir(exist_ok=True)
    artifacts.mkdir(parents=True, exist_ok=True)
    if args.mode == "run":
        if args.command in ([], ["--"]):
            run.error("missing xcodebuild command")
        return run_validation(args, runner_temp, artifacts)
    return collect_evidence(runner_temp, artifacts)


if __name__ == "__main__":
    raise SystemExit(main())
