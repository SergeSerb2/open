// Dedicated worker: one blocked and one allowed fetch, outcomes posted back.
const outcome = url => fetch(url).then(() => 'ok', () => 'failed');
Promise.all([outcome('/ads/worker-ad.js'), outcome('/api/data.json')])
    .then(([ad, data]) => postMessage({ad, data}));
