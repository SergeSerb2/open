"""Real two-device macOS App end-to-end verification for Open Accounts & Sync."""
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time


def _start_sync_server(root: Path, data_dir: Path):
    dist = root / "SyncServer" / "dist" / "index.js"
    if not dist.is_file():
        # Compile with tsrs if dist/ was not emitted on this host yet.
        npx = shutil.which("npx") or "/opt/homebrew/bin/npx"
        build = subprocess.run(
            [npx, "--yes", "tsrs", "-p", str(root / "SyncServer" / "tsconfig.json")],
            cwd=str(root),
            capture_output=True,
            text=True,
            timeout=120,
        )
        if build.returncode != 0 or not dist.is_file():
            raise RuntimeError(f"SyncServer build failed: {build.stdout}\n{build.stderr}")

    node = shutil.which("node") or "/opt/homebrew/bin/node"
    env = dict(os.environ)
    env.update(
        {
            "OPEN_SYNC_HOST": "127.0.0.1",
            "OPEN_SYNC_PORT": "0",
            "OPEN_SYNC_DATA_DIR": str(data_dir),
            "OPEN_SYNC_AUTH_RATE_LIMIT": "600",
        }
    )
    proc = subprocess.Popen(
        [node, "--no-warnings", str(dist)],
        cwd=str(root / "SyncServer"),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    deadline = time.monotonic() + 15.0
    port = None
    assert proc.stdout is not None
    while time.monotonic() < deadline:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                err = proc.stderr.read() if proc.stderr else ""
                raise RuntimeError(f"SyncServer exited early ({proc.returncode}): {err}")
            time.sleep(0.05)
            continue
        if line.startswith("OPEN_SYNC_LISTENING "):
            info = json.loads(line.split(" ", 1)[1])
            port = int(info["port"])
            break
    if port is None:
        proc.terminate()
        raise RuntimeError("SyncServer did not print OPEN_SYNC_LISTENING in time")
    return proc, f"http://127.0.0.1:{port}"


def _stop_sync_server(proc):
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def run(factory, results, tmp, h, config="Debug"):
    root = Path(h.ROOT)
    server_dir = Path(tempfile.mkdtemp(prefix="open-sync-srv-", dir="/tmp"))
    mac_a_dir = Path(tempfile.mkdtemp(prefix="open-sync-a-", dir="/tmp"))
    mac_b_dir = Path(tempfile.mkdtemp(prefix="open-sync-b-", dir="/tmp"))
    server_proc = None
    mac_a = None
    mac_b = None

    def launch_device(user_data: Path, name: str):
        # Use a short /tmp path so the macOS AF_UNIX automation socket stays under 104 bytes.
        app = h.Open(
            config,
            "chrome",
            str(user_data),
            ["--use-mock-keychain", "--open-allow-mock-keychain-secrets"],
            str(Path(tmp) / f"sync-{name}.log"),
            urls=(),
            first_run=False,
        )
        h._OWNED_APPS.append(app)
        if getattr(h, "_ACTIVE_FOCUS_TRACKER", None) is not None:
            app.focus_tracker = h._ACTIVE_FOCUS_TRACKER
            h._ACTIVE_FOCUS_TRACKER.apps.append(app)
        return app

    def record(name, ok, **detail):
        results[name] = dict(ok=bool(ok), **detail)
        return bool(ok)

    old_file_creds = os.environ.get("OPEN_SYNC_FILE_CREDENTIALS")
    os.environ["OPEN_SYNC_FILE_CREDENTIALS"] = "1"
    try:
        server_proc, server_url = _start_sync_server(root, server_dir)
        record("server_started", bool(server_url), url=server_url)

        # 1. Launch Mac A with zero account -> verify signed-out status and lazy Settings deep link.
        mac_a = launch_device(mac_a_dir, "mac-a")
        status_a0 = mac_a.call("sync", action="status")
        record(
            "signed_out_initial",
            status_a0.get("ok") and not status_a0.get("isSignedIn") and not status_a0.get("hasBanner"),
            status=status_a0,
        )

        # Verify Account & Sync Settings section deep-link works cleanly.
        link_res = mac_a.call("settings-link", url="open://settings/account-sync/account")
        settings_ui = mac_a.call("settings-ui", metricsOnly=True)
        record(
            "settings_deep_link",
            bool(link_res.get("accepted")) and settings_ui.get("section") == "account-sync",
            response=link_res,
            section=settings_ui.get("section"),
        )

        # 2. Populate Mac A's real browser setup: Space, Pinned tab, Favorite, Today tab, Note, Keybinding.
        work_space_id = mac_a.call("space-create", title="Work Sync")
        assert work_space_id, "Failed to create Work Sync space"

        pinned_res = mac_a.call("open", url="https://example.com/pinned-sync")
        mac_a.call("pin", tab=pinned_res["id"])
        fav_res = mac_a.call("open", url="https://example.com/fav-sync")
        mac_a.call("favorite", tab=fav_res["id"])
        mac_a.call("open", url="https://example.com/today-sync")

        # Write a custom keybinding for a customizable command and reload so Mac A has non-default shortcuts.
        kb_path = mac_a_dir / "State" / "keybindings.json"
        kb_path.parent.mkdir(parents=True, exist_ok=True)
        kb_path.write_text(
            json.dumps(
                {
                    "version": 1,
                    "bindings": {
                        "new-note": {
                            "shortcuts": [{"key": "y", "modifiers": ["command", "shift"]}]
                        }
                    },
                }
            )
        )
        mac_a.call("reload-keybindings")

        # Create a real Note on Mac A and flush it to disk.
        mac_a.call("note", action="create")
        mac_a.call("note", action="type", field="body", text="Encrypted Sync Note Body")
        mac_a.call("note", action="flush")

        # Save snapshot before sign-up so every store is durable.
        mac_a.call("save")

        # 3. Sign up on Mac A -> verify Recovery Key and initial encrypted upload.
        email = "sync-e2e@example.com"
        password_1 = "Correct-Horse-Battery-1!"
        signup = mac_a.call(
            "sync",
            action="sign-up",
            serverURL=server_url,
            email=email,
            password=password_1,
            displayName="Mac A User",
        )
        recovery_key = signup.get("recoveryKey", "")
        rev_after_signup = signup.get("snapshot", {}).get("serverRevision", 0)
        record(
            "mac_a_sign_up",
            signup.get("ok")
            and bool(re.fullmatch(r"OPEN(-[A-Z2-7]{4}){13}", recovery_key))
            and rev_after_signup > 0,
            revision=rev_after_signup,
            recoveryKeyPrefix=recovery_key[:14],
        )

        # 4. Zero-knowledge proof on server SQLite database: zero plaintext leakage!
        db_file = next(server_dir.glob("*.sqlite*"), None)
        assert db_file is not None, f"No SQLite database found in {list(server_dir.iterdir())}"
        plain_leaks = []
        with sqlite3.connect(f"file:{db_file}?mode=ro", uri=True) as conn:
            rows = list(conn.execute("SELECT collection, record_id, ciphertext FROM sync_records"))
            record("server_has_encrypted_records", len(rows) >= 4, recordCount=len(rows))
            for col, rid, ct in rows:
                ct_str = ct.decode("latin1") if isinstance(ct, (bytes, bytearray)) else str(ct)
                for needle in ("Work Sync", "pinned-sync", "fav-sync", "today-sync", "Encrypted Sync Note Body"):
                    if needle in ct_str:
                        plain_leaks.append((col, rid, needle))
        record("zero_knowledge_no_plaintext", len(plain_leaks) == 0, leaks=plain_leaks)

        # 5. Launch Mac B with distinct local Space, test wrong password refusal, then sign in!
        mac_b = launch_device(mac_b_dir, "mac-b")
        mac_b.call("space-create", title="Local Only MacB")
        mac_b.call("save")

        bad_login = mac_b.call(
            "sync",
            action="sign-in",
            serverURL=server_url,
            email=email,
            password="Wrong-Password-999!",
        )
        record(
            "wrong_password_rejected",
            bad_login.get("ok") is False and bad_login.get("code") == "INVALID_CREDENTIALS",
            response=bad_login,
        )

        login_b = mac_b.call(
            "sync",
            action="sign-in",
            serverURL=server_url,
            email=email,
            password=password_1,
        )
        snap_b = login_b.get("snapshot", {})
        record(
            "mac_b_initial_choice_prompt_and_banner",
            login_b.get("ok")
            and login_b.get("outcome", {}).get("kind") == "needsInitialChoice"
            and snap_b.get("isAwaitingInitialChoice") is True
            and snap_b.get("hasBanner") is True,
            outcome=login_b.get("outcome"),
            hasBanner=snap_b.get("hasBanner"),
        )

        # 6. Complete initial sync on Mac B using default strategy (replaceLocal: take synced data first).
        applied = mac_b.call("sync", action="complete-initial-sync", strategy="replaceLocal")
        backups = list((mac_b_dir / "State" / "SyncBackups").glob("*")) if (mac_b_dir / "State" / "SyncBackups").is_dir() else []
        spaces_b = mac_b.call("spaces")
        work_space_b = next((s for s in spaces_b if s.get("title") == "Work Sync"), None)
        if work_space_b is not None:
            mac_b.call("space", space=work_space_b["id"])
        tabs_b = mac_b.call("tabs")
        kb_b = json.loads((mac_b_dir / "State" / "keybindings.json").read_text()) if (mac_b_dir / "State" / "keybindings.json").is_file() else {}
        notes_b = [p.read_text(errors="ignore") for p in (mac_b_dir / "Notes").glob("*.json")] if (mac_b_dir / "Notes").is_dir() else []
        space_titles_b = [s.get("title") for s in spaces_b]
        tab_urls_b = [t.get("url") for t in tabs_b]
        record(
            "mac_b_replace_local_backup_and_workspace",
            applied.get("ok")
            and len(backups) >= 1
            and "Work Sync" in space_titles_b
            and "Local Only MacB" not in space_titles_b
            and any("pinned-sync" in (u or "") for u in tab_urls_b)
            and any("fav-sync" in (u or "") for u in tab_urls_b)
            and any("today-sync" in (u or "") for u in tab_urls_b)
            and "new-note" in kb_b.get("bindings", {})
            and any("Encrypted Sync Note Body" in n for n in notes_b)
            and applied.get("snapshot", {}).get("hasBanner") is False,
            backupCount=len(backups),
            spaces=space_titles_b,
            tabCount=len(tabs_b),
            tabUrls=tab_urls_b,
            hasKeybinding="new-note" in kb_b.get("bindings", {}),
            noteCount=len(notes_b),
        )

        # 7. Real-time WebSocket wakeup: Mac A adds a new pinned tab -> pushes -> Mac B receives automatically!
        delta_res = mac_a.call("open", url="https://example.com/realtime-delta")
        mac_a.call("pin", tab=delta_res["id"])
        pushed = mac_a.call("sync", action="sync-now")
        target_rev = pushed.get("snapshot", {}).get("serverRevision", 0)
        waited = mac_b.call("sync", action="wait-revision", minRevision=target_rev, timeoutMs=15000)
        tabs_b_after = mac_b.call("tabs")
        record(
            "realtime_websocket_delta_sync",
            waited.get("ok")
            and target_rev > rev_after_signup
            and waited.get("reached") is True
            and any("realtime-delta" in (t.get("url") or "") for t in tabs_b_after),
            targetRevision=target_rev,
            reached=waited.get("reached"),
        )

        # 8. Tombstone deletion propagation: Mac A unpins and closes the realtime-delta tab -> syncs -> Mac B drops it!
        mac_a.call("pin", tab=delta_res["id"])
        mac_a.call("close", tab=delta_res["id"])
        pushed_del = mac_a.call("sync", action="sync-now")
        del_rev = pushed_del.get("snapshot", {}).get("serverRevision", 0)
        waited_del = mac_b.call("sync", action="wait-revision", minRevision=del_rev, timeoutMs=15000)
        tabs_b_post_del = mac_b.call("tabs")
        record(
            "tombstone_deletion_propagates",
            waited_del.get("ok")
            and del_rev > target_rev
            and waited_del.get("reached") is True
            and not any("realtime-delta" in (t.get("url") or "") for t in tabs_b_post_del),
            deleteRevision=del_rev,
        )

        # 9. Connected devices list, Password change, Recovery key flow, and Account deletion.
        devices_res = mac_a.call("sync", action="devices")
        record("connected_devices_listed", devices_res.get("ok") and len(devices_res.get("devices", [])) == 2, devices=devices_res.get("devices"))

        password_2 = "New-Strong-Password-2@"
        chg = mac_a.call("sync", action="change-password", currentPassword=password_1, newPassword=password_2, revokeOtherSessions=False)
        record("password_change", chg.get("ok") is True, response=chg)

        # Sign out Mac B and recover using the Recovery Key!
        mac_b.call("sync", action="sign-out")
        password_3 = "Recovered-Vault-Password-3#"
        rec = mac_b.call(
            "sync",
            action="recover",
            serverURL=server_url,
            email=email,
            recoveryKey=recovery_key,
            newPassword=password_3,
            strategy="replaceLocal",
        )
        spaces_b_rec = [s.get("title") for s in mac_b.call("spaces")]
        record(
            "recovery_key_restores_vault",
            rec.get("ok")
            and bool(re.fullmatch(r"OPEN(-[A-Z2-7]{4}){13}", rec.get("recoveryKey", "")))
            and "Work Sync" in spaces_b_rec,
            spaces=spaces_b_rec,
        )

        # Delete cloud account cleanly -> local browser data stays intact!
        deleted = mac_b.call("sync", action="delete-account", password=password_3)
        spaces_after_delete = [s.get("title") for s in mac_b.call("spaces")]
        record(
            "delete_account_keeps_local_data",
            deleted.get("ok")
            and deleted.get("snapshot", {}).get("isSignedIn") is False
            and "Work Sync" in spaces_after_delete,
            spaces=spaces_after_delete,
        )
    finally:
        if old_file_creds is None:
            os.environ.pop("OPEN_SYNC_FILE_CREDENTIALS", None)
        else:
            os.environ["OPEN_SYNC_FILE_CREDENTIALS"] = old_file_creds
        for inst in (mac_b, mac_a):
            if inst is not None and not inst.closed:
                inst.quit()
        _stop_sync_server(server_proc)
        for folder in (server_dir, mac_a_dir, mac_b_dir):
            shutil.rmtree(folder, ignore_errors=True)
