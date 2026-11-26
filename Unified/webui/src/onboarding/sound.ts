// Open's intro score, synthesized live with WebAudio (no audio files):
// a warm bell pair when the sun rises, a suspended pad that resolves to
// Dadd9, and a short hand-off chord. Quiet by design (peak gain 0.16).
// Browsers start audio only after a user gesture, so the score begins on the
// first pointer or key press; the mute choice is remembered per device.

const MUTE_KEY = 'open.onboarding.muted';

let context: AudioContext | null = null;
let master: GainNode | null = null;

export function isMuted(): boolean {
  try {
    return window.localStorage.getItem(MUTE_KEY) === '1';
  } catch {
    return false;
  }
}

export function setMuted(muted: boolean): void {
  try {
    window.localStorage.setItem(MUTE_KEY, muted ? '1' : '0');
  } catch {
    // Storage may be blocked; the choice then lasts for this page only.
  }
  if (master && context) {
    master.gain.cancelScheduledValues(context.currentTime);
    master.gain.setTargetAtTime(muted ? 0 : 1, context.currentTime, 0.08);
  }
}

function ensureContext(): AudioContext | null {
  if (context) return context;
  const Ctor =
    typeof window !== 'undefined'
      ? (window.AudioContext ??
        (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext)
      : undefined;
  if (!Ctor) return null;
  try {
    context = new Ctor();
    master = context.createGain();
    master.gain.value = isMuted() ? 0 : 1;
    master.connect(context.destination);
  } catch {
    context = null;
    master = null;
  }
  return context;
}

const NOTE = {
  D4: 293.66,
  A4: 440,
  D5: 587.33,
  E5: 659.25,
  Fs5: 739.99,
  A5: 880,
  B4: 493.88,
  G4: 392,
} as const;

/** One struck bell: inharmonic partials with a fast attack, long decay. */
function bell(ctx: AudioContext, out: AudioNode, freq: number, at: number, gain: number): void {
  const partials: [number, number, number][] = [
    [1, 1, 2.6],
    [2.01, 0.42, 1.6],
    [2.76, 0.22, 1.1],
    [5.4, 0.08, 0.6],
  ];
  for (const [ratio, amp, decay] of partials) {
    const osc = ctx.createOscillator();
    const env = ctx.createGain();
    osc.type = 'sine';
    osc.frequency.value = freq * ratio;
    env.gain.setValueAtTime(0, at);
    env.gain.linearRampToValueAtTime(gain * amp, at + 0.008);
    env.gain.exponentialRampToValueAtTime(0.0001, at + decay);
    osc.connect(env).connect(out);
    osc.start(at);
    osc.stop(at + decay + 0.05);
  }
}

/** A soft pad chord: detuned triangles through a low-pass. */
function pad(ctx: AudioContext, out: AudioNode, freqs: number[], at: number, hold: number, gain: number): void {
  const filter = ctx.createBiquadFilter();
  filter.type = 'lowpass';
  filter.frequency.value = 1400;
  filter.Q.value = 0.4;
  const env = ctx.createGain();
  env.gain.setValueAtTime(0, at);
  env.gain.linearRampToValueAtTime(gain, at + 1.6);
  env.gain.setValueAtTime(gain, at + hold);
  env.gain.linearRampToValueAtTime(0.0001, at + hold + 2.4);
  filter.connect(env).connect(out);
  for (const f of freqs) {
    for (const detune of [-6, 6]) {
      const osc = ctx.createOscillator();
      osc.type = 'triangle';
      osc.frequency.value = f;
      osc.detune.value = detune;
      osc.connect(filter);
      osc.start(at);
      osc.stop(at + hold + 2.6);
    }
  }
}

let introPlayed = false;

/**
 * The intro score from |offsetSeconds| into the intro timeline (the sun
 * rises at 1.7 s; the bell pair sounds at 2.3 s). Plays once per page.
 */
export function playIntroScore(offsetSeconds: number): void {
  if (introPlayed) return;
  const ctx = ensureContext();
  if (!ctx || !master) return;
  introPlayed = true;
  void ctx.resume().catch(() => undefined);
  const now = ctx.currentTime + 0.08;
  const t = (beat: number) => now + Math.max(0, beat - offsetSeconds);
  const bus = ctx.createGain();
  bus.gain.value = 0.16;
  bus.connect(master);
  if (offsetSeconds < 2.6) {
    bell(ctx, bus, NOTE.A5, t(2.3), 0.55);
    bell(ctx, bus, NOTE.D5, t(2.47), 0.6);
  } else {
    bell(ctx, bus, NOTE.D5, now, 0.45);
  }
  // Suspended (Dsus2/sus4 colour), then the Dadd9 resolution.
  pad(ctx, bus, [NOTE.D4, NOTE.A4, NOTE.E5, NOTE.G4], t(3.3), 4.2, 0.12);
  pad(ctx, bus, [NOTE.D4, NOTE.A4, NOTE.Fs5, NOTE.E5], t(8.2), 4.5, 0.11);
}

/** The hand-off: a rising D-A-F# arpeggio of soft bells (0.8 s). */
export function playHandoff(): void {
  const ctx = ensureContext();
  if (!ctx || !master || isMuted()) return;
  void ctx.resume().catch(() => undefined);
  const bus = ctx.createGain();
  bus.gain.value = 0.14;
  bus.connect(master);
  const now = ctx.currentTime + 0.05;
  bell(ctx, bus, NOTE.D5, now, 0.5);
  bell(ctx, bus, NOTE.A5, now + 0.12, 0.45);
  bell(ctx, bus, NOTE.Fs5 * 2, now + 0.24, 0.3);
}

/** A small tick for selections (Favorites, swatches). */
export function playTick(): void {
  if (!context || !master || isMuted()) return;
  const bus = context.createGain();
  bus.gain.value = 0.05;
  bus.connect(master);
  bell(context, bus, NOTE.B4 * 2, context.currentTime + 0.01, 0.4);
}
