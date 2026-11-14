"""Real-App frame-presentation requests on live native hosted Chromium pages."""
import http.server
import os
from pathlib import Path
import signal
import subprocess
import threading
import time
import uuid
from loopback_http import LoopbackHTTPServer


def run(factory, results, wait, output, read_image):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            body = (b'<!doctype html><title>Presentation fixture</title>'
                    b'<style>body{margin:0;background:#276aa5;color:white}'
                    b'div{width:100px;height:100px;background:#eabc52}</style>'
                    b'<div>retained pixels</div><script>window.fixtureNonce="same-document"</script>')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = LoopbackHTTPServer(Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    app = None

    def call(action='state', **args):
        return app.call('engine-api', action=action, **args)

    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)

    def receipt(identifier):
        return wait(lambda: next((r for r in call()['frameReceipts']
                                  if r['requestID'] == identifier), None), timeout=10)

    def request(viewport, **options):
        identifier = str(uuid.uuid4()).upper()
        reply = call('presentation-request', page='p', requestID=identifier,
                     pixelWidth=int(viewport['pixelSize'][0]),
                     pixelHeight=int(viewport['pixelSize'][1]),
                     scale=viewport['scale'], **options)
        assert reply['accepted'], reply
        return identifier, reply

    try:
        app = factory(fresh=True, urls=('about:blank',),
                      extra_args=['--style=chrome', '--engine-api-auth'])
        call('start')
        call('add', page='p', browser='a',
             url='http://127.0.0.1:%d/static' % server.server_address[1])
        assert wait(lambda: (lambda p: p['live'] and not p['loading'])(call()['pages']['p']), timeout=20)
        row('presentation_capability', 'frameReceipts' in call()
            and call()['pages']['p'].get('framePresentation', False))
        assert results['presentation_capability']['ok'], 'App has no presentation request capability'
        viewport = call('presentation-viewport', page='p')
        identifier, reply = request(viewport)
        actual = receipt(identifier)
        row('static_page_successful_presentation', actual and actual['success']
            and not actual['synchronous'] and actual['receiptID'] == identifier
            and actual['pixelSize'] == viewport['pixelSize']
            and actual['scale'] == viewport['scale']
            and actual['presentedAt'] >= actual['startedAt'], request=reply, receipt=actual)
        assert results['static_page_successful_presentation']['ok']

        def capture(name):
            path = Path(output) / ('presentation-' + name + '.png')
            subprocess.run(['screencapture', '-l', str(viewport['window']),
                            '-o', '-x', str(path)], check=True, timeout=8)
            return path.name, read_image(str(path))

        # Stop only this App's verified renderer descendants. The browser/GPU
        # remain live, so the native resize still runs but cannot receive new
        # renderer pixels. Always resume before cleanup or any assertion.
        before_name, before_image = capture('before-retained-resize')
        app.discover_owned_processes()
        renderers = {pid: path for pid, path in app.owned_processes.items()
                     if '(Renderer)' in path and app.process_path(pid) == path}
        assert renderers, 'no owned renderer to pause'
        stopped = []
        try:
            for pid, path in renderers.items():
                if app.process_path(pid) == path:
                    os.kill(pid, signal.SIGSTOP)
                    stopped.append((pid, path))
            target = dict(viewport, pixelSize=[round(910 * viewport['scale']),
                                               round(600 * viewport['scale'])])
            identifier, reply = request(target, retain=True, resizeTo=[910, 600])
            # Observe beyond the normal surface deadline while no renderer
            # can produce the requested frame. This delay cannot complete a
            # request; only the engine's successful presentation receipt can.
            pending_observation_started = time.monotonic()
            time.sleep(.25)
            pending_name, pending_image = capture('pending-retained-resize')
            pending_observation_seconds = time.monotonic() - pending_observation_started
            pending_rows = call()['frameReceipts']
            premature = any(r['requestID'] == identifier for r in pending_rows)
            call('presentation-cancel', requestID=identifier)
            cancelled = receipt(identifier)
            time.sleep(.1)
            cancelled_name, cancelled_image = capture('cancelled-retained-resize')
            # Re-arm at the already applied size. It still needs a genuine
            # presentation after this request; cancellation must keep pixels.
            identifier, reply = request(target, retain=True)
        finally:
            for pid, path in stopped:
                if app.process_path(pid) == path:
                    os.kill(pid, signal.SIGCONT)
        actual = receipt(identifier)
        final_name, final_image = capture('presented-retained-resize')

        def gold_width(image):
            # Exclude native titlebar controls. The fixture has a solid 100px
            # gold square. Its width must stay fixed while the surface waits.
            width, height, pixel = image
            columns = []
            for x in range(width):
                for y in range(100, min(height - 40, 350)):
                    red, green, blue = pixel(x, y)
                    if red > 150 and green > 100 and blue < 150:
                        columns.append(x)
                        break
            return max(columns) - min(columns) + 1 if columns else 0

        def common_pixels(image):
            _, height, pixel = image
            return [pixel(x, y) for y in range(height - 120, height - 40)
                    for x in range(40, 400)]

        retained = common_pixels(before_image) == common_pixels(pending_image)
        kept_on_cancel = common_pixels(pending_image) == common_pixels(cancelled_image)
        widths = [gold_width(i) for i in (before_image, pending_image, cancelled_image, final_image)]
        row('retained_pixels_until_matching_presentation', retained and not premature
            and kept_on_cancel and cancelled and not cancelled['success']
            and len(stopped) == len(renderers)
            and widths[0] == round(100 * viewport['scale']) and len(set(widths)) == 1
            and actual and actual['success'] and actual['pixelSize'] == target['pixelSize'],
            receipt=actual, cancelledReceipt=cancelled, noPrematureReceipt=not premature,
            unchangedPixelsOnCancel=kept_on_cancel,
            unchangedCommonPixels=retained, goldWidths=widths,
            pendingObservationSeconds=pending_observation_seconds,
            pausedOwnedRenderers=len(stopped),
            captures=[before_name, pending_name, cancelled_name, final_name])
        assert results['retained_pixels_until_matching_presentation']['ok']
        viewport = call('presentation-viewport', page='p')

        for index, width in enumerate((680, 910, 800)):
            target = dict(viewport, pixelSize=[round(width * viewport['scale']),
                                               round(600 * viewport['scale'])])
            identifier, reply = request(target, retain=True, resizeTo=[width, 600])
            actual = receipt(identifier)
            dom = call('eval', page='p', js='({width:innerWidth,height:innerHeight,nonce:fixtureNonce})')
            row('retained_resize_%d' % index, actual and actual['success']
                and not actual['synchronous'] and actual['receiptID'] == identifier
                and actual['pixelSize'] == target['pixelSize']
                and actual['scale'] == target['scale']
                and dom['width'] == width and dom['height'] == 600
                and dom['nonce'] == 'same-document', request=reply, receipt=actual, document=dom)
            assert results['retained_resize_%d' % index]['ok']
            viewport = call('presentation-viewport', page='p')

        # The requested size is deliberately not applied. These requests must
        # stay pending, then cancel through the real native/document lifetime.
        pending = dict(viewport, pixelSize=[int(viewport['pixelSize'][0]) + 74,
                                           int(viewport['pixelSize'][1])])
        for action in ('cancel', 'same-document', 'navigate', 'detach'):
            identifier, reply = request(pending, retain=True, then=action)
            actual = receipt(identifier)
            row('cancel_on_' + action, actual and not actual['success']
                and not actual['synchronous'], request=reply, receipt=actual)
            assert results['cancel_on_' + action]['ok']
            if action == 'navigate':
                call('navigate', page='p',
                     url='http://127.0.0.1:%d/static' % server.server_address[1])
                assert wait(lambda: (lambda p: not p['loading'] and p['url'].endswith('/static'))(
                    call()['pages']['p']), timeout=20)
            if action == 'detach':
                call('attach', page='p', browser='a')

        old, first = request(pending, retain=True)
        latest, second = request(viewport)
        old_receipt, new_receipt = receipt(old), receipt(latest)
        row('supersession_keeps_latest', old_receipt and not old_receipt['success']
            and new_receipt and new_receipt['success']
            and new_receipt['receiptID'] == latest,
            previous=old_receipt, latest=new_receipt)
        identifier, reply = request(pending, retain=True, then='close')
        actual = receipt(identifier)
        row('close_cancels_without_success', actual and not actual['success'], receipt=actual)
        time.sleep(.1)
        rows = call()['frameReceipts']
        ids = [r['requestID'] for r in rows]
        row('one_deferred_completion_per_request', len(ids) == len(set(ids))
            and len(rows) == 13 and all(not r['synchronous'] for r in rows), receipts=rows)
    finally:
        if app:
            app.quit()
        server.shutdown()
        server.server_close()
