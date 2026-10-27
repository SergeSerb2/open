// The page under the popup, and whether Chromium sees this page as a popup.
chrome.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
  window.currentTab = tabs[0] || null;
  window.popupViews = chrome.extension.getViews({ type: "popup" }).length;
  document.getElementById("out").textContent =
    `Current tab ${tabs[0] && tabs[0].id}; popup views ${window.popupViews}`;
});

// A solid image for chrome.action.setIcon({imageData}).
window.solidIcon = (r, g, b) => {
  const canvas = new OffscreenCanvas(32, 32);
  const context = canvas.getContext("2d");
  context.fillStyle = `rgb(${r}, ${g}, ${b})`;
  context.fillRect(0, 0, 32, 32);
  return context.getImageData(0, 0, 32, 32);
};
