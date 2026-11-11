// All telemetry is synthetic and remains on loopback. No recurring work in the
// normal static fixture: the observer disconnects and the one-shot task ends.
const params = new URLSearchParams(location.search);
const run = params.get('run') || 'unlabelled';
const send = data => navigator.sendBeacon('/collect', new Blob([JSON.stringify({run,...data})], {type:'application/json'}));
if (params.get('phase2') === '1') {
  addEventListener('scrollend', () => send({event:'scrolled',score:scrollY}));
  addEventListener('wheel', () => {
    const frames=[],start=performance.now();
    const frame=t=>{frames.push(t);if(performance.now()-start<700){requestAnimationFrame(frame);return}
      const gaps=frames.slice(1).map((v,i)=>v-frames[i]).sort((a,b)=>a-b);
      if(gaps.length){send({event:'raf-median',score:gaps[Math.floor(gaps.length/2)]});send({event:'raf-p95',score:gaps[Math.ceil(gaps.length*.95)-1]})}};
    requestAnimationFrame(frame);
  }, {once:true,passive:true});
}
const channel = new BroadcastChannel('open-perf');
channel.onmessage = event => {
  if (event.data.command === 'close' && event.data.keep !== run) {
    send({event:'close-requested'});
    window.close();
  }
};
addEventListener('pagehide', () => send({event:'pagehide'}), {once:true});
let lcp = null;
const observer = new PerformanceObserver(list => {
  const entries = list.getEntries();
  if (entries.length) lcp = entries.at(-1).startTime;
});
observer.observe({type:'largest-contentful-paint',buffered:true});
addEventListener('load', () => setTimeout(() => {
  const navigation = performance.getEntriesByType('navigation')[0];
  const fcp = performance.getEntriesByType('paint').find(p => p.name === 'first-contentful-paint');
  observer.disconnect();
  send({event:'loaded', time_origin_ms:performance.timeOrigin, fcp_ms:fcp?.startTime ?? null,
    lcp_ms:lcp, load_ms:navigation.loadEventEnd-navigation.startTime,
    resource_network_count:performance.getEntriesByType('resource').filter(r=>r.transferSize>0).length,
    resource_cache_count:performance.getEntriesByType('resource').filter(r=>r.transferSize===0 && r.decodedBodySize>0).length,
    delay_ms:Number(params.get('delay_ms')||0), visibility:document.visibilityState,
    viewport_width:innerWidth,viewport_height:innerHeight});
}, 350), {once:true});
if (params.has('alloc_mib')) {
  window.perfAllocation = new Uint8Array(Number(params.get('alloc_mib'))*1024*1024);
  for (let i=0;i<window.perfAllocation.length;i+=4096) window.perfAllocation[i]=i/4096%251;
}
if (params.has('cpu_pct')) {
  // Intentional negative-proof fault; absent from primary samples.
  const ms=Number(params.get('cpu_pct'));
  setInterval(()=>{const end=performance.now()+ms;while(performance.now()<end){}},100);
}
