// Service worker: fetches a blocked file on install and stores the outcome
// in Cache Storage for the CDP driver.
self.addEventListener('install', event => {
  event.waitUntil(
      fetch('/ads/sw-ad.js').then(() => 'ok', () => 'failed').then(outcome =>
          caches.open('open-adblock-test').then(cache =>
              cache.put('/sw-outcome', new Response(outcome)))));
});
