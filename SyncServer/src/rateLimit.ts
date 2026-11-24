/**
 * Per-key sliding-window-log rate limiter. Each key keeps the timestamps of its
 * hits inside the window; a hit is refused once `limit` hits are inside it.
 */
export class SlidingWindowLimiter {
  private readonly limit: number;
  private readonly windowMs: number;
  private readonly hits = new Map<string, number[]>();
  private readonly maxEntries: number;
  private readonly sweeper: NodeJS.Timeout;

  constructor(limit: number, windowMs = 60_000, maxEntries = 50_000) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.maxEntries = Math.max(1, maxEntries);
    this.sweeper = setInterval(() => this.sweep(Date.now()), Math.min(windowMs, 60_000));
    this.sweeper.unref();
  }

  get enabled(): boolean {
    return this.limit > 0;
  }

  /** Records a hit. Returns `retryAfterMs = 0` when allowed. */
  hit(key: string, now = Date.now()): { allowed: boolean; retryAfterMs: number } {
    if (this.limit <= 0) return { allowed: true, retryAfterMs: 0 };
    const cutoff = now - this.windowMs;
    let stamps = this.hits.get(key);
    if (stamps === undefined) {
      if (this.hits.size >= this.maxEntries) {
        this.sweep(now);
        // Still full: evict the oldest key (Map insertion order) so memory stays bounded.
        while (this.hits.size >= this.maxEntries) {
          const oldest = this.hits.keys().next();
          if (oldest.done) break;
          this.hits.delete(oldest.value);
        }
      }
      stamps = [];
      this.hits.set(key, stamps);
    }
    let drop = 0;
    while (drop < stamps.length && (stamps[drop] as number) <= cutoff) drop += 1;
    if (drop > 0) stamps.splice(0, drop);
    if (stamps.length >= this.limit) {
      const oldest = stamps[0] as number;
      return { allowed: false, retryAfterMs: Math.max(1, oldest + this.windowMs - now) };
    }
    stamps.push(now);
    return { allowed: true, retryAfterMs: 0 };
  }

  private sweep(now: number): void {
    const cutoff = now - this.windowMs;
    for (const [key, stamps] of this.hits) {
      const last = stamps[stamps.length - 1];
      if (last === undefined || last <= cutoff) this.hits.delete(key);
    }
  }

  close(): void {
    clearInterval(this.sweeper);
    this.hits.clear();
  }
}
