# Remote engine build (Siso + NativeLink on boat.dev Linux sandboxes)

Status: E3-0 proof (2026-11-11). The Mac (M5) only coordinates: Siso runs there, compile
actions run on Linux workers, links and other local steps stay on the Mac.

## Shape

```
M5: siso ninja ──► 127.0.0.1:50051 rr-proxy.py ──► N ssh -L tunnels ──► scheduler sandbox
                                                                          127.0.0.1:50051 CAS/AC/Execution
                                                                          127.0.0.1:50061 worker API
worker sandboxes: ssh -L tunnel to the scheduler (key restricted to those two ports)
                  nativelink worker (root) ─ clang_remote_wrapper ─ /opt/cr-clang (Linux clang)
```

- Nothing listens on a public port. The boat.dev HTTPS relay (Cloudflare) answers gRPC with
  HTTP 403, so the Mac uses SSH tunnels. One SSH stream moves about 6 MB/s at 150 ms RTT;
  `rr-proxy.py` spreads Siso's gRPC connections over several tunnels.
- Workers reach the scheduler over IPv6 through their own SSH tunnel. The worker key is
  authorized on the scheduler with `restrict,port-forwarding,permitopen=` for the two ports only.

## Files

| File | Role |
|---|---|
| `rewrapper_mac.cfg` | Copied to `buildtools/reclient_cfgs/chromium-browser-clang/` (git-ignored in Chromium). `build/config/siso/clang_mac.star` reads platform, inputs and `remote_wrapper` from it. |
| `clang_remote_wrapper` | Copied next to it. Runs on the worker; see the comments in the file. |
| `nativelink-scheduler.json5` | Scheduler, CAS and AC (no local worker). |
| `nativelink-worker.json5` | Remote worker. Bind-mounts the SDK, libc++ headers and host clang read-only per action (`experimental_readonly_input_mounts`); without this, building each action's input tree costs ~6 s and half the worker CPU. Edit the SDK path when the output dir or Xcode SDK changes. |
| `setup-node.sh` | Installs NativeLink 1.8.3 and Chromium's pinned Linux clang (both SHA-256 checked). |
| `build-nativelink.sh` | Builds NativeLink v1.8.3 with `MAX_BATCH_TOTAL_SIZE` = 4 MiB (upstream: 64 KiB, which makes Siso upload small files two per round trip). |
| `worker-up.sh` | Starts the worker tunnel loop and the worker. |
| `rr-proxy.py` | Round-robin TCP proxy on the Mac. |

## Correctness rules

Official Mac builds keep absolute paths (`clang_need_input_root_absolute_path=true`): debug
info and Clang module files (`module.pcm`) contain the exec root and the clang resource
directory. Remote objects match local ones byte for byte only if:

1. the action runs at the Mac's absolute source path (rbind mount in a private mount namespace);
2. the Linux clang binary is mounted over the Mac clang path, so the resource directory
   (`third_party/llvm-build/Release+Asserts/lib/clang/<v>`) is the Mac package's, from the
   action inputs;
3. the driver gets `-mlinker-version=1249`, the ld64 version baked into the Mac clang
   (`HOST_LINK_VERSION`). Without it, Objective-C code is compiled without selector stubs.

The GN args need `use_remoteexec = true` (it adds the SDK filegroups that Siso needs). It does
not change any compile command. The Mac also needs a real `python3` first on `PATH`: with
Xcode 27.2 the `/usr/bin/python3` shim fails when `SDKROOT` is the symlinked SDK path in the
output directory (local Rust build-script links fail otherwise).

## Operating notes

- Check every new worker's link to the scheduler before it takes work: 50 MB over SSH should
  take < 1.5 s (measure with the operator key, or time the worker's first fetch of the 315 MB
  PGO profile into `/opt/e3/data/cas`). One host gave 5 MB/s and stalled every action it
  received; delete such a sandbox and start another.
- Create sandboxes with `--no-env --no-monitoring`: boat.dev's monitoring agents use ~1 core.
- The worker key on the scheduler is `restrict,port-forwarding,command="/bin/false",permitopen=...`.
- Seed very large inputs into the CAS out of band (e.g. the 315 MB PGO profile: copy with
  parallel SSH streams to `/opt/e3/data/cas/d2/<sha256>-<size>-0`, then start NativeLink);
  one gRPC stream to the Mac moves only ~2 MB/s.
- `-strict_remote` keeps Siso from compiling locally when a remote action fails.

## Not in this directory

Keys, host keys, tunnel URLs and logs live in the engine worktree's `.re/e3/` (git-ignored).
