#!/usr/bin/env python3
"""Bounded real-CLI SM6 sampling. Wrap --case check in /usr/bin/lockf.

Never builds or kills processes by name. Measurement hosts never order front.
"""

import argparse
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
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    args.out.mkdir(parents=True, exist_ok=False)
    burners, commands, samples = [], [], []
    receipt = {"load_requested": args.load, "case": args.case, "samples": samples,
               "burner_pids": [], "command_pids": [], "data_roots": [], "cleanup": False}

    # Catch termination as an exception so the same finally path cleans up.
    def interrupted(number, _frame):
        raise RuntimeError(f"proof interrupted by signal {number}")

    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, interrupted)
    try:
        if args.load == "high":
            cpus = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.activecpu"], text=True))
            if not 1 <= cpus <= 64:
                raise RuntimeError(f"unexpected active CPU count: {cpus}")
            for _ in range(2 * cpus):
                job = subprocess.Popen(["/usr/bin/yes"], stdin=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       start_new_session=True)
                burners.append(job)
                receipt["burner_pids"].append(job.pid)
        deadline = time.monotonic() + 120
        while True:
            load = os.getloadavg()[0]
            ready = load >= 15 if args.load == "high" else load <= 2
            print(f"load wait: requested={args.load} actual={load:.2f} ready={ready}", flush=True)
            if ready or time.monotonic() >= deadline:
                break
            time.sleep(5)
        receipt["load_target_reached"] = ready
        if not ready and args.load == "high":
            raise RuntimeError("load1 did not reach 15 within 120 s")
        if not ready:
            print("LOW TARGET NOT REACHED; samples retain actual load1", flush=True)
        for index in range(args.runs):
            with tempfile.TemporaryDirectory(prefix="open-sm6-proof-") as directory:
                root = Path(directory)
                receipt["data_roots"].append(str(root))
                (root / "tmp").mkdir()
                (root / "home").mkdir()
                env = dict(os.environ, TMPDIR=str(root / "tmp") + "/",
                           CFFIXED_USER_HOME=str(root / "home"))
                command = [str(binary), "sm6-measure"]
                expected = 0
                if args.case == "early-failure":
                    command.append("--fail-after-host")
                    expected = 1
                elif args.case == "check":
                    # Caller wraps this proof in lockf; Popen owns the actual CLI PID.
                    command = [str(binary), "check"]
                log = args.out / f"run-{index + 1}.log"
                with log.open("w") as stream:
                    job = subprocess.Popen(command, cwd=root, env=env, start_new_session=True,
                                           stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
                    commands.append(job)
                    receipt["command_pids"].append(job.pid)
                    try:
                        # The existing full suite also runs media flows; leave them visible.
                        deadline = time.monotonic() + (300 if args.case == "check" else 90)
                        while job.poll() is None:
                            if time.monotonic() >= deadline:
                                raise RuntimeError(f"CLI timeout; see {log}")
                            print(f"CLI {index + 1}/{args.runs} pid={job.pid} running, load1={os.getloadavg()[0]:.2f}", flush=True)
                            time.sleep(5 if args.case == "check" else 0.2)
                    finally:
                        stop_owned(job)
                output = log.read_text()
                for line in output.splitlines():
                    if "SM6" in line or "checks:" in line:
                        print(line, flush=True)
                if job.returncode != expected:
                    # Keep original gate failures visible in the receipt, without retrying.
                    raise RuntimeError(f"CLI exit {job.returncode}; expected {expected}; see run-{index + 1}.log")
                if args.case == "measure":
                    lines = [line.removeprefix("SM6_JSON ") for line in output.splitlines()
                             if line.startswith("SM6_JSON ")]
                    if len(lines) != 1:
                        raise RuntimeError("missing single SM6_JSON result")
                    sample = json.loads(lines[0])
                    if not sample["cleanup"] or sample["instructions"] <= 0:
                        raise RuntimeError("missing cleanup or positive counter evidence")
                    samples.append(sample)
                elif args.case == "early-failure":
                    if "SM6 cleanup hosts=0 visible=0" not in output or "SM6 forced failure after host" not in output:
                        raise RuntimeError("missing early-failure/host cleanup evidence")
        if samples:
            values = [sample["instructions"] for sample in samples]
            receipt["instructions"] = {"min": min(values), "median": statistics.median(values), "max": max(values)}
            print("instructions " + json.dumps(receipt["instructions"]), flush=True)
    finally:
        # Ignore another termination signal while reaping, but keep cleanup bounded.
        for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        failures = []
        for job in reversed(commands + burners):
            try:
                if job in burners and job.poll() is None:
                    command = subprocess.check_output(["/bin/ps", "-p", str(job.pid), "-o", "command="], text=True).strip()
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
