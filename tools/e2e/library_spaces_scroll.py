"""Library > Spaces with more Spaces than fit (UX round 1 wave 2, W3).

Six Spaces in a 1440 pt window. Real input through the window's event path (`mouse action=scroll`,
CGEvents sent through NSApp): a trackpad sideways swipe over a column, a notched mouse wheel over the
column headers, and a real Shift + wheel over a column body (macOS delivers it with sideways deltas)
must each bring the sixth column fully into view; one wheel notch moves the strip the same distance
over a header, over the gap between columns and (with Shift) over a column. Vertical input over
a column (a wheel turn, a trackpad gesture, also right after a sideways swipe) must not move the strip.
One swipe that crosses columns (and its momentum) stays with the strip to its end, through
whichever column is under the pointer. The edge with more columns past it fades, and scrolling between
the ends does not rewrite the fade
(the 56 pt page peek at the right is the Library's design: library_overlay `spaces_pushes_full_page_card`).
"""
import time

# A trackpad sends gesture events at the display rate. AppKit treats a burst of a few events and a
# lift within milliseconds unevenly (it may glide, stop at the deltas, or not move at all).
PACE = .012


def run(factory, results, h):
    app = factory(urls=('about:blank',), fresh=True)
    try:
        for n in range(5): app.call('space-create', title='Space %d' % (n + 2))
        app.call('window-frame', frame=[60, 60, 1440, 900]); time.sleep(.5)
        app.call('library', action='open', section='spaces')
        def state():
            return (app.call('space-manager-lifecycle') or {}).get('layout') or {}
        h.wait_until(lambda: len(state().get('columns', [])) == 6, timeout=10, step=.1)
        start = state()
        cols = start.get('columns') or [[0, 0, 0, 0]] * 2
        column_point = (cols[1][0] + cols[1][2] / 2, cols[1][1] + 200)
        header_point = (cols[1][0] + cols[1][2] / 2, cols[1][1] + 18)
        gap_point = ((cols[0][0] + cols[0][2] + cols[1][0]) / 2, cols[1][1] + 200)

        def scroll(point, **kw): app.call('mouse', action='scroll', x=point[0], y=point[1], **kw)
        def gesture(point, dx, dy, steps, may_begin=False):
            if may_begin: scroll(point, dx=0, dy=0, phase='mayBegin')
            scroll(point, dx=0, dy=0, phase='began')
            for _ in range(steps): scroll(point, dx=dx, dy=dy, phase='changed'); time.sleep(PACE)
            scroll(point, dx=0, dy=0, phase='ended')
        def wheel(point, dx=0, dy=0, steps=1, shift=False):
            for _ in range(steps): scroll(point, dx=dx, dy=dy, phase='none', continuous=False, shift=shift)
        def origin():
            # AppKit adds its own momentum after a gesture: read once the strip has come to rest.
            last = None
            for _ in range(40):
                time.sleep(.15); value = state().get('originX')
                if value is not None and value == last: return value
                last = value
            return None
        def home():
            app.call('space-manager-scroll', x=0); origin()
        def last_visible(s):
            c, vis = s.get('columns') or [], s.get('visible') or [0, 0, 0, 0]
            return bool(c) and c[-1][0] + c[-1][2] <= vis[0] + vis[2] + 1
        def until_end(move):
            for _ in range(8):
                if last_visible(state()): break
                move(); time.sleep(.3)
            return state()

        trackpad = until_end(lambda: gesture(column_point, -40, 0, 24))
        home(); header = until_end(lambda: wheel(header_point, dy=-10, steps=24))
        # macOS turns Shift + a vertical wheel into a sideways turn before the App sees it.
        home(); shifted = until_end(lambda: wheel(column_point, dx=-10, steps=24, shift=True))
        ends = dict(trackpad=trackpad, header=header, shiftWheel=shifted)
        results['library_spaces_sixth_reachable'] = dict(
            ok=len(cols) == 6 and not last_visible(start) and all(last_visible(s) for s in ends.values()),
            visible=start.get('visible'), lastColumn=dict(start=cols[-1], **{k: (s.get('columns') or [None])[-1] for k, s in ends.items()}))

        # One wheel notch moves the strip the same distance over a header (vertical turn), over the gap
        # between two columns, and over a column with Shift (a sideways turn). (A wheel kept turning
        # over a gap scrolls the column that slides under the pointer, as over any column.)
        home(); o0 = origin(); wheel(header_point, dy=-1); o1 = origin()
        home(); g0 = origin(); wheel(gap_point, dy=-1); g1 = origin()
        home(); s0 = origin(); wheel(column_point, dx=-1, shift=True); s1 = origin()
        results['library_spaces_wheel_step'] = dict(
            ok=None not in (o0, o1, g0, g1, s0, s1) and o1 - o0 > 0 and abs((g1 - g0) - (o1 - o0)) < .5 and abs((s1 - s0) - (o1 - o0)) < .5,
            header=[o0, o1], gap=[g0, g1], shiftWheel=[s0, s1])

        # Vertical input over a column (its list fits, so it cannot scroll) leaves the strip where it is.
        home(); v0 = origin(); wheel(column_point, dy=-3, steps=10); v1 = origin()
        gesture(column_point, 0, -40, 8, may_begin=True); v2 = origin()
        # A short sideways swipe that ends without momentum, then a vertical gesture on the same column.
        gesture(column_point, -30, 0, 3); v3 = origin()
        gesture(column_point, 0, -40, 6, may_begin=True); v4 = origin()
        results['library_spaces_vertical_stays'] = dict(
            ok=None not in (v0, v1, v2, v3, v4) and v1 == v0 and v2 == v0 and v3 > v0 and v4 == v3,
            wheel=[v0, v1], trackpad=[v1, v2], afterSwipe=[v3, v4])

        # Fades: right only at the start, both in the middle, left only at the end. Scrolling inside the
        # middle moves the strip but does not rewrite the mask.
        app.call('space-manager-scroll', x=120); origin()
        middle = state(); m0 = middle.get('originX')
        wheel(header_point, dy=-1, steps=6); origin(); after = state()
        writes = (after.get('maskWrites') or 0) - (middle.get('maskWrites') or 0)
        results['library_spaces_edges'] = dict(
            ok=start.get('masked') is True and [start.get('fadeLeft'), start.get('fadeRight')] == [False, True]
               and [middle.get('fadeLeft'), middle.get('fadeRight')] == [True, True]
               and [trackpad.get('fadeLeft'), trackpad.get('fadeRight')] == [True, False],
            contentWidth=start.get('contentWidth'),
            fades={k: [s.get('fadeLeft'), s.get('fadeRight')] for k, s in (('start', start), ('middle', middle), ('end', trackpad))})
        results['library_spaces_fade_static'] = dict(
            ok=after.get('originX') is not None and m0 is not None and after['originX'] > m0
               and [after.get('fadeLeft'), after.get('fadeRight')] == [True, True] and 0 <= writes <= 1,
            origin=[m0, after.get('originX')], maskWrites=writes)

        # One swipe that crosses columns: it starts over one column, the strip slides the next columns
        # under the still pointer, a slightly vertical event comes mid-swipe, and the lift and the
        # momentum land over another column. The strip keeps the whole gesture, then its momentum.
        app.call('window-frame', frame=[60, 60, 1000, 800]); time.sleep(.8)
        home(); before = state(); c = before.get('columns') or []
        point = (c[1][0] + c[1][2] / 2, c[1][1] + 200) if len(c) > 1 else (0, 0)
        def under(s):
            # The column the pointer is over, or (in a gap) the one to its left.
            return max((i for i, col in enumerate(s.get('columns') or []) if col[0] <= point[0]), default=None)
        scroll(point, dx=0, dy=0, phase='mayBegin'); scroll(point, dx=0, dy=0, phase='began')
        # Columns are 264 pt apart: after 410 pt the third column has just come under the pointer, and
        # the first event it gets is a slightly vertical one.
        for dx in [-40] * 10 + [-10]: scroll(point, dx=dx, dy=0, phase='changed'); time.sleep(PACE)
        time.sleep(.1); crossed = state()
        scroll(point, dx=-2, dy=-8, phase='changed'); time.sleep(PACE)
        for _ in range(4): scroll(point, dx=-40, dy=0, phase='changed'); time.sleep(PACE)
        time.sleep(.1); moving = state()
        scroll(point, dx=0, dy=0, phase='ended'); time.sleep(.05); lifted = state()
        scroll(point, dx=-20, dy=0, phase='none', momentum=1)
        for _ in range(3): scroll(point, dx=-20, dy=0, phase='none', momentum=2)
        scroll(point, dx=0, dy=0, phase='none', momentum=3); origin(); glided = state()
        # Then a vertical wheel turn over the column now under the pointer scrolls that column only.
        rest = glided.get('originX'); wheel(point, dy=-3, steps=4); after_wheel = origin()
        results['library_spaces_cross_column_swipe'] = dict(
            ok=under(before) == 1 and under(crossed) == 3 and (under(moving) or 0) >= 3
               and moving.get('originX', 0) - crossed.get('originX', 0) >= 120
               and crossed.get('ownsGesture') is True and lifted.get('ownsGesture') is False
               and glided.get('ownsGesture') is False and glided.get('ownsMomentum') is False and after_wheel == rest,
            columnUnderPointer={'start': under(before), 'wobble': under(crossed), 'lift': under(moving)},
            origin=[before.get('originX'), crossed.get('originX'), moving.get('originX'), lifted.get('originX')],
            owns={k: [s.get('ownsGesture'), s.get('ownsMomentum')] for k, s in (('swiping', crossed), ('lifted', lifted), ('atRest', glided))},
            wheelAfter=[rest, after_wheel])
    finally:
        app.quit()
