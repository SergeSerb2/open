#!/usr/bin/env python3
"""Bounded real-CLI SM6 sampling. Wrap --case check in /usr/bin/lockf.

Never builds or kills processes by name. Measurement hosts never order front.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import tempfile
import time


def bounded_integer(text):
    value = int(text)
    if not 1 <= value <= 5:
        raise argparse.ArgumentTypeError("runs must be in 1...5")
    return value


def stop_owned(job):
    # Popen still owns this unreaped child, so its PID cannot have been reused.
    if job.poll() is None:
        job.terminate()
        try:
            job.wait(timeout=5)
        except subprocess.TimeoutExpired:
            job.kill()
            job.wait(timeout=5)
    else:
        job.wait()
    try:
        os.kill(job.pid, 0)
    except ProcessLookupError:
        return
    raise RuntimeError(f"owned PID {job.pid} still exists after wait")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--load", choices=("low", "high"), required=True)
    parser.add_argument("--case", choices=("measure", "early-failure", "check"), default="measure")
    parser.add_argument("--runs", type=bounded_integer, default=5)
    parser.add_argument("--thread-probe", action="store_true",
                        help="M1 single probe campaign; hard stop 2026-10-27T04:35:40Z, including prior work")
    parser.add_argument("--calibration", action="store_true",
                        help="Lead-authorized fixed calibration: one discarded process, then five fresh processes")
    args = parser.parse_args()
    if args.calibration and (args.thread_probe or args.case != "measure" or args.runs != 5):
        parser.error("--calibration requires five measure runs and cannot reopen --thread-probe")
    if args.thread_probe and args.case != "measure":
        parser.error("--thread-probe requires --case measure")
    binary = args.binary.resolve(strict=True)
    # Convert the binding absolute deadline once; clock changes cannot extend it.
    probe_seconds = (datetime(2026, 10, 27, 4, 35, 40, tzinfo=timezone.utc) - datetime.now(timezone.utc)).total_seconds()
    probe_end = time.monotonic() + min(45 * 60, probe_seconds) - 15 if args.thread_probe else float("inf")
    operation_end = min(probe_end, time.monotonic() + 600 if args.calibration else float("inf"))

    def remaining():
        value = operation_end - time.monotonic()
        if value <= 0:
            if args.calibration:
                raise RuntimeError("fixed calibration timeout; retain structural fallback; do not repeat")
            raise RuntimeError("thread-instruction probe deadline reached; stop probing, structural-only gate")
        return value

    remaining()
    args.out.mkdir(parents=True, exist_ok=False)
    burners, commands, samples = [], [], []
    receipt = {"load_requested": args.load, "case": args.case, "samples": samples,
               "burner_pids": [], "command_pids": [], "data_roots": [], "cleanup": False}
    receipt["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    receipt["repository_head"] = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=Path(__file__).resolve().parents[1], text=True, timeout=5).strip()
    receipt["thread_probe"] = args.thread_probe
    receipt["fixed_calibration"] = args.calibration
    receipt["discarded_warmup_processes"] = 1 if args.calibration else 0
    receipt["machine"] = {key: subprocess.check_output(["/usr/sbin/sysctl", "-n", name], text=True, timeout=5).strip()
                          for key, name in (("cpuBrand", "machdep.cpu.brand_string"), ("osBuild", "kern.osversion"))}
    receipt["probe_remaining_seconds_at_start"] = remaining() if args.thread_probe else None

    # Catch termination as an exception so the same finally path cleans up.
    def interrupted(number, _frame):
        raise RuntimeError(f"proof interrupted by signal {number}")

    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, interrupted)
    try:
        if args.load == "high":
            cpus = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.activecpu"], text=True, timeout=5))
            if not 1 <= cpus <= 64:
                raise RuntimeError(f"unexpected active CPU count: {cpus}")
            for _ in range(2 * cpus):
                job = subprocess.Popen(["/usr/bin/yes"], stdin=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       start_new_session=True)
                burners.append(job)
                receipt["burner_pids"].append(job.pid)
        deadline = min(time.monotonic() + 120, operation_end)
        while True:
            remaining()
            load = os.getloadavg()[0]
            ready = load >= 15 if args.load == "high" else load <= 2
            print(f"load wait: requested={args.load} actual={load:.2f} ready={ready}", flush=True)
            if ready or time.monotonic() >= deadline:
                break
            time.sleep(min(5, remaining()))
        receipt["load_target_reached"] = ready
        if not ready and args.load == "high":
            raise RuntimeError("load1 did not reach 15 within 120 s")
        if not ready:
            print("LOW TARGET NOT REACHED; samples retain actual load1", flush=True)
        # Calibration was declared before launch. Only index zero is discarded.
        indices = range(0, 6) if args.calibration else range(1, args.runs + 1)
        for index in indices:
            remaining()
            with tempfile.TemporaryDirectory(prefix="open-sm6-proof-") as directory:
                root = Path(directory)
                receipt["data_roots"].append(str(root))
                (root / "tmp").mkdir()
                (root / "home").mkdir()
                env = dict(os.environ, TMPDIR=str(root / "tmp") + "/",
                           CFFIXED_USER_HOME=str(root / "home"))
                command = [str(binary), "sm6-measure"]
                if args.thread_probe or args.calibration:
                    command.append("--thread-instructions")
                expected = 0
                if args.case == "early-failure":
                    command.append("--fail-after-host")
                    expected = 1
                elif args.case == "check":
                    # Caller wraps this proof in lockf; Popen owns the actual CLI PID.
                    command = [str(binary), "check"]
                log = args.out / f"run-{index}.log"
                with log.open("w") as stream:
                    job = subprocess.Popen(command, cwd=root, env=env, start_new_session=True,
                                           stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
                    commands.append(job)
                    receipt["command_pids"].append(job.pid)
                    try:
                        # The existing full suite also runs media flows; leave them visible.
                        deadline = min(time.monotonic() + (300 if args.case == "check" else 90), operation_end)
                        while job.poll() is None:
                            remaining()
                            if time.monotonic() >= deadline:
                                raise RuntimeError(f"CLI timeout; see {log}")
                            print(f"CLI index={index} pid={job.pid} running, load1={os.getloadavg()[0]:.2f}", flush=True)
                            time.sleep(min(5 if args.case == "check" else 0.2, remaining()))
                    finally:
                        stop_owned(job)
                output = log.read_text()
                for line in output.splitlines():
                    if "SM6" in line or "checks:" in line:
                        print(line, flush=True)
                if job.returncode != expected:
                    # Keep original gate failures visible in the receipt, without retrying.
                    raise RuntimeError(f"CLI exit {job.returncode}; expected {expected}; see run-{index}.log")
                if args.case == "measure":
                    lines = [line.removeprefix("SM6_JSON ") for line in output.splitlines()
                             if line.startswith("SM6_JSON ")]
                    if len(lines) != 1:
                        raise RuntimeError("missing single SM6_JSON result")
                    sample = json.loads(lines[0])
                    metric = sample.get("mainThreadInstructions") if args.thread_probe or args.calibration else sample.get("instructions")
                    if not sample["cleanup"] or not metric or metric <= 0:
                        if args.thread_probe or args.calibration:
                            raise RuntimeError(f"thread instructions {sample.get('mainThreadStatus', 'unavailable')}; fixed calibration invalid" if args.calibration else f"thread instructions {sample.get('mainThreadStatus', 'unavailable')}; stop probing, structural-only gate")
                        raise RuntimeError("missing cleanup or positive counter evidence")
                    if args.calibration and index == 0:
                        receipt["discarded_warmup"] = sample
                        print("DISCARDED predeclared warm-up index=0", flush=True)
                    else:
                        samples.append(sample)
                elif args.case == "early-failure":
                    if "SM6 cleanup hosts=0 visible=0" not in output or "SM6 forced failure after host" not in output:
                        raise RuntimeError("missing early-failure/host cleanup evidence")
        if samples:
            values = [sample.get("instructions") for sample in samples]
            if all(value and value > 0 for value in values):
                receipt["instructions"] = {"min": min(values), "median": statistics.median(values), "max": max(values)}
                print("instructions " + json.dumps(receipt["instructions"]), flush=True)
            else:
                receipt["instructions"] = {"status": "unavailable; diagnostic only"}
            if args.thread_probe or args.calibration:
                values = [sample["mainThreadInstructions"] for sample in samples]
                median = statistics.median(values)
                receipt["main_thread_instructions"] = {"min": min(values), "median": median, "max": max(values),
                                                        "range_over_median": (max(values) - min(values)) / median}
                print("main-thread instructions " + json.dumps(receipt["main_thread_instructions"]), flush=True)
    finally:
        # Ignore another termination signal while reaping, but keep cleanup bounded.
        for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        failures = []
        for job in reversed(commands + burners):
            try:
                if job in burners and job.poll() is None:
                    command = subprocess.check_output(["/bin/ps", "-p", str(job.pid), "-o", "command="], text=True, timeout=5).strip()
                    if command != "/usr/bin/yes":
                        raise RuntimeError(f"owned burner PID {job.pid} changed command: {command}")
                stop_owned(job)
            except Exception as error:
                failures.append(str(error))
        for directory in receipt["data_roots"]:
            if Path(directory).exists():
                failures.append(f"data root remains: {directory}")
        receipt["cleanup"] = not failures
        receipt["cleanup_errors"] = failures
        (args.out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(f"cleanup: {len(burners)} owned burners and {len(commands)} commands reaped; errors={failures}", flush=True)
        if failures:
            raise RuntimeError("; ".join(failures))


if __name__ == "__main__":
    main()
