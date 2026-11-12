"""Chrome's startup-complete signal in Open (LEAD 2026-11-12 09:15).

Chrome queues BEST_EFFORT tasks (AfterStartupTaskUtils) until it declares
browser startup complete. Each row launches Open on a fresh data root and reads
two of Chrome's own histograms from chrome://histograms:
  Startup.BrowserStartupCompleteReason   why startup completed (0 = 3-minute failsafe)
  Startup.AfterStartupTaskDelayedUntilTime   ms from process creation to that moment,
    when the queued BEST_EFFORT tasks (Startup.AfterStartupTaskCount) were released.
The row passes when startup completed for a real reason within LIMIT_MS of the
App's first paint (LaunchTiming, same process-start origin).

The histogram tab opens only after WAIT_S, so it cannot be the page that
completes startup in time.
"""
import re
import time

LIMIT_MS = 8000
WAIT_S = 12
# StartupIsCompleteReason (chrome/browser/after_startup_task_utils.h).
REASONS = {0: "kFailsafeTimeout", 7: "kVisiblePageLoadingFinished",
           8: "kVisiblePageLoadingTimedOut", 9: "kNoVisiblePageFound"}


def _histograms(app, new_tab, wait_until):
    tab = new_tab(app, "chrome://histograms/Startup.")
    try:
        names = ("Startup.BrowserStartupCompleteReason", "Startup.AfterStartupTaskDelayedUntilTime",
                 "Startup.AfterStartupTaskCount")
        out = {}
        def read():
            text = app.eval(tab, "document.body.innerText") or ""
            for name in names:
                m = re.search(re.escape(name) + r" recorded (\d+) samples, mean = ([\d.]+)", text)
                out[name] = {"samples": int(m.group(1)), "mean": float(m.group(2))} if m else None
            return "Histogram:" in text
        wait_until(read, timeout=10, step=0.5)
        return out
    finally:
        app.call("close", tab=tab)


def _row(app, new_tab, wait_until, paint_key, expected_reasons):
    wait_until(lambda: paint_key in app.call("timing"), timeout=15, step=0.1)
    timing = app.call("timing")
    time.sleep(max(0, WAIT_S - timing.get(paint_key, 0) / 1000))
    hist = _histograms(app, new_tab, wait_until)
    reason = hist["Startup.BrowserStartupCompleteReason"]
    delayed = hist["Startup.AfterStartupTaskDelayedUntilTime"]
    count = hist["Startup.AfterStartupTaskCount"]
    paint = timing.get(paint_key)
    after_paint = delayed["mean"] - paint if delayed and paint is not None else None
    return {"ok": bool(reason and reason["samples"] == 1 and int(reason["mean"]) in expected_reasons
                       and after_paint is not None and after_paint <= LIMIT_MS and count and count["samples"] == 1),
            "reason": REASONS.get(int(reason["mean"]), reason["mean"]) if reason else None,
            "startupCompleteMs": delayed["mean"] if delayed else None, "firstPaintKey": paint_key,
            "firstPaintMs": paint, "afterFirstPaintMs": after_paint, "limitMs": LIMIT_MS,
            "releasedBestEffortTasks": count["mean"] if count else None}


def run(factory, results, new_tab, wait_until, begin_row, style):
    if style != "chrome":
        # Alloy pages are not tab-strip tabs (PageType kTab), so the loaded-page
        # reason differs; Open ships chrome style and the gate runs it.
        for name in ("startup_complete_no_page", "startup_complete_loaded_page"):
            results[name] = {"status": "SKIP", "reason": "chrome style only (the gate's features style)"}
        return
    # 1. No web page at launch (empty window): before the fix, only the
    #    3-minute failsafe completed startup.
    begin_row("startup_complete_no_page")
    app = factory(urls=(), fresh=True)
    try:
        results["startup_complete_no_page"] = _row(app, new_tab, wait_until, "sidebarDrawn", {9})
    except Exception as e:
        results["startup_complete_no_page"] = {"ok": False, "error": repr(e)}
    finally:
        app.quit()
    # 2. A visible page that loads: startup completes when it is loaded and idle.
    begin_row("startup_complete_loaded_page")
    app = factory(urls=("data:text/html,<title>Start</title><h1>Start</h1>",), fresh=True)
    try:
        results["startup_complete_loaded_page"] = _row(app, new_tab, wait_until, "firstContentfulPaint", {7})
    except Exception as e:
        results["startup_complete_loaded_page"] = {"ok": False, "error": repr(e)}
    finally:
        app.quit()
