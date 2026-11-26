'use strict';

// Always invoke webui_ctl.sh with its absolute module path (id=coresurface).
const CTL_SCRIPT = '/system/bin/sh /data/adb/modules/coresurface/lib/webui_ctl.sh';
const LIVE_KEYS = new Set(['FEAT_MOTION_PROFILE', 'FEAT_SURGICAL_GUARD']);

let execCounter = 0;
let uiBusy = false;

function setBusy(busy) {
  uiBusy = busy;
  for (const el of document.querySelectorAll('button')) {
    el.disabled = busy;
  }
}

function ksuExec(command) {
  if (!window.ksu || typeof window.ksu.exec !== 'function') {
    return Promise.reject(new Error('Open this WebUI from KernelSU-Next / MMRL Manager'));
  }

  return new Promise((resolve, reject) => {
    const cbName = '__csExec' + (++execCounter);
    const cbHandle = 'window.' + cbName;

    const timer = setTimeout(() => {
      delete window[cbName];
      reject(new Error('Shell command timed out (30s)'));
    }, 30000);

    window[cbName] = (code, stdout, stderr) => {
      clearTimeout(timer);
      delete window[cbName];
      const out = String(stdout == null ? '' : stdout).trim();
      const err = String(stderr == null ? '' : stderr).trim();
      if (Number(code) !== 0) {
        reject(new Error(err || out || ('Shell exited with code ' + code)));
      } else {
        resolve(out);
      }
    };

    try {
      window.ksu.exec(command, cbHandle);
    } catch (e) {
      clearTimeout(timer);
      delete window[cbName];
      reject(e);
    }
  });
}

function parseStatus(raw) {
  const kv = {};
  const logs = [];
  let inLog = false;

  for (const line of raw.split(/\r?\n/)) {
    if (line === 'log_start') { inLog = true; continue; }
    if (line === 'log_end') { inLog = false; continue; }
    if (inLog) {
      logs.push(line);
      continue;
    }
    const idx = line.indexOf('=');
    if (idx > 0) {
      kv[line.slice(0, idx)] = line.slice(idx + 1);
    }
  }
  return { kv, logs };
}

function makeKvRow(label, value) {
  const row = document.createElement('div');
  row.className = 'kv-row';
  const k = document.createElement('span');
  k.textContent = label;
  const v = document.createElement('strong');
  v.textContent = value || '-';
  row.appendChild(k);
  row.appendChild(v);
  return row;
}

function formatMotion(p) {
  if (p === 'snappy' || p === 'coloros' || p === 'silk') return 'Snappy (Fast & Crisp)';
  if (p === 'fluid' || p === 'hyperos4') return 'Fluid (Silky Glide)';
  if (p === 'bouncy' || p === 'ios') return 'Bouncy (Elastic Spring)';
  if (p === 'off' || p === '0') return 'Stock Flagship (Native)';
  return p || '-';
}

function renderVerifyPill(featKey, status, isPending) {
  const el = document.getElementById('verify-' + featKey);
  if (!el) return;
  el.className = 'v-pill';

  if (isPending && !LIVE_KEYS.has(featKey)) {
    el.classList.add('v-info');
    el.textContent = 'Pending Reboot';
    return;
  }

  switch (status) {
    case 'verified_active':
      el.classList.add('v-ok');
      el.textContent = 'Active';
      break;
    case 'pending_lsposed':
      el.classList.add('v-info');
      el.textContent = 'Enable in LSPosed';
      break;
    case 'ignored_by_rom':
      el.classList.add('v-danger');
      el.textContent = 'Rejected by ROM';
      break;
    case 'disabled':
      el.classList.add('v-neutral');
      el.textContent = 'OFF';
      break;
    default:
      el.classList.add('v-neutral');
      el.textContent = status || '-';
      break;
  }
}

function setSegmentValue(key, val) {
  const group = document.querySelector('.seg-group[data-key="' + key + '"]');
  if (!group) return;
  let normalized = (val === 'auto') ? '1' : val;
  if (key === 'FEAT_MOTION_PROFILE') {
    if (normalized === 'coloros' || normalized === 'silk') normalized = 'snappy';
    if (normalized === 'hyperos4') normalized = 'fluid';
    if (normalized === 'ios') normalized = 'bouncy';
    if (normalized === 'off') normalized = '0';
  }
  for (const btn of group.querySelectorAll('button')) {
    btn.classList.toggle('active', btn.dataset.val === normalized);
  }
}

function setToast(msg) {
  document.getElementById('toast-msg').textContent = msg || '';
}

async function refreshStatus() {
  const summary = document.getElementById('summary-list');
  try {
    const raw = await ksuExec(CTL_SCRIPT + ' status');
    const { kv, logs } = parseStatus(raw);
    if (!kv.rom_family) {
      throw new Error('Incomplete status response');
    }

    // Watchdog badge
    const wdBadge = document.getElementById('watchdog-badge');
    const safeBanner = document.getElementById('safemode-banner');
    const safeReason = document.getElementById('safemode-reason');
    const isDisabled = kv.module_disabled === '1' || kv.watchdog_status === 'safe_mode_disabled';
    wdBadge.className = 'badge';
    safeBanner.classList.add('hidden');
    if (isDisabled) {
      wdBadge.classList.add('badge-danger');
      wdBadge.textContent = 'Watchdog: Safe-Mode';
      if (safeReason && kv.watchdog_reason && kv.watchdog_reason !== 'none') {
        safeReason.textContent = 'Reason: ' + kv.watchdog_reason + ' (strikes: ' + (kv.boot_strikes || '0') + '/2).';
      }
      safeBanner.classList.remove('hidden');
    } else if (kv.watchdog_status === 'healthy') {
      wdBadge.classList.add('badge-ok');
      wdBadge.textContent = 'Watchdog: Healthy';
    } else {
      wdBadge.classList.add('badge-warn');
      wdBadge.textContent = 'Watchdog: ' + (kv.watchdog_status || 'unknown');
    }

    // Metamodule RRO warning banner
    const bugsList = (kv.os_bugs_csv || '').split(',').map((s) => s.trim()).filter(Boolean);
    const metaBanner = document.getElementById('metamodule-banner');
    if (metaBanner) {
      metaBanner.classList.toggle('hidden', !bugsList.includes('MISSING_META_OVERLAYFS'));
    }

    // Engine + Hz badges
    const engBadge = document.getElementById('engine-badge');
    const lodBadge = document.getElementById('engine-lod-badge');
    const hzPill = document.getElementById('engine-hz-pill');
    const active = kv.verify_engine_active === '1';
    const installed = kv.verify_engine_installed === '1';
    const hz = Number(kv.verify_engine_hz || 0);

    engBadge.className = 'badge';
    lodBadge.className = 'pill';
    hzPill.className = 'pill';

    if (active) {
      engBadge.classList.add('badge-ok');
      engBadge.textContent = 'Engine: Active';
      lodBadge.classList.add('on');
      lodBadge.textContent = 'Thermal: ' + (kv.verify_engine_lod || 'FULL');
      hzPill.classList.add('on');
      hzPill.textContent = hz > 0 ? (hz + ' Hz Sync') : 'Live IPC';
    } else if (installed) {
      engBadge.classList.add('badge-warn');
      engBadge.textContent = 'Engine: Enable in LSPosed';
      lodBadge.classList.add('warn');
      lodBadge.textContent = 'LSPosed Off';
      hzPill.textContent = 'Standalone Layer 1';
    } else {
      engBadge.classList.add('badge-neutral');
      engBadge.textContent = 'Layer 1 Only';
      lodBadge.textContent = 'No Engine APK';
      hzPill.textContent = 'Standalone Layer 1';
    }

    // Compat badge
    const compatBadge = document.getElementById('compat-badge');
    const evalCount = Number(kv.verify_feat_evaluated || 0);
    if (kv.compat_score_pct && evalCount > 0) {
      const pct = Number(kv.compat_score_pct);
      compatBadge.className = 'badge ' + (pct >= 85 ? 'badge-ok' : (pct >= 50 ? 'badge-warn' : 'badge-danger'));
      compatBadge.textContent = 'Score: ' + pct + '% (' + (kv.verify_feat_verified || '0') + '/' + evalCount + ')';
    } else {
      compatBadge.classList.add('hidden');
    }

    document.getElementById('coreflow-badge').classList.toggle('hidden', kv.coreflow_guard !== 'active');

    const pendingSet = new Set((kv.pending_keys || '').split(',').map((s) => s.trim()).filter(Boolean));
    document.getElementById('reboot-banner').classList.toggle('hidden', pendingSet.size === 0);

    // 4-Tier cards
    const curTier = kv.cfg_tier_mode || 'auto';
    for (const btn of document.querySelectorAll('.btn-tier')) {
      btn.classList.toggle('active', btn.dataset.tier === curTier);
    }
    const autoHint = document.getElementById('auto-tier-hint');
    if (autoHint && kv.detected_tier_label) {
      autoHint.textContent = 'Detected: ' + kv.detected_tier_label;
    }
    const tierPill = document.getElementById('active-tier-pill');
    tierPill.className = 'pill on';
    tierPill.textContent = kv.eff_tier_label || kv.eff_tier || 'Auto';

    // Controls
    setSegmentValue('FEAT_MOTION_PROFILE', kv.cfg_feat_motion_profile || 'snappy');
    setSegmentValue('FEAT_SURGICAL_GUARD', kv.cfg_feat_surgical_guard || '1');
    setSegmentValue('FEAT_AOD_UNLOCK', kv.cfg_feat_aod_unlock || '1');
    setSegmentValue('FEAT_FLAGSHIP_AUDIO', kv.eff_feat_flagship_audio === '1' ? '1' : '0');
    setSegmentValue('FEAT_FLAGSHIP_SUITE', kv.eff_feat_flagship_suite === '1' ? '1' : '0');

    renderVerifyPill('FEAT_MOTION_PROFILE', kv.verify_feat_motion_profile, false);
    renderVerifyPill('FEAT_SURGICAL_GUARD', kv.verify_feat_surgical_guard, false);
    renderVerifyPill('FEAT_AOD_UNLOCK', kv.verify_feat_aod_unlock, pendingSet.has('FEAT_AOD_UNLOCK'));
    renderVerifyPill('FEAT_FLAGSHIP_AUDIO', kv.verify_feat_flagship_audio, pendingSet.has('FEAT_FLAGSHIP_AUDIO'));
    renderVerifyPill('FEAT_FLAGSHIP_SUITE', kv.verify_feat_flagship_suite, pendingSet.has('FEAT_FLAGSHIP_SUITE'));

    // Compact Summary
    const romStr = (kv.rom_family || '').toUpperCase() + ' ' + (kv.rom_version || '') + ' · SDK ' + (kv.android_sdk || '-');
    const blurMode = kv.eff_tier === 'motion_only'
      ? 'Factory Flagship (Full Passthrough)'
      : (kv.eff_feat_adv_textures === '1' ? 'Full Blur (HOS3/4 Safe)' : 'Standard Blur (No Adv. Textures)');
    const colorMode = (kv.eff_feat_color_expert === '1' || kv.stock_has_expert_color === '1')
      ? 'Custom Color ON'
      : 'Stock Color';
    const audioSuiteStr = 'Audio ' + (kv.eff_feat_flagship_audio === '1' ? 'Flagship ON' : 'Stock')
      + ' · Porting Suite ' + (kv.eff_feat_flagship_suite === '1' ? 'ON' : 'OFF');
    const stats = 'Folme: ' + (kv.verify_engine_folme_hooks || '0')
      + ' · Gates: ' + (kv.verify_engine_native_gates || '0')
      + ' · Springs: ' + (kv.verify_engine_springs || '0')
      + ' · UI Curves: ' + (kv.verify_engine_curves || '0')
      + ' · Guard Fix: ' + (kv.verify_engine_recents || '0')
      + ' · AOD Gates: ' + (kv.verify_engine_aod_gates || '0');
    const bugSummary = (kv.os_bugs_mitigated || '0') + '/' + (kv.os_bugs_detected || '0') + ' mitigated'
      + (kv.os_bugs_csv ? (' (' + kv.os_bugs_csv.split(',').slice(0, 3).join(', ') + ')') : '');

    summary.replaceChildren(
      makeKvRow('ROM & RAM', romStr + ' · ' + (kv.ram_mb || '0') + ' MB'),
      makeKvRow('Blur & Color', blurMode + ' · ' + colorMode),
      makeKvRow('Audio & Suite', audioSuiteStr),
      makeKvRow('Motion Profile', formatMotion(kv.verify_engine_motion && kv.verify_engine_motion !== 'N/A' ? kv.verify_engine_motion : kv.eff_feat_motion_profile)),
      makeKvRow('OS Bug Logic', bugSummary),
      makeKvRow('Live Telemetry', active ? stats : 'Enable CoreSurface Engine in LSPosed'),
      makeKvRow('Base Layer 1', 'Props ' + (kv.verify_props_matched || '0') + '/' + (kv.verify_props_total || '0')
        + ' · XML ' + (kv.verify_xml_mount || kv.xml_status || '-')
        + ' · RRO ' + (kv.verify_rro_active || '0') + '/' + (kv.verify_rro_total || kv.rro_staged_count || '0'))
    );

    document.getElementById('diag-log').textContent = logs.join('\n') || 'No log entries yet.';
  } catch (err) {
    summary.replaceChildren(makeKvRow('Error', err.message));
    setToast('Failed to read status: ' + err.message);
  }
}

async function runAction(toastBusy, fn) {
  if (uiBusy) return;
  setBusy(true);
  setToast(toastBusy);
  try {
    await fn();
  } finally {
    setBusy(false);
  }
}

async function selectTier(tier) {
  await runAction('Saving Tier Mode "' + tier + '"…', async () => {
    try {
      const res = await ksuExec(CTL_SCRIPT + ' tier ' + tier);
      document.getElementById('reboot-banner').classList.remove('hidden');
      setToast(res);
      await refreshStatus();
    } catch (err) {
      setToast('Failed to change tier: ' + err.message);
    }
  });
}

async function updateConfig(key, value) {
  const isLive = LIVE_KEYS.has(key);
  await runAction((isLive ? 'Applying LIVE ' : 'Saving ') + key + '=' + value + '…', async () => {
    try {
      const res = await ksuExec(CTL_SCRIPT + ' set ' + key + ' ' + value);
      if (!isLive) {
        document.getElementById('reboot-banner').classList.remove('hidden');
      }
      setToast(res);
      await refreshStatus();
    } catch (err) {
      setToast('Failed to save: ' + err.message);
    }
  });
}

document.getElementById('btn-refresh').addEventListener('click', () => {
  runAction('Refreshing status…', async () => {
    await refreshStatus();
    setToast('');
  });
});

document.getElementById('btn-reset-safemode').addEventListener('click', () => {
  runAction('Resetting Safe-Mode…', async () => {
    try {
      setToast(await ksuExec(CTL_SCRIPT + ' reset-safemode'));
      await refreshStatus();
    } catch (err) {
      setToast('Reset failed: ' + err.message);
    }
  });
});

document.getElementById('btn-hot-sync').addEventListener('click', () => {
  runAction('Running re-verification…', async () => {
    try {
      setToast(await ksuExec(CTL_SCRIPT + ' hot-sync'));
      await refreshStatus();
    } catch (err) {
      setToast('Verification failed: ' + err.message);
    }
  });
});

document.getElementById('btn-install-engine').addEventListener('click', () => {
  runAction('Installing CoreSurfaceEngine.apk…', async () => {
    try {
      setToast(await ksuExec(CTL_SCRIPT + ' install-engine'));
      await refreshStatus();
    } catch (err) {
      setToast('APK install failed: ' + err.message);
    }
  });
});

document.getElementById('btn-export-diag').addEventListener('click', () => {
  runAction('Generating diagnostic report…', async () => {
    try {
      const report = await ksuExec(CTL_SCRIPT + ' diag-report');
      const wrap = document.getElementById('diag-export-wrap');
      const box = document.getElementById('diag-export-box');
      box.value = report;
      wrap.classList.remove('hidden');
      if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
        try {
          await navigator.clipboard.writeText(report);
          setToast('Diagnostic report copied to clipboard.');
          return;
        } catch (_clipErr) {
          // Fallback to textarea
        }
      }
      box.focus();
      box.select();
      setToast('Report ready to copy from the text box below.');
    } catch (err) {
      setToast('Failed to generate report: ' + err.message);
    }
  });
});

for (const btn of document.querySelectorAll('.btn-tier')) {
  btn.addEventListener('click', () => {
    if (uiBusy || btn.classList.contains('active')) return;
    selectTier(btn.dataset.tier);
  });
}

for (const group of document.querySelectorAll('.seg-group')) {
  const key = group.dataset.key;
  for (const btn of group.querySelectorAll('button')) {
    btn.addEventListener('click', () => {
      if (uiBusy || btn.classList.contains('active')) return;
      updateConfig(key, btn.dataset.val);
    });
  }
}

refreshStatus();
