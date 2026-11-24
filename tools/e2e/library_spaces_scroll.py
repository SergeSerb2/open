"""Library > Spaces with more Spaces than fit (UX round 1 wave 2, W3).

Six Spaces in a 1440 pt window. Real input through the window's event path (`mouse action=scroll`):
a trackpad sideways swipe over a column, and a notched mouse wheel over the gap between columns,
a notched mouse wheel over the column headers, and Shift + wheel over a column body must each bring
the sixth column fully into view. The edge with more columns past it fades (the 56 pt page peek at
the right is the Library's design: library_overlay `spaces_pushes_full_page_card`).
"""
import time


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
        def last_visible(s):
            cols, vis = s.get('columns') or [], s.get('visible') or [0, 0, 0, 0]
            return bool(cols) and cols[-1][0] + cols[-1][2] <= vis[0] + vis[2] + 1
        def swipe(x, y, continuous, steps=24, shift=False):
            for _ in range(8):
                if last_visible(state()): break
                if continuous:
                    app.call('mouse', action='scroll', x=x, y=y, dx=0, dy=0, phase='began')
                    for _ in range(steps): app.call('mouse', action='scroll', x=x, y=y, dx=-40, dy=0, phase='changed')
                    app.call('mouse', action='scroll', x=x, y=y, dx=0, dy=0, phase='ended')
                else:
                    for _ in range(steps): app.call('mouse', action='scroll', x=x, y=y, dx=0, dy=-10, phase='none', continuous=False, shift=shift)
                time.sleep(.3)
            return state()
        cols = start.get('columns') or [[0, 0, 0, 0]] * 2
        column_point = (cols[1][0] + cols[1][2] / 2, cols[1][1] + 200)
        header_point = (cols[1][0] + cols[1][2] / 2, cols[1][1] + 18)
        trackpad = swipe(*column_point, continuous=True)
        app.call('space-manager-scroll', x=0); time.sleep(.3)
        wheel = swipe(*header_point, continuous=False)
        app.call('space-manager-scroll', x=0); time.sleep(.3)
        shifted = swipe(*column_point, continuous=False, shift=True)
        manager = start.get('manager') or [0, 0, 0, 0]
        results['library_spaces_sixth_reachable'] = dict(
            ok=len(cols) == 6 and not last_visible(start) and last_visible(trackpad) and last_visible(wheel) and last_visible(shifted),
            visible=start.get('visible'), lastColumn={'start': cols[-1], 'trackpad': (trackpad.get('columns') or [None])[-1],
            'wheel': (wheel.get('columns') or [None])[-1], 'shiftWheel': (shifted.get('columns') or [None])[-1]})
        results['library_spaces_edges'] = dict(
            ok=start.get('masked') is True and start.get('fadeRight') is True and start.get('fadeLeft') is False
               and trackpad.get('fadeLeft') is True and trackpad.get('fadeRight') is False,
            manager=manager, contentWidth=start.get('contentWidth'),
            fades={'start': [start.get('fadeLeft'), start.get('fadeRight')], 'end': [trackpad.get('fadeLeft'), trackpad.get('fadeRight')]})
    finally:
        app.quit()
