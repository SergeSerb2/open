#!/usr/bin/env python3
"""Exercise real openkit generation publication, migration and rejection paths."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading


def verify(cli, root):
    def require(value, reason):
        if not value:
            raise RuntimeError(reason)

    def sha(data):
        return hashlib.sha256(data).hexdigest()

    pin = next(line.split()[2] for line in (root / "Engine/fork/adblock/resources-pins.txt").read_text().splitlines()
               if line.startswith("resources.json "))
    vendor = root / "Vendor/adblock"
    require(sha((vendor / "resources.json").read_bytes()) == pin, "staged resources pin mismatch")
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            body = b"[Adblock Plus 2.0]\n! Synthetic generation-flow fixture\n||example.invalid/ad^\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("ETag", '"resources-flow-v1"')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="open-resources-flow-") as temporary:
            data = Path(temporary) / "data"
            directory = data / "Profiles/00000000-0000-0000-0000-000000000001/AdBlock/lists"
            env = dict(os.environ, OPEN_ADBLOCK_DEBUG_SOURCE_ROOT=f"http://127.0.0.1:{server.server_port}")

            def call(*args, expected=0, bundle=vendor, destination=data):
                command = [str(cli), "adblock", *args, "--dir", str(destination), "--bundled-dir", str(bundle)]
                print(f"command={command} load_before={os.getloadavg()}", flush=True)
                result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
                print(result.stdout, end="", flush=True)
                print(f"exit={result.returncode} load_after={os.getloadavg()}", flush=True)
                require(result.returncode == expected, f"CLI exited {result.returncode}, expected {expected}")
                return result.stdout

            def live():
                pointer = json.loads((directory / "current.json").read_text())
                generation = directory / "generations" / str(pointer["live"]["generation"])
                raw = (generation / "manifest.json").read_bytes()
                require(sha(raw) == pointer["live"]["manifestSHA256"], "manifest pointer hash mismatch")
                return pointer, generation, json.loads(raw)

            def check(label, ids):
                pointer, generation, manifest = live()
                require(set(manifest["state"]["enabledBlockLists"]) == ids, "resources changed enabled lists")
                entries = [entry for entry in manifest["files"] if entry["listID"] == "_resources"]
                require(len(entries) == 1, "generation must contain exactly one _resources entry")
                entry = entries[0]
                body = (generation / "resources.json").read_bytes()
                require(entry["file"] == "resources.json" and entry["sourceRevision"] == [pin]
                        and entry["sha256"] == sha(body) == pin and entry["bytes"] == len(body) == 142493
                        and entry["generation"] == manifest["generation"], "resources manifest receipt mismatch")
                print(f"PASS {label}: generation={manifest['generation']} entry={json.dumps(entry, sort_keys=True)}", flush=True)
                return pointer, generation, manifest

            defaults = {"EasyList", "EasyPrivacy"}
            cli_bundle = Path(temporary) / "cli-bundle"
            cli_bundle.mkdir()
            for name in ["easylist.txt", "easyprivacy.txt"]:
                shutil.copyfile(vendor / name, cli_bundle / name)
            call("bundle", destination=cli_bundle)
            require(sha((cli_bundle / "resources.json").read_bytes()) == pin, "CLI bundle omitted the resources payload")
            (cli_bundle / "resources.json").write_bytes(b"tampered")
            call("bundle", destination=cli_bundle)
            require(sha((cli_bundle / "resources.json").read_bytes()) == pin, "CLI bundle failed to repair resources from the app bundle")
            require("configure_verified=true" in call("status", bundle=cli_bundle, destination=Path(temporary) / "bundled-profile"),
                    "CLI bundle output cannot seed a fresh Profile")
            print("PASS CLI bundle copies/repairs pinned resources without a resource download", flush=True)
            require("resources=" + pin[:12] in call("status"), "debug info missing resource revision")
            check("fresh Profile", defaults)
            require(not requests, "offline first open fetched a list or resource")
            call("list", "EasyPrivacy", "off")
            check("list disabled", {"EasyList"})
            call("list", "EasyList", "off")
            check("no lists enabled", set())
            call("reset")
            check("reset", defaults)
            call("update")
            check("update", defaults)
            require(requests and all(path.endswith(".txt") for path in requests), "runtime fetched a non-list resource")

            pointer, generation, manifest = live()
            (generation / "resources.json").write_bytes(b"tampered")
            warning = call("status")
            require("_resources: size or SHA-256 mismatch" in warning and "quarantined" in warning,
                    "tampered generation was not rejected")
            require(not generation.exists(), "rejected generation remains live")
            check("tampered generation rejected; verified fallback", defaults)

            # A real pre-Step-7 generation has no reserved entry. Edit only this
            # synthetic fixture, then let the public open path migrate it offline.
            pointer, generation, manifest = live()
            manifest["files"] = [entry for entry in manifest["files"] if entry["listID"] != "_resources"]
            (generation / "resources.json").unlink()
            raw = json.dumps(manifest, sort_keys=True).encode()
            (generation / "manifest.json").write_bytes(raw)
            pointer["live"]["manifestSHA256"] = sha(raw)
            (directory / "current.json").write_text(json.dumps(pointer))
            old_number = manifest["generation"]
            old_lists = {entry["listID"]: entry["sha256"] for entry in manifest["files"]}
            before = len(requests)
            call("status")
            _, _, upgraded = check("legacy generation upgraded on open", defaults)
            require(upgraded["generation"] > old_number and len(requests) == before, "legacy upgrade fetched or did not publish")
            require({entry["listID"]: entry["sha256"] for entry in upgraded["files"] if entry["listID"] != "_resources"} == old_lists,
                    "legacy upgrade changed list bytes")

            pointer, generation, manifest = live()
            old_resource = b"[]"  # A valid receipt for a former app's resource bytes.
            (generation / "resources.json").write_bytes(old_resource)
            entry = next(entry for entry in manifest["files"] if entry["listID"] == "_resources")
            entry.update(bytes=len(old_resource), sha256=sha(old_resource), sourceRevision=[sha(old_resource)])
            raw = json.dumps(manifest, sort_keys=True).encode()
            (generation / "manifest.json").write_bytes(raw)
            pointer["live"]["manifestSHA256"] = sha(raw)
            (directory / "current.json").write_text(json.dumps(pointer))
            before = len(requests)
            call("status")
            _, _, refreshed = check("app resource pin refreshed on open", defaults)
            require(refreshed["generation"] > manifest["generation"] and len(requests) == before,
                    "app pin refresh fetched or did not publish")

            bad_bundle = Path(temporary) / "bad-bundle"
            shutil.copytree(vendor, bad_bundle, ignore=shutil.ignore_patterns("ubo-source", "ubo.tar.gz"))
            for label, body in [("tampered bundled bytes", b"[]"), ("oversized bundled bytes", b"x" * (4 * 1024 * 1024 + 1))]:
                (bad_bundle / "resources.json").write_bytes(body)
                output = call("status", expected=1, bundle=bad_bundle, destination=Path(temporary) / label)
                require("_resources: bundled size or SHA-256 pin mismatch" in output and "configure_verified=true" not in output,
                        "invalid bundled resources reached configure")
                print("PASS " + label + " refused before configure", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    print("adblock resources: all real CLI generation flows PASS", flush=True)


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
