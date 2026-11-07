"""Section 10 acceptance through the real openkit route/import/roundtrip CLIs."""
import copy
import json
import os
from pathlib import Path
import uuid


def route_atc(cli, original, run, require, save_snapshot, only=None):
    data = copy.deepcopy(original)
    profile_a = data["profiles"][0]["id"]
    profile_b = "A1000000-0000-0000-0000-000000000002"
    empty_profile = "A1000000-0000-0000-0000-000000000003"
    missing_profile = "A1000000-0000-0000-0000-000000000099"
    data["profiles"] = [data["profiles"][0]]
    for pid, name in ((profile_b, "Synthetic Work"), (empty_profile, "Synthetic Empty")):
        profile = copy.deepcopy(data["profiles"][0])
        profile.update(id=pid, name=name, favorites=[], dataDirectoryName=name.replace(" ", "-"))
        data["profiles"].append(profile)
    first_space = copy.deepcopy(data["spaces"][0])
    first_space.update(profileID=profile_a, today=[], pinned=[])
    work_spaces = []
    for n in (2, 3):
        space = copy.deepcopy(first_space)
        space.update(id=f"A2000000-0000-0000-0000-00000000000{n}", profileID=profile_b,
                     title=f"Synthetic Work {n}")
        work_spaces.append(space)
    data["spaces"] = [first_space] + work_spaces
    a, b1, b2 = [s["id"] for s in data["spaces"]]

    def window(space, n, style="standard"):
        value = copy.deepcopy(original["windows"][0])
        value.update(id=f"A3000000-0000-0000-0000-00000000000{n}", focusedSpaceID=space,
                     selectedNodeBySpace={}, style=style)
        return value

    ordered = [window(b1, 1, "littleOpen"), window(a, 2), window(b2, 3), window(b1, 4)]
    data["windows"] = ordered
    data["defaultDestination"] = {"littleOpen": {}}

    def rule(destination):
        return {"id": str(uuid.uuid4()).upper(), "match": {"hostEquals": {"_0": "atc.example"}},
                "destination": destination}

    def decide(destination, later=None):
        data["routingRules"] = [rule(destination)] + ([rule(later)] if later else [])
        return json.loads(run(cli, "route", save_snapshot(data), "https://atc.example/",
                              "--external-little-open", "on", "--json"))

    recent_b = {"mostRecentSpace": {"profile": profile_b}}
    old_cli = os.environ.get("OPEN_ROUTE_OLD_CLI")
    if only in (None, "A18"):
        decision = decide(recent_b)
        require(decision["resolved"] == {"space": {"spaceID": b2, "profileID": profile_b}},
                "A18 Profile most-recent did not follow standard-window order")
        data["windows"] = [ordered[0], ordered[1], ordered[3], ordered[2]]
        require(decide(recent_b)["resolved"]["space"]["spaceID"] == b1, "A18 Profile window order frozen")
        data["windows"] = []
        require(decide(recent_b)["resolved"]["space"]["spaceID"] == b1, "A18 Profile model-order fallback")
        print("A18 Profile-scoped mostRecent and window/model order PASS")

    if only in (None, "A19"):
        data["windows"] = ordered
        for pid in (empty_profile, missing_profile):
            decision = decide({"mostRecentSpace": {"profile": pid}}, {"space": {"_0": a}})
            require(decision["traces"][0]["outcome"] == {"targetProfileMissing": {}}
                    and decision["resolved"]["space"]["spaceID"] == a
                    and decision["via"]["rule"]["index"] == 1, "A19 stale/empty Profile rule was not skipped")
        print("A19 Profile with no Space or missing Profile skipped PASS")

    if only in (None, "A20"):
        decision = decide({"littleOpen": {"profile": profile_b}})
        require(decision["resolved"] == {"littleOpen": {"profileHint": profile_b}}, "A20 Little Open lost Profile hint")
        require(decide({"littleOpen": {"profile": missing_profile}})["resolved"]
                == {"littleOpen": {"profileHint": profile_a}}, "A20 missing Little Open Profile did not fall back")
        require(decide({"littleOpen": {"profile": empty_profile}})["resolved"]
                == {"littleOpen": {"profileHint": empty_profile}}, "A20 existing empty Profile lost Little Open context")
        print("A20 Little Open Profile hint and stale fallback PASS")

    if only in (None, "A21"):
        for destination in ({"littleOpen": {}}, {"mostRecentSpace": {}}):
            data["routingRules"] = [rule(destination)]
            data["defaultDestination"] = destination
            directory = save_snapshot(data, "atc-nil-roundtrip")
            # The second save must be byte-identical, and nil payloads must stay {}.
            run(cli, "roundtrip", directory)
            file = Path(directory) / "State/browser.json"
            before = file.read_bytes()
            run(cli, "roundtrip", directory)
            current = json.loads(file.read_bytes())
            require(file.read_bytes() == before and current["defaultDestination"] == destination
                    and current["routingRules"][0]["destination"] == destination and current["schemaVersion"] == 1,
                    "A21 nil destination roundtrip bytes/schema changed")
            old_cli = os.environ.get("OPEN_ROUTE_OLD_CLI")
            if old_cli:
                run(old_cli, "roundtrip", directory)
                require(file.read_bytes() == before, "A21 old/new nil encodings differ")
        print("A21 nil payload and legacy file byte-identical roundtrip PASS")

    if only in (None, "A22"):
        if old_cli:
            for destination in (recent_b, {"littleOpen": {"profile": profile_b}}):
                data["routingRules"] = [rule(destination)]
                data["defaultDestination"] = destination
                directory = save_snapshot(data, "atc-old-decoder")
                run(cli, "roundtrip", directory)
                encoded = json.loads((Path(directory) / "State/browser.json").read_text())
                require(encoded["defaultDestination"] == destination
                        and encoded["routingRules"][0]["destination"] == destination,
                        "A22 new file did not retain Profile payloads before old-decoder load")
                # Real pre-S10 CLI must load the new schema-1 file without throwing.
                run(old_cli, "route", directory, "https://atc.example/", "--external-little-open", "on", "--json")
            print("A22 current-main decoder reads Profile payloads PASS")

    if only not in (None, "A23", "A24"):
        return

    source = Path("atc-arc-source").resolve()
    source.mkdir(exist_ok=True)
    source_profile = "A4000000-0000-0000-0000-000000000002"
    source_space = "A5000000-0000-0000-0000-000000000002"
    spaces = ["atc-default-space", {"id": "atc-default-space", "title": "Synthetic Default",
                                   "profile": {"default": True}, "containerIDs": []},
              source_space, {"id": source_space, "title": "Synthetic Work",
                             "profile": source_profile, "containerIDs": []}]
    sidebar = {"version": 1, "sidebar": {"containers": [{"global": {}},
               {"spaces": spaces, "items": [], "topAppsContainerIDs": []}]}}
    (source / "StorableSidebar.json").write_text(json.dumps(sidebar))
    (source / "StorableProfiles.json").write_text(json.dumps(
        {"profiles": [source_profile, {"id": source_profile, "name": "Synthetic Work", "directory": "SyntheticWork"}]}))

    def component(kind, pattern):
        return {"id": str(uuid.uuid4()), "componentType": {"urlMatch": {"_0": {kind: {}}, "_1": pattern}}}

    def arc_destination(outer, context, value=None):
        return {outer: {"_0": {context: {} if value is None else {"_0": value}}}}

    destinations = [
        arc_destination("space", "mostRecent"), arc_destination("space", "profile", source_profile),
        arc_destination("space", "space", source_space), arc_destination("littleArc", "mostRecent"),
        arc_destination("littleArc", "profile", source_profile), arc_destination("littleArc", "space", source_space),
        arc_destination("space", "unknown"), arc_destination("littleArc", "profile", "missing-profile")]
    rules = [{"id": str(uuid.uuid4()), "sourceComponents": [component("matches", f"case{i}.example")],
              "destination": dest} for i, dest in enumerate(destinations)]
    rules.append({"id": str(uuid.uuid4()), "sourceComponents": [
        component("matches", "https://example.invalid/docs"), component("contains", "example.invalid")],
        "destination": destinations[1]})
    (source / "StorableLinkRouting.json").write_text(json.dumps(
        {"version": 1, "rules": rules, "defaultDestination": destinations[4]}))
    output = Path("atc-arc-output").resolve()
    report = run(cli, "import-arc", "--arc-dir", str(source), "--out", str(output), "--counts-only")
    imported = json.loads((output / "State/browser.json").read_text())
    targets = [r["destination"] for r in imported["routingRules"]]
    expected = [{"mostRecentSpace": {}}, {"mostRecentSpace": {"profile": source_profile}},
                {"space": {"_0": source_space}}, {"littleOpen": {}},
                {"littleOpen": {"profile": source_profile}}, {"littleOpen": {"profile": source_profile}},
                {"mostRecentSpace": {}}, {"littleOpen": {}}]
    if only in (None, "A23"):
        require(targets[:8] == expected and imported["defaultDestination"] == expected[4],
                "A23 nested Arc destination context lost")
        require("routingDestinationFallbacks=2" in report, "A23 unknown destinations not counted")
        print("A23 all nested Arc destinations and counted unknown fallback PASS")
    if only in (None, "A24"):
        matches = [r["match"] for r in imported["routingRules"]]
        require(len(matches) == 10 and matches[0] == {"hostEquals": {"_0": "case0.example"}}
                and matches[8:] == [{"urlPrefix": {"_0": "https://example.invalid/docs"}},
                                   {"hostContains": {"_0": "example.invalid"}}]
                and targets[8:] == [expected[1], expected[1]] and len(targets) == 10,
                "A24 matches/contains or ordered multi-component import lost")
        run(cli, "roundtrip", str(output))
        print("A24 Arc matches/contains and multi-component import PASS")



if __name__ == "__main__":
    import runpy
    import sys
    import tempfile
    helper = runpy.run_path(str(Path(__file__).with_name("check.py")))
    cli = str(Path(sys.argv[1]).resolve())
    only = sys.argv[2] if len(sys.argv) > 2 else None
    if only is not None and only not in {f"A{i}" for i in range(18, 25)}:
        raise SystemExit("unknown ATC row")
    with tempfile.TemporaryDirectory(prefix="open-route-atc-") as root:
        os.chdir(root)
        original = helper["seed_snapshot"](cli, Path(root) / "seed")
        route_atc(cli, original, helper["run"], helper["require"], helper["save_snapshot"], only=only)
