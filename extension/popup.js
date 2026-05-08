document.querySelectorAll('[data-i18n]').forEach(el => {
  el.textContent = chrome.i18n.getMessage(el.dataset.i18n);
});

const shared = globalThis.RabbitGatekeeperShared;

function mergeSettingsWithDefaults(settings) {
  return shared.normalizeSettings(settings);
}

function getClampedNumberValue(inputId, fallbackValue) {
  const input = document.getElementById(inputId);
  const parsedValue = Number.parseInt(input.value, 10);
  const minValue = Number.parseInt(input.min, 10);
  const maxValue = Number.parseInt(input.max, 10);
  if (Number.isNaN(parsedValue)) return fallbackValue;
  return Math.min(Math.max(parsedValue, minValue), maxValue);
}

const dismissBtn = document.getElementById('dismissBtn');
chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
  chrome.tabs.sendMessage(tabs[0].id, { type: 'GET_RABBIT_STATUS' }, (res) => {
    void chrome.runtime.lastError;
    if (res?.rabbitIsActive) dismissBtn.style.display = 'block';
  });
});

dismissBtn.addEventListener('click', () => {
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    chrome.tabs.sendMessage(tabs[0].id, { type: 'DISMISS_RABBIT' }, () => {
      void chrome.runtime.lastError;
    });
    dismissBtn.style.display = 'none';
  });
});

const defaults = { ...shared.DEFAULT_SETTINGS };

chrome.storage.local.get(null, (settings) => {
  const mergedSettings = mergeSettingsWithDefaults(settings);
  document.getElementById('usageLimit').value = mergedSettings.usageLimit;
  document.getElementById('breakTime').value = mergedSettings.breakTime;
  document.getElementById('customDomains').value = mergedSettings.customDomains.join('\n');
  document.getElementById('rabbitEnabled').checked = mergedSettings.rabbitEnabled;
});

document.getElementById('saveBtn').addEventListener('click', () => {
  const settings = {
    rabbitEnabled: document.getElementById('rabbitEnabled').checked,
    usageLimit: getClampedNumberValue('usageLimit', defaults.usageLimit),
    breakTime: getClampedNumberValue('breakTime', defaults.breakTime),
    customDomains: shared.normalizeDomainList(document.getElementById('customDomains').value),
  };

  document.getElementById('usageLimit').value = settings.usageLimit;
  document.getElementById('breakTime').value = settings.breakTime;
  document.getElementById('customDomains').value = settings.customDomains.join('\n');

  chrome.storage.local.set(settings, () => {
    const msg = document.getElementById('savedMsg');
    msg.style.display = 'block';
    setTimeout(() => msg.style.display = 'none', 2000);

    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      chrome.tabs.sendMessage(tabs[0].id, { type: 'UPDATE_SETTINGS', settings }, () => {
        void chrome.runtime.lastError;
      });
    });
  });
});
