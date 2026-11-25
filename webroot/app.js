'use strict';

// Always invoke webui_ctl.sh with its absolute module path (id=coresurface).
const CTL_SCRIPT = '/system/bin/sh /data/adb/modules/coresurface/lib/webui_ctl.sh';
const LIVE_KEYS = new Set(['FEAT_MOTION_PROFILE', 'FEAT_SURGICAL_GUARD']);

let execCounter = 0;

function ksuExec(command) {
  if (!window.ksu || typeof window.ksu.exec !== 'function') {
    return Promise.reject(new Error('Buka WebUI ini melalui KernelSU-Next Manager'));
  }

  return new Promise((resolve, reject) => {
    const cbName = '__csExec' + (++execCounter);
    const cbHandle = 'window.' + cbName;

    const timer = setTimeout(() => {
      delete window[cbName];
      reject(new Error('Perintah shell timeout (30 detik)'));
    }, 30000);

    window[cbName] = (code, stdout, stderr) => {
      clearTimeout(timer);
      delete window[cbName];
      const out = String(stdout == null ? '' : stdout).trim();
      const err = String(stderr == null ? '' : stderr).trim();
      if (Number(code) !== 0) {
        reject(new Error(err || out || ('Shell keluar dengan kode ' + code)));
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
  if (p === 'silk') return 'iOS · ColorOS 17 Silk';
  if (p === 'hyperos4') return 'HyperOS 4 Flagship';
  if (p === 'off' || p === '0') return 'Stock ROM';
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
      el.textContent = 'Aktif';
      break;
    case 'pending_lsposed':
      el.classList.add('v-info');
      el.textContent = 'Aktifkan di LSPosed';
      break;
    case 'ignored_by_rom':
      el.classList.add('v-danger');
      el.textContent = 'Ditolak ROM';
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

async function refreshStatus() {
  const summary = document.getElementById('summary-list');
  try {
    const raw = await ksuExec(CTL_SCRIPT + ' status');
    const { kv, logs } = parseStatus(raw);
    if (!kv.rom_family) {
      throw new Error('Respons status tidak lengkap');
    }

    // Watchdog badge
    const wdBadge = document.getElementById('watchdog-badge');
    const safeBanner = document.getElementById('safemode-banner');
    const isDisabled = kv.module_disabled === '1' || kv.watchdog_status === 'safe_mode_disabled';
    wdBadge.className = 'badge';
    safeBanner.classList.add('hidden');
    if (isDisabled) {
      wdBadge.classList.add('badge-danger');
      wdBadge.textContent = 'Watchdog: Safe-Mode';
      safeBanner.classList.remove('hidden');
    } else if (kv.watchdog_status === 'healthy') {
      wdBadge.classList.add('badge-ok');
      wdBadge.textContent = 'Watchdog: Healthy';
    } else {
      wdBadge.classList.add('badge-warn');
      wdBadge.textContent = 'Watchdog: ' + (kv.watchdog_status || 'unknown');
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
      compatBadge.textContent = 'Skor: ' + pct + '% (' + (kv.verify_feat_verified || '0') + '/' + evalCount + ')';
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
      autoHint.textContent = 'Terdeteksi: ' + kv.detected_tier_label;
    }
    const tierPill = document.getElementById('active-tier-pill');
    tierPill.className = 'pill on';
    tierPill.textContent = kv.eff_tier_label || kv.eff_tier || 'Auto';

    // Controls
    setSegmentValue('FEAT_MOTION_PROFILE', kv.cfg_feat_motion_profile || 'hyperos4');
    setSegmentValue('FEAT_SURGICAL_GUARD', kv.cfg_feat_surgical_guard || '1');
    setSegmentValue('FEAT_AOD_UNLOCK', kv.cfg_feat_aod_unlock || '1');

    renderVerifyPill('FEAT_MOTION_PROFILE', kv.verify_feat_motion_profile, false);
    renderVerifyPill('FEAT_SURGICAL_GUARD', kv.verify_feat_surgical_guard, false);
    renderVerifyPill('FEAT_AOD_UNLOCK', kv.verify_feat_aod_unlock, pendingSet.has('FEAT_AOD_UNLOCK'));

    // Compact Summary
    const romStr = (kv.rom_family || '').toUpperCase() + ' ' + (kv.rom_version || '') + ' · SDK ' + (kv.android_sdk || '-');
    const blurMode = kv.eff_feat_adv_textures === '1' ? 'Blur Penuh (HOS3 Safe)' : 'Blur Standar (No Adv. Textures)';
    const stats = 'Folme: ' + (kv.verify_engine_folme_hooks || '0')
      + ' · Gates: ' + (kv.verify_engine_native_gates || '0')
      + ' · Springs: ' + (kv.verify_engine_springs || '0')
      + ' · Recents Fix: ' + (kv.verify_engine_recents || '0')
      + ' · AOD Gates: ' + (kv.verify_engine_aod_gates || '0');

    summary.replaceChildren(
      makeKvRow('ROM & RAM', romStr + ' · ' + (kv.ram_mb || '0') + ' MB'),
      makeKvRow('Mode Blur & Warna', blurMode + ' · Custom Color ON'),
      makeKvRow('Profil Animasi', formatMotion(kv.verify_engine_motion && kv.verify_engine_motion !== 'N/A' ? kv.verify_engine_motion : kv.eff_feat_motion_profile)),
      makeKvRow('Statistik Live', active ? stats : 'Aktifkan CoreSurface Engine di LSPosed'),
      makeKvRow('Base Layer 1', 'Props ' + (kv.verify_props_matched || '0') + '/' + (kv.verify_props_total || '0')
        + ' · XML ' + (kv.verify_xml_mount || kv.xml_status || '-')
        + ' · RRO ' + (kv.verify_rro_active || '0') + '/' + (kv.verify_rro_total || kv.rro_staged_count || '0'))
    );

    document.getElementById('diag-log').textContent = logs.join('\n') || 'Belum ada entri log.';
  } catch (err) {
    summary.replaceChildren(makeKvRow('Kesalahan', err.message));
    setToast('Gagal membaca status: ' + err.message);
  }
}

async function selectTier(tier) {
  setToast('Menyimpan Mode Tier "' + tier + '"…');
  try {
    const res = await ksuExec(CTL_SCRIPT + ' tier ' + tier);
    document.getElementById('reboot-banner').classList.remove('hidden');
    setToast(res);
    await refreshStatus();
  } catch (err) {
    setToast('Gagal mengubah tier: ' + err.message);
  }
}

async function updateConfig(key, value) {
  const isLive = LIVE_KEYS.has(key);
  setToast((isLive ? 'Menerapkan LIVE ' : 'Menyimpan ') + key + '=' + value + '…');
  try {
    const res = await ksuExec(CTL_SCRIPT + ' set ' + key + ' ' + value);
    if (!isLive) {
      document.getElementById('reboot-banner').classList.remove('hidden');
    }
    setToast(res);
    await refreshStatus();
  } catch (err) {
    setToast('Gagal menyimpan: ' + err.message);
  }
}

document.getElementById('btn-refresh').addEventListener('click', () => {
  setToast('');
  refreshStatus();
});

document.getElementById('btn-reset-safemode').addEventListener('click', async () => {
  setToast('Mereset Safe-Mode…');
  try {
    setToast(await ksuExec(CTL_SCRIPT + ' reset-safemode'));
    await refreshStatus();
  } catch (err) {
    setToast('Gagal reset: ' + err.message);
  }
});

document.getElementById('btn-hot-sync').addEventListener('click', async () => {
  setToast('Menjalankan verifikasi ulang…');
  try {
    setToast(await ksuExec(CTL_SCRIPT + ' hot-sync'));
    await refreshStatus();
  } catch (err) {
    setToast('Gagal verifikasi: ' + err.message);
  }
});

document.getElementById('btn-install-engine').addEventListener('click', async () => {
  setToast('Memasang CoreSurfaceEngine.apk…');
  try {
    setToast(await ksuExec(CTL_SCRIPT + ' install-engine'));
    await refreshStatus();
  } catch (err) {
    setToast('Gagal memasang APK: ' + err.message);
  }
});

document.getElementById('btn-export-diag').addEventListener('click', async () => {
  setToast('Menyiapkan laporan diagnostik…');
  try {
    const report = await ksuExec(CTL_SCRIPT + ' diag-report');
    const wrap = document.getElementById('diag-export-wrap');
    const box = document.getElementById('diag-export-box');
    box.value = report;
    wrap.classList.remove('hidden');
    if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
      try {
        await navigator.clipboard.writeText(report);
        setToast('Laporan diagnostik disalin ke clipboard.');
        return;
      } catch (_clipErr) {
        // Fallback to textarea
      }
    }
    box.focus();
    box.select();
    setToast('Laporan siap disalin dari kotak teks di bawah.');
  } catch (err) {
    setToast('Gagal membuat laporan: ' + err.message);
  }
});

for (const btn of document.querySelectorAll('.btn-tier')) {
  btn.addEventListener('click', () => {
    if (btn.classList.contains('active')) return;
    selectTier(btn.dataset.tier);
  });
}

for (const group of document.querySelectorAll('.seg-group')) {
  const key = group.dataset.key;
  for (const btn of group.querySelectorAll('button')) {
    btn.addEventListener('click', () => {
      if (btn.classList.contains('active')) return;
      updateConfig(key, btn.dataset.val);
    });
  }
}

refreshStatus();
