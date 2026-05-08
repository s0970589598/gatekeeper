const shared = globalThis.RabbitGatekeeperShared;

const preloadVideo = document.createElement('video');
preloadVideo.preload = 'auto';
preloadVideo.muted = true;

const preventScroll = (e) => e.preventDefault();

const hostname = location.hostname;
const USAGE_STORAGE_KEY = 'rabbitGatekeeperUsage';
const USAGE_STALE_AFTER_MS = 30 * 60 * 1000;
const USAGE_SAVE_INTERVAL_SECONDS = 5;

function mergeSettingsWithDefaults(settings) {
  return shared.normalizeSettings(settings);
}

function getMatchedDomain(settings) {
  return shared.normalizeDomainList(settings.customDomains).find((domain) =>
    shared.hostnameMatchesDomain(hostname, domain)
  ) || '';
}

function applySettings(settings, { resetUsage = false } = {}) {
  const mergedSettings = mergeSettingsWithDefaults(settings);
  currentUsageLimit = mergedSettings.usageLimit;
  currentBreakTime = mergedSettings.breakTime;
  currentCustomDomains = mergedSettings.customDomains;
  currentUsageKey = getMatchedDomain(mergedSettings);
  currentTrackingEnabled = mergedSettings.rabbitEnabled && !!currentUsageKey;

  console.log('[rabbit-gatekeeper] applySettings', {
    hostname,
    usageLimit: currentUsageLimit,
    breakTime: currentBreakTime,
    customDomains: currentCustomDomains,
    matchedDomain: currentUsageKey,
    enabled: currentTrackingEnabled,
    rabbitEnabledSetting: mergedSettings.rabbitEnabled,
  });

  if (!currentTrackingEnabled) {
    stopTracker();
    return;
  }

  if (!rabbitIsActive) {
    startTracking(currentUsageLimit, currentBreakTime, { resetUsage });
  }
}

let rabbitIsActive = false;
let trackerRunning = false;

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message.type === 'GET_RABBIT_STATUS') {
    sendResponse({
      rabbitIsActive,
      hostname,
      trackerRunning,
      customDomains: currentCustomDomains,
      isTracked: currentTrackingEnabled,
      trackedDomain: currentUsageKey,
      hasFocus: document.hasFocus(),
      isHidden: document.hidden,
    });
    return;
  }

  if (message.type === 'UPDATE_SETTINGS') {
    stopTracker();
    applySettings(message.settings, { resetUsage: true });
  }

  if (message.type === 'DISMISS_RABBIT') {
    const overlay = document.getElementById('rabbit-gatekeeper-overlay');
    if (!overlay) return;
    const dismissedUsageKey = currentUsageKey;
    rabbitIsActive = false;
    stopCountdown();
    resetUsageSeconds(dismissedUsageKey);
    overlay.style.transition = 'opacity 0.5s';
    overlay.style.opacity = '0';
    setTimeout(() => {
      overlay.remove();
      document.documentElement.style.overflow = '';
      document.removeEventListener('wheel', preventScroll);
      document.removeEventListener('touchmove', preventScroll);
      if (currentTrackingEnabled && dismissedUsageKey === currentUsageKey) {
        startTracking(currentUsageLimit, currentBreakTime);
      }
    }, 500);
  }
});

let resetSeconds = () => {};
let stopTracker = () => {};
let stopCountdown = () => {};
let currentUsageLimit = 30;
let currentBreakTime = 5;
let currentTrackingEnabled = false;
let currentCustomDomains = [];
let currentUsageKey = '';
let rabbitAssetsPrepared = false;
let trackerRunId = 0;

function getUsageStorageKey(usageKey) {
  return `${USAGE_STORAGE_KEY}:${usageKey}`;
}

function isExtensionContextValid() {
  try {
    return !!chrome.runtime?.id;
  } catch (_e) {
    return false;
  }
}

function loadUsageSeconds(usageKey, callback) {
  if (!isExtensionContextValid()) { callback(0); return; }
  const storageKey = getUsageStorageKey(usageKey);
  try {
    chrome.storage.local.get({ [storageKey]: null }, (result) => {
      try {
        if (chrome.runtime.lastError) { callback(0); return; }
        const entry = result[storageKey];
        const now = Date.now();
        if (!entry || typeof entry !== 'object') { callback(0); return; }
        if (now - Number(entry.updatedAt || 0) > USAGE_STALE_AFTER_MS) { callback(0); return; }
        callback(Math.max(0, Number.parseInt(entry.seconds, 10) || 0));
      } catch (_e) {
        callback(0);
      }
    });
  } catch (_e) {
    callback(0);
  }
}

function saveUsageSeconds(usageKey, seconds) {
  if (!usageKey) return;
  if (!isExtensionContextValid()) return;
  try {
    chrome.storage.local.set({
      [getUsageStorageKey(usageKey)]: {
        seconds: Math.max(0, seconds),
        updatedAt: Date.now(),
      },
    });
  } catch (_e) {
    // Extension context lost (e.g., extension reloaded). Stop the tracker so it doesn't keep throwing.
    stopTracker();
  }
}

function resetUsageSeconds(usageKey) {
  saveUsageSeconds(usageKey, 0);
}

document.addEventListener('visibilitychange', () => {
  if (document.hidden) resetSeconds({ clearStoredUsage: true });
});

window.addEventListener('pagehide', () => {
  resetSeconds();
});

function startTracking(usageLimit, breakTime, { resetUsage = false } = {}) {
  prepareRabbitAssets();
  stopTracker();
  const runId = ++trackerRunId;
  currentUsageLimit = usageLimit;
  currentBreakTime = breakTime;
  const usageKey = currentUsageKey;

  if (resetUsage) {
    resetUsageSeconds(usageKey);
  }

  loadUsageSeconds(usageKey, (initialSeconds) => {
    if (
      runId !== trackerRunId ||
      usageKey !== currentUsageKey ||
      rabbitIsActive ||
      !currentTrackingEnabled
    ) {
      return;
    }

    trackerRunning = true;
    let localSeconds = resetUsage ? 0 : initialSeconds;
    let secondsSinceSave = 0;
    let shouldPersistUsage = true;
    console.log('[rabbit-gatekeeper] tracker started', { usageKey, initialSeconds, usageLimitSec: usageLimit * 60 });

    resetSeconds = ({ clearStoredUsage = false } = {}) => {
      if (clearStoredUsage) {
        shouldPersistUsage = false;
        localSeconds = 0;
        resetUsageSeconds(usageKey);
        return;
      }
      saveUsageSeconds(usageKey, localSeconds);
    };

    const tracker = setInterval(() => {
      if (!isExtensionContextValid()) {
        clearInterval(tracker);
        trackerRunning = false;
        return;
      }
      if (usageKey !== currentUsageKey || rabbitIsActive || !currentTrackingEnabled) {
        clearInterval(tracker);
        trackerRunning = false;
        return;
      }
      const focused = !document.hidden && document.hasFocus();
      if (!focused) {
        if (localSeconds % 5 === 0) {
          console.log('[rabbit-gatekeeper] tick paused (tab unfocused)', localSeconds, '/', usageLimit * 60);
        }
        return;
      }

      localSeconds++;
      secondsSinceSave++;
      if (localSeconds % 5 === 0) {
        console.log('[rabbit-gatekeeper] tick', localSeconds, '/', usageLimit * 60);
      }
      if (secondsSinceSave >= USAGE_SAVE_INTERVAL_SECONDS) {
        saveUsageSeconds(usageKey, localSeconds);
        secondsSinceSave = 0;
      }

      if (localSeconds >= usageLimit * 60) {
        clearInterval(tracker);
        trackerRunning = false;
        rabbitIsActive = true;
        shouldPersistUsage = false;
        localSeconds = 0;
        resetUsageSeconds(usageKey);
        showRabbit(breakTime, usageLimit, () => {
          if (currentTrackingEnabled && usageKey === currentUsageKey) {
            startTracking(currentUsageLimit, currentBreakTime);
          }
        });
      }
    }, 1000);

    stopTracker = () => {
      trackerRunning = false;
      if (shouldPersistUsage) {
        saveUsageSeconds(usageKey, localSeconds);
      }
      clearInterval(tracker);
      trackerRunId++;
    };
  });
}

function prepareRabbitAssets() {
  if (rabbitAssetsPrepared) return;
  preloadVideo.src = chrome.runtime.getURL('assets/rabbit.webm');
  preloadVideo.load();
  rabbitAssetsPrepared = true;
}

if (isExtensionContextValid()) {
  try {
    chrome.storage.local.get(null, (settings) => {
      try {
        if (chrome.runtime.lastError) return;
        applySettings(settings);
      } catch (_e) { /* extension context gone */ }
    });
  } catch (_e) { /* extension context gone */ }
}

function showRabbit(breakMinutes, usageLimit, onBreakEnd) {
  document.getElementById('rabbit-gatekeeper-overlay')?.remove();

  const overlay = document.createElement('div');
  overlay.id = 'rabbit-gatekeeper-overlay';
  overlay.style.setProperty('opacity', '1', 'important');
  overlay.style.transition = '';

  const countdown = document.createElement('div');
  countdown.id = 'rabbit-gatekeeper-countdown';
  let seconds = breakMinutes * 60;

  let countdownCancelled = false;
  stopCountdown = () => { countdownCancelled = true; };

  function updateCountdown() {
    if (countdownCancelled) return;
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    countdown.textContent = `${m}:${String(s).padStart(2, '0')}`;
    if (seconds > 0) {
      seconds--;
      setTimeout(updateCountdown, 1000);
    } else {
      rabbitIsActive = false;
      overlay.style.transition = 'opacity 1s';
      overlay.style.opacity = '0';
      setTimeout(() => {
        overlay.remove();
        document.documentElement.style.overflow = '';
        document.removeEventListener('wheel', preventScroll);
        document.removeEventListener('touchmove', preventScroll);
        onBreakEnd();
      }, 1000);
    }
  }
  updateCountdown();

  const video = document.createElement('video');
  video.src = chrome.runtime.getURL('assets/rabbit.webm');
  video.autoplay = true;
  video.muted = true;
  video.loop = true;
  video.playsInline = true;
  video.style.opacity = '1';

  overlay.appendChild(countdown);
  overlay.appendChild(video);
  document.body.appendChild(overlay);
  document.documentElement.style.overflow = 'hidden';
  document.addEventListener('wheel', preventScroll, { passive: false });
  document.addEventListener('touchmove', preventScroll, { passive: false });

  document.querySelectorAll('video').forEach(v => {
    if (v !== video) v.pause();
  });
}
