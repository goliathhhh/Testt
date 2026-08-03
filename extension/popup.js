document.getElementById("toggle").addEventListener("click", () => {
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    if (tabs[0]) {
      chrome.tabs.sendMessage(tabs[0].id, { type: "togglePanel" }, () => {
        // ignore errors when the content script isn't on this page
        void chrome.runtime.lastError;
      });
    }
  });
});
