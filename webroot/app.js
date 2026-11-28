'use strict';

const CTL_SCRIPT = '/data/adb/modules/coresurface/lib/webui_ctl.sh';
let uiBusy = false;

function ksuExec(cmd) {
  return new Promise((resolve, reject) => {
    if (typeof window.ksu === 'object' && typeof window.ksu.exec === 'function') {
      const cbName = '__cs_cb_' + Date.now() + '_' + Math.floor(Math.random() * 100000);
      window[cbName] = (errno, stdout, stderr) => {
        delete window[cbName];
        if (errno === 0) {
          resolve(stdout || '');
        } else {
          reject(new Error((stderr || stdout || ('Exit code ' + errno)).trim()));
        }
      };
      try {
        window.ksu.exec(cmd, '{}', cbName);
      } catch (err) {
        delete window[cbName];
        reject(err);
      }
      return;
    }

    if (typeof window.exec === 'function') {
      Promise.resolve(window.exec(cmd))
        .then((res) => {
          if (typeof res === 'string') {
            resolve(res);
          } else if (res && (res.errno === 0 || res.code === 0)) {
            resolve(res.stdout || '');
          } else {
            reject(new Error((res && (res.stderr || res.stdout)) || 'Command failed'));
          }
        })
        .catch(reject);
      return;
    }

    reject(new Error('KernelSU / MMRL WebUI API unavailable.'));
  });
}

function setBusy(busy) {
  uiBusy = busy;
  for (const el of document.querySelectorAll('button')) {
    el.disabled = busy;
  }
}

function parseStatus(raw) {
  const kv = {};
  const logs = [];
  let inLog = false;
  for (const line of String(raw || '').split(/\r?\n/)) {
    if (line === 'log_start') {
      inLog = true;
      continue;
    }
    if (line === 'log_end') {
      inLog = false;
      continue;
    }
    if (inLog) {
      if (line.trim()) logs.push(line);
      continue;
    }
    const idx = line.indexOf('=');
    if (idx > 0) {
      kv[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
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
  v.textContent = value;
  row.appendChild(k);
  row.appendChild(v);
  return row;
}

function renderVerifyPill(featKey, status, isPending, extraLabel) {
  const el = document.getElementById('verify-' + featKey);
  if (!el) return;
  el.className = 'v-pill';

  if (isPending) {
    el.classList.add('v-info');
    el.textContent = 'Pending Reboot';
    return;
  }

  switch (status) {
    case 'verified_active':
      el.classList.add('v-ok');
      el.textContent = extraLabel || 'Active';
      break;
    case 'native_passthrough':
      el.classList.add('v-ok');
      el.textContent = featKey === 'FEAT_LEICA_BRIDGE' ? 'Native Leica' : 'Native Passthrough';
      break;
    case 'companion_active':
      el.classList.add('v-ok');
      el.textContent = 'Companion Active';
      break;
    case 'companion_missing':
      el.classList.add('v-warn');
      el.textContent = 'Companion Not Installed';
      break;
    case 'auto_reverted':
      el.classList.add('v-danger');
      el.textContent = 'Auto-Reverted';
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
  const normalized = (val === 'auto') ? '1' : val;
  for (const btn of group.querySelectorAll('button')) {
    btn.classList.toggle('active', btn.dataset.val === normalized);
  }
}

function setToast(msg) {
  document.getElementById('toast-msg').textContent = msg || '';
}

function formatBoolCap(val) {
  return val === '1' ? 'Supported' : 'Not Advertised';
}

function formatIsp(isp) {
  switch (isp) {
    case 'snapdragon': return 'Qualcomm Snapdragon ISP';
    case 'mediatek': return 'MediaTek Imagiq ISP';
    case 'xring': return 'Xiaomi XRING ISP';
    default: return 'Generic Android Camera2';
  }
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

    // Camera Watchdog auto-revert banner
    const camWdBanner = document.getElementById('cam-watchdog-banner');
    const camWdReason = document.getElementById('cam-watchdog-reason');
    if (camWdBanner) {
      const isCamReverted = kv.cam_watchdog_status === 'auto_reverted';
      camWdBanner.classList.toggle('hidden', !isCamReverted);
      if (isCamReverted && camWdReason) {
        camWdReason.textContent = 'Detected ' + (kv.cam_crash_count || '2+')
          + ' crashes in com.android.camera (' + (kv.cam_watchdog_reason || 'crash_loop')
          + '). Disabled Leica Bridge & reverted safely to Stock Camera + Pro Engine.';
      }
    }

    // Metamodule RRO warning banner
    const bugsList = (kv.os_bugs_csv || '').split(',').map((s) => s.trim()).filter(Boolean);
    const metaBanner = document.getElementById('metamodule-banner');
    if (metaBanner) {
      metaBanner.classList.toggle('hidden', !bugsList.includes('MISSING_META_OVERLAYFS'));
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
    setSegmentValue('FEAT_AOD_UNLOCK', kv.cfg_feat_aod_unlock || '1');
    setSegmentValue('FEAT_FLAGSHIP_AUDIO', kv.eff_feat_flagship_audio === '1' ? '1' : '0');
    setSegmentValue('FEAT_FLAGSHIP_SUITE', kv.eff_feat_flagship_suite === '1' ? '1' : '0');
    setSegmentValue('FEAT_CAMERA_PRO', kv.cfg_feat_camera_pro === '0' ? '0' : '1');
    setSegmentValue('FEAT_LEICA_BRIDGE', kv.cfg_feat_leica_bridge === '0' ? '0' : '1');

    const camCapsCount = kv.cam_pro_cap_count || '1';
    renderVerifyPill('FEAT_AOD_UNLOCK', kv.verify_feat_aod_unlock, pendingSet.has('FEAT_AOD_UNLOCK'));
    renderVerifyPill('FEAT_FLAGSHIP_AUDIO', kv.verify_feat_flagship_audio, pendingSet.has('FEAT_FLAGSHIP_AUDIO'));
    renderVerifyPill('FEAT_FLAGSHIP_SUITE', kv.verify_feat_flagship_suite, pendingSet.has('FEAT_FLAGSHIP_SUITE'));
    renderVerifyPill(
      'FEAT_CAMERA_PRO',
      kv.verify_feat_camera_pro,
      pendingSet.has('FEAT_CAMERA_PRO'),
      'Active · ' + camCapsCount + ' caps'
    );
    renderVerifyPill(
      'FEAT_LEICA_BRIDGE',
      kv.verify_feat_leica_bridge || (kv.cam_leica_source === 'native' ? 'native_passthrough' : (kv.cam_leica_source === 'companion' ? 'companion_active' : 'companion_missing')),
      pendingSet.has('FEAT_LEICA_BRIDGE')
    );

    // Honest Leica Bridge dynamic description
    const leicaDesc = document.getElementById('leica-bridge-desc');
    if (leicaDesc) {
      if (kv.cam_leica_source === 'native') {
        leicaDesc.textContent = 'Factory Native Leica camera detected — protected in Never-Downgrade Passthrough with 0 KB Crash Inspector.';
      } else if (kv.cam_leica_source === 'companion') {
        leicaDesc.textContent = 'Active Leica Companion detected (' + (kv.cam_companion_name || kv.cam_companion_id)
          + ') — guarded by CoreSurface 0 KB Camera Crash Inspector & 1-tap Safe Rollback.';
      } else {
        leicaDesc.textContent = 'Pro Engine active on stock MiuiCamera. Authentic/Vibrant Leica LUTs require an optional SDK/SoC-matched Leica Companion Pack (* currently in development).';
      }
    }

    // Collapsible Camera Hardware Inspector
    const camList = document.getElementById('cam-inspector-list');
    if (camList) {
      const leicaSourceLabel = kv.cam_leica_source === 'native'
        ? 'Native Leica Flagship'
        : (kv.cam_leica_source === 'companion'
          ? ('Companion (' + (kv.cam_companion_name || kv.cam_companion_id) + ')')
          : 'Stock Non-Leica APK');
      const wdLabel = (kv.cam_watchdog_status || 'healthy') + ' (crashes: ' + (kv.cam_crash_count || '0') + ')';
      camList.replaceChildren(
        makeKvRow('Camera2 HAL Level', kv.cam_hal_level || 'UNKNOWN'),
        makeKvRow('SoC ISP', formatIsp(kv.cam_isp)),
        makeKvRow('Detected Camera IDs', (kv.cam_lens_count || '0') + ' sensor(s)'),
        makeKvRow('RAW / DNG Hardware', formatBoolCap(kv.cam_has_raw)),
        makeKvRow('Manual Sensor / Pro Aids', formatBoolCap(kv.cam_has_manual)),
        makeKvRow('Video 4K@60 / 10-bit', (kv.cam_has_4k60 === '1' ? '4K60 Yes' : '4K60 No') + ' · ' + (kv.cam_has_10bit === '1' ? '10-bit Yes' : '10-bit No')),
        makeKvRow('Active Pro Unlocks', kv.cam_active_unlocks || 'Pro Utilities'),
        makeKvRow('Stock Camera APK', kv.cam_apk_version || 'unknown'),
        makeKvRow('Leica Status', leicaSourceLabel),
        makeKvRow('Companion Match Profile', kv.cam_readiness_profile || '-'),
        makeKvRow('Camera Watchdog', wdLabel)
      );
    }

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
    const camSummaryStr = 'HAL ' + (kv.cam_hal_level || 'UNKNOWN')
      + ' · ' + (kv.cam_isp || 'generic').toUpperCase()
      + ' · Leica ' + (kv.cam_leica_source || 'none');
    const bugSummary = (kv.os_bugs_mitigated || '0') + '/' + (kv.os_bugs_detected || '0') + ' mitigated'
      + (kv.os_bugs_csv ? (' (' + kv.os_bugs_csv.split(',').slice(0, 3).join(', ') + ')') : '');

    summary.replaceChildren(
      makeKvRow('ROM & RAM', romStr + ' · ' + (kv.ram_mb || '0') + ' MB'),
      makeKvRow('Blur & Color', blurMode + ' · ' + colorMode),
      makeKvRow('Audio & Suite', audioSuiteStr),
      makeKvRow('Camera Engine', camSummaryStr),
      makeKvRow('OS Bug Logic', bugSummary),
      makeKvRow('Standalone Layer 1', 'Props ' + (kv.verify_props_matched || '0') + '/' + (kv.verify_props_total || '0')
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
  await runAction('Saving ' + key + '=' + value + '…', async () => {
    try {
      const res = await ksuExec(CTL_SCRIPT + ' set ' + key + ' ' + value);
      document.getElementById('reboot-banner').classList.remove('hidden');
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

document.getElementById('btn-cam-health').addEventListener('click', () => {
  runAction('Running Camera2 Hardware & Crash Check…', async () => {
    try {
      setToast(await ksuExec(CTL_SCRIPT + ' camera-health'));
      await refreshStatus();
    } catch (err) {
      setToast('Camera Health Check failed: ' + err.message);
    }
  });
});

document.getElementById('btn-cam-rollback').addEventListener('click', () => {
  runAction('Applying Camera Safe Rollback…', async () => {
    try {
      setToast(await ksuExec(CTL_SCRIPT + ' camera-rollback'));
      document.getElementById('reboot-banner').classList.remove('hidden');
      await refreshStatus();
    } catch (err) {
      setToast('Camera Safe Rollback failed: ' + err.message);
    }
  });
});

document.getElementById('btn-save-diag').addEventListener('click', () => {
  runAction('Exporting diagnostic file…', async () => {
    try {
      const msg = await ksuExec(CTL_SCRIPT + ' export-diag');
      setToast((msg || 'Diagnostic exported to /sdcard/Download/coresurface-diag.txt').trim());
    } catch (err) {
      setToast('Export failed: ' + err.message);
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
