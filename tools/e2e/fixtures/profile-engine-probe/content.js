document.documentElement.dataset.s10Extension = chrome.extension.inIncognitoContext ? "private" : "regular";
const port = chrome.runtime.connect({name: "s10-profile-proof"});
port.onMessage.addListener(() => { document.documentElement.dataset.s10Worker = "live"; });
port.postMessage("ready");
const timer = setInterval(() => port.postMessage("alive"), 2000);
port.onDisconnect.addListener(() => clearInterval(timer));
