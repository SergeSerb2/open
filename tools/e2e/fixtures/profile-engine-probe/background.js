// A real MV3 worker. The fixture page keeps a port and sends periodic traffic.
chrome.runtime.onConnect.addListener(port => {
  port.onMessage.addListener(() => port.postMessage({live: true}));
});
