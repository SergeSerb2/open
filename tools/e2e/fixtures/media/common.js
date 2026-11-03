// Shared by the media e2e fixtures (tools/e2e/engine_e2e.py --only media). No binary media files:
// sound and pictures are generated in the page.
window.__counts = { previoustrack: 0, nexttrack: 0, play: 0, pause: 0 };
function toneWavURL(seconds, freq) {
  const rate = 8000, n = Math.floor(seconds * rate), buf = new ArrayBuffer(44 + n), v = new DataView(buf);
  const str = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
  str(0, 'RIFF'); v.setUint32(4, 36 + n, true); str(8, 'WAVEfmt '); v.setUint32(16, 16, true);
  v.setUint16(20, 1, true); v.setUint16(22, 1, true); v.setUint32(24, rate, true); v.setUint32(28, rate, true);
  v.setUint16(32, 1, true); v.setUint16(34, 8, true); str(36, 'data'); v.setUint32(40, n, true);
  for (let i = 0; i < n; i++) v.setUint8(44 + i, 128 + Math.round(40 * Math.sin(2 * Math.PI * freq * i / rate)));
  return URL.createObjectURL(new Blob([buf], { type: 'audio/wav' }));
}
function canvasStream(w, h, label) {
  const c = document.createElement('canvas'); c.width = w; c.height = h;
  const x = c.getContext('2d'); let f = 0;
  (function draw() { x.fillStyle = 'hsl(' + (f++ % 360) + ',60%,45%)'; x.fillRect(0, 0, w, h);
    x.fillStyle = '#fff'; x.font = '24px sans-serif'; x.fillText(label + ' ' + f, 20, 40); requestAnimationFrame(draw); })();
  return c.captureStream(30);
}
function toneStream(freq) {
  const ctx = new AudioContext(), o = ctx.createOscillator(), g = ctx.createGain(), d = ctx.createMediaStreamDestination();
  o.frequency.value = freq; g.gain.value = 0.05; o.connect(g); g.connect(d); o.start();
  window.__audioContext = ctx; (window.__audioContexts = window.__audioContexts || []).push(ctx);
  return d.stream;
}
// Plays the elements and resumes the tone contexts. A context made at load without a user gesture
// starts suspended under Chromium's autoplay policy, and its stream is then silent: Chromium's tab
// audio signal (P6) reports the tab inaudible. start() runs from the driver with a user gesture.
function playAll(...elements) {
  return Promise.all([...elements.map((e) => e.play()), ...(window.__audioContexts || []).map((c) => c.resume())]).then(() => true);
}
function makeVideo(id, w, h, withAudio, extra) {
  const v = document.createElement('video'); v.id = id; v.width = w; v.height = h; v.playsInline = true;
  const tracks = canvasStream(w, h, id).getVideoTracks();
  if (withAudio) tracks.push(...toneStream(330).getAudioTracks());
  v.srcObject = new MediaStream(tracks);
  if (extra) extra(v);
  document.body.appendChild(v);
  return v;
}
