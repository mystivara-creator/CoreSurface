'use strict';

// Always invoke webui_ctl.sh with its absolute module path (id=coresurface).
const CTL_SCRIPT = '/system/bin/sh /data/adb/modules/coresurface/lib/webui_ctl.sh';

const LIVE_ENGINE_KEYS = new Set([
  'FEAT_MOTION_PROFILE',
  'FEAT_NATIVE_TIER',
  'FEAT_SURGICAL_GUARD',
  'FEAT_THERMAL_LOD'
]);

const FEATURE_KEYS = [
  'FEAT_MOTION_PROFILE',
  'FEAT_NATIVE_TIER',
  'FEAT_SURGICAL_GUARD',
  'FEAT_THERMAL_LOD',
  'FEAT_BLUR',
  'FEAT_ANIMATIONS',
  'FEAT_XML_PATCHER',
  'FEAT_RRO_OVERLAYS',
  'FEAT_VIDEO_DEPTH',
  'FEAT_MULTITASK',
  'FEAT_DISPLAY_HZ',
  'FEAT_COLOR_EXPERT',
  'FEAT_GALLERY_PRO',
  'FEAT_AOD_UNLOCK'
];

const OPT_IN_KEYS = new Set(['FEAT_COLOR_EXPERT', 'FEAT_GALLERY_PRO', 'FEAT_AOD_UNLOCK']);

let execCounter = 0;

/**
 * Execute a shell command via KernelSU-Next 2-argument async callback API.
 * Avoids ShellUtils.fastCmd truncation to only the last stdout line.
 */
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

function parseStatusOutput(raw) {
  const kv = {};
  const rros = [];
  const props = [];
  const overridden = [];
  const logs = [];
  let section = 'kv';

  for (const line of raw.split(/\r?\n/)) {
    if (line === 'rro_start') { section = 'rro'; continue; }
    if (line === 'rro_end') { section = 'kv'; continue; }
    if (line === 'props_start') { section = 'props'; continue; }
    if (line === 'props_end') { section = 'kv'; continue; }
    if (line === 'overridden_start') { section = 'overridden'; continue; }
    if (line === 'overridden_end') { section = 'kv'; continue; }
    if (line === 'log_start') { section = 'log'; continue; }
    if (line === 'log_end') { section = 'kv'; continue; }

    if (section === 'rro') {
      if (line.trim()) rros.push(line.trim());
      continue;
    }
    if (section === 'props') {
      if (line.trim()) props.push(line.trim());
      continue;
    }
    if (section === 'overridden') {
      if (line.trim()) overridden.push(line.trim());
      continue;
    }
    if (section === 'log') {
      logs.push(line);
      continue;
    }

    const idx = line.indexOf('=');
    if (idx > 0) {
      kv[line.slice(0, idx)] = line.slice(idx + 1);
    }
  }

  return { kv, rros, props, overridden, logs };
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

function formatMotionProfile(profile) {
  if (profile === 'silk') return 'iOS · ColorOS 17 Silk Fluid';
  if (profile === 'hyperos4') return 'HyperOS 4 Flagship';
  if (profile === 'off' || profile === '0') return 'Stock ROM (OFF)';
  return profile || 'N/A';
}

function renderWatchdogBadge(kv) {
  const badge = document.getElementById('watchdog-badge');
  const safeBanner = document.getElementById('safemode-banner');
  const safeReason = document.getElementById('safemode-reason');
  const status = kv.watchdog_status || 'unknown';
  const isDisabled = kv.module_disabled === '1' || status === 'safe_mode_disabled';

  badge.className = 'badge';
  safeBanner.classList.add('hidden');

  if (isDisabled) {
    badge.classList.add('badge-danger');
    badge.textContent = 'Watchdog: Safe-Mode Disabled';
    safeBanner.classList.remove('hidden');
    if (kv.watchdog_reason && kv.watchdog_reason !== 'none') {
      safeReason.textContent = 'Alasan: ' + kv.watchdog_reason + '. Disarankan matikan fitur eksperimental sebelum mengaktifkan kembali.';
    }
  } else if (status === 'healthy') {
    badge.classList.add('badge-ok');
    badge.textContent = 'Watchdog: Healthy';
  } else if (status === 'unsupported_rom') {
    badge.classList.add('badge-warn');
    badge.textContent = 'ROM Tidak Didukung (Idle)';
  } else if (status === 'pending_reboot') {
    badge.classList.add('badge-warn');
    badge.textContent = 'Watchdog: Menunggu Reboot';
  } else if (status === 'degraded') {
    badge.classList.add('badge-danger');
    badge.textContent = 'Watchdog: Degraded (Strike ' + (kv.boot_strikes || '?') + '/2)';
  } else {
    badge.classList.add('badge-neutral');
    badge.textContent = 'Watchdog: ' + status;
  }
}

function renderEngineSummary(kv) {
  const badge = document.getElementById('engine-badge');
  const lodBadge = document.getElementById('engine-lod-badge');
  const container = document.getElementById('engine-summary');

  const installed = kv.verify_engine_installed === '1';
  const active = kv.verify_engine_active === '1';
  const motion = kv.verify_engine_motion || kv.eff_feat_motion_profile || 'N/A';
  const lod = kv.verify_engine_lod || 'N/A';

  badge.className = 'badge';
  lodBadge.className = 'pill';

  if (active) {
    badge.classList.add('badge-ok');
    badge.textContent = 'Engine: Native Motion Active';
    lodBadge.classList.add('on');
    lodBadge.textContent = 'LOD: ' + lod;
  } else if (installed) {
    badge.classList.add('badge-warn');
    badge.textContent = 'Engine: Enable in LSPosed';
    lodBadge.classList.add('warn');
    lodBadge.textContent = 'Pending LSPosed';
  } else {
    badge.classList.add('badge-neutral');
    badge.textContent = 'Engine: Belum Terpasang';
    lodBadge.textContent = 'Not Installed';
  }

  container.replaceChildren(
    makeKvRow('CoreSurfaceEngine.apk', installed ? 'Terpasang' : 'Belum terpasang (klik tombol di bawah)'),
    makeKvRow('LSPosed Runtime Hook', active ? 'Aktif (Zero-Binder IPC · 100% Original UI)' : 'Belum aktif di LSPosed Manager'),
    makeKvRow('Profil Fisika Folme', active ? formatMotionProfile(motion) : 'Menunggu LSPosed (' + formatMotionProfile(kv.eff_feat_motion_profile) + ')'),
    makeKvRow('Thermal-Adaptive Motion', lod),
    makeKvRow('Hooks Terikat', kv.verify_engine_hooks || 'Belum ada'),
    makeKvRow('Statistik Live', 'Native Gates: ' + (kv.verify_engine_native_gates || '0')
      + ' · Folme Hooks: ' + (kv.verify_engine_folme_hooks || '0')
      + ' · Springs Tuned: ' + (kv.verify_engine_springs || '0')
      + ' · Toast Guard: ' + (kv.verify_engine_toasts || '0')
      + ' · Recents Guard: ' + (kv.verify_engine_recents || '0'))
  );
}

function renderCompatBadge(kv) {
  const badge = document.getElementById('compat-badge');
  const pct = kv.compat_score_pct;
  const evalCount = Number(kv.verify_feat_evaluated || 0);

  if (!pct || evalCount <= 0) {
    badge.classList.add('hidden');
    return;
  }

  const num = Number(pct);
  badge.className = 'badge';
  if (num >= 85) {
    badge.classList.add('badge-ok');
  } else if (num >= 50) {
    badge.classList.add('badge-warn');
  } else {
    badge.classList.add('badge-danger');
  }
  badge.textContent = 'Skor ROM: ' + pct + '% (' + (kv.verify_feat_verified || '0') + '/' + evalCount + ')';
}

function setSegmentValue(key, val) {
  const group = document.querySelector('.seg-group[data-key="' + key + '"]');
  if (!group) return;
  for (const btn of group.querySelectorAll('button')) {
    btn.classList.toggle('active', btn.dataset.val === val);
  }
}

function renderVerifyPill(featKey, verifyStatus, isPending, effValue) {
  const el = document.getElementById('verify-' + featKey);
  if (!el) return;

  el.className = 'v-pill';

  if (isPending && !LIVE_ENGINE_KEYS.has(featKey)) {
    el.classList.add('v-info');
    el.textContent = 'Pending Reboot';
    return;
  }

  switch (verifyStatus) {
    case 'verified_active':
      el.classList.add('v-ok');
      el.textContent = 'Verified Active';
      break;
    case 'pending_lsposed':
      el.classList.add('v-info');
      el.textContent = 'Enable in LSPosed';
      break;
    case 'ignored_by_rom':
      el.classList.add('v-danger');
      el.textContent = 'Ignored by ROM';
      break;
    case 'skipped':
      el.classList.add('v-warn');
      el.textContent = 'Skipped';
      break;
    case 'disabled':
      el.classList.add('v-neutral');
      el.textContent = 'Disabled';
      break;
    default:
      if (effValue && effValue !== '0' && effValue !== 'off') {
        el.classList.add('v-info');
        el.textContent = LIVE_ENGINE_KEYS.has(featKey) ? 'Live Ready' : 'Pending Verify';
      } else {
        el.classList.add('v-neutral');
        el.textContent = 'Skipped';
      }
      break;
  }
}

function renderXmlSummary(kv) {
  const container = document.getElementById('xml-summary');
  const badge = document.getElementById('xml-mount-badge');
  const mountVerify = kv.verify_xml_mount || '';
  const xmlStatus = kv.xml_status || 'skipped';

  badge.className = 'pill';
  if (mountVerify === 'active') {
    badge.classList.add('on');
    badge.textContent = 'Verified Mounted';
  } else if (mountVerify === 'not_mounted') {
    badge.classList.add('danger');
    badge.textContent = 'Ignored by ROM';
  } else if (xmlStatus === 'mounted') {
    badge.classList.add('on');
    badge.textContent = 'Mounted';
  } else if (xmlStatus === 'disabled') {
    badge.textContent = 'Disabled';
  } else {
    badge.classList.add('warn');
    badge.textContent = 'Skipped';
  }

  container.replaceChildren(
    makeKvRow('XML Asli Terdeteksi', kv.xml_source && kv.xml_source !== 'none' ? kv.xml_source : 'Tidak ditemukan'),
    makeKvRow('Tag Ditambal', (kv.xml_patched_tags || '0') + ' tag'),
    makeKvRow('Status Mount', xmlStatus + (kv.xml_reason && kv.xml_reason !== 'none' ? ' (' + kv.xml_reason + ')' : '')),
    makeKvRow('Verifikasi /proc/mounts', mountVerify || 'Menunggu verifikasi')
  );
}

function renderRroSummary(kv, rros) {
  const container = document.getElementById('rro-summary');
  const badge = document.getElementById('rro-summary-badge');
  const vStatus = kv.verify_feat_rro_overlays || '';
  const staged = kv.rro_staged_count || String(rros.length);

  badge.className = 'pill';
  if (vStatus === 'verified_active') {
    badge.classList.add('on');
    badge.textContent = 'Verified Active (' + (kv.verify_rro_active || '0') + '/' + (kv.verify_rro_total || staged) + ')';
  } else if (vStatus === 'ignored_by_rom') {
    badge.classList.add('danger');
    badge.textContent = 'Ignored by ROM';
  } else if (vStatus === 'disabled' || kv.rro_status === 'disabled') {
    badge.textContent = 'Disabled';
  } else if (kv.rro_status === 'staged') {
    badge.classList.add('on');
    badge.textContent = 'Staged (' + staged + ')';
  } else {
    badge.classList.add('warn');
    badge.textContent = 'Skipped';
  }

  const apkNames = rros.map((item) => item.split('|')[0]).filter(Boolean);
  container.replaceChildren(
    makeKvRow('RRO Staging', (kv.rro_status || 'skipped') + ' (' + staged + ' APK)'),
    makeKvRow('Aktif (cmd overlay list)', (kv.verify_rro_active || '0') + ' / ' + (kv.verify_rro_total || staged)),
    makeKvRow('Lockscreen Video Depth', kv.verify_feat_video_depth || kv.video_depth_status || 'disabled'),
    makeKvRow('Paket Ter-stage', apkNames.length > 0 ? apkNames.join(', ') : 'Tidak ada')
  );
}

function renderPropsList(props, kv) {
  const list = document.getElementById('props-list');
  const count = document.getElementById('props-count');
  const verified = document.getElementById('props-verified');
  count.textContent = String(props.length);
  verified.textContent = (kv.verify_props_matched || '0') + '/' + (kv.verify_props_total || String(props.length));
  list.replaceChildren();

  if (props.length === 0) {
    const empty = document.createElement('li');
    empty.className = 'muted';
    empty.textContent = 'Belum ada properti yang diterapkan pada boot ini.';
    list.appendChild(empty);
    return;
  }

  for (const entry of props) {
    const sep = entry.indexOf('|');
    const feat = sep > 0 ? entry.slice(0, sep).replace(/^FEAT_/, '') : 'prop';
    const pair = sep > 0 ? entry.slice(sep + 1) : entry;

    const li = document.createElement('li');
    const tag = document.createElement('span');
    tag.className = 'prop-tier';
    tag.textContent = feat;
    const text = document.createElement('span');
    text.textContent = pair;
    li.appendChild(tag);
    li.appendChild(text);
    list.appendChild(li);
  }
}

function renderOverriddenList(overridden) {
  const section = document.getElementById('overridden-section');
  const list = document.getElementById('overridden-list');
  const count = document.getElementById('overridden-count');

  count.textContent = String(overridden.length);
  list.replaceChildren();

  if (overridden.length === 0) {
    section.classList.add('hidden');
    return;
  }

  section.classList.remove('hidden');
  for (const entry of overridden) {
    const parts = entry.split('|');
    const feat = (parts[0] || 'prop').replace(/^FEAT_/, '');
    const key = parts[1] || '';
    const expected = parts[2] || '';
    const actual = parts[3] || '';

    const li = document.createElement('li');
    const tag = document.createElement('span');
    tag.className = 'prop-tier prop-warn';
    tag.textContent = feat;
    const text = document.createElement('span');
    text.textContent = key + ' (set=' + expected + ', actual=' + actual + ')';
    li.appendChild(tag);
    li.appendChild(text);
    list.appendChild(li);
  }
}

function setToast(msg) {
  document.getElementById('toast-msg').textContent = msg || '';
}

function defaultFeatureValue(key) {
  if (key === 'FEAT_MOTION_PROFILE') return 'hyperos4';
  return OPT_IN_KEYS.has(key) ? '0' : 'auto';
}

async function refreshStatus() {
  const envList = document.getElementById('env-list');
  try {
    const raw = await ksuExec(CTL_SCRIPT + ' status');
    const { kv, rros, props, overridden, logs } = parseStatusOutput(raw);

    if (!kv.rom_family || !kv.ram_tier) {
      throw new Error('Respons status tidak lengkap dari webui_ctl.sh');
    }

    renderWatchdogBadge(kv);
    renderEngineSummary(kv);
    renderCompatBadge(kv);

    const cfBadge = document.getElementById('coreflow-badge');
    cfBadge.classList.toggle('hidden', kv.coreflow_guard !== 'active');

    const pendingSet = new Set(
      (kv.pending_keys || '').split(',').map((s) => s.trim()).filter(Boolean)
    );
    document.getElementById('reboot-banner').classList.toggle('hidden', pendingSet.size === 0);

    const romLabel = kv.rom_family === 'unsupported'
      ? 'Unsupported (Non-HyperOS/MIUI)'
      : kv.rom_family.toUpperCase() + ' · ' + (kv.rom_version || 'Unknown');

    envList.replaceChildren(
      makeKvRow('ROM Terdeteksi', romLabel),
      makeKvRow('Android SDK', kv.android_sdk || '-'),
      makeKvRow('RAM Aktual & Tier', (kv.ram_mb || '0') + ' MB (' + (kv.ram_tier_label || '-') + ')'),
      makeKvRow('Boot Strikes', (kv.boot_strikes || '0') + ' / 2'),
      makeKvRow('CoreFlow-Engine', kv.coreflow_guard === 'active' ? 'Thermal Guard Active' : 'Tidak Terdeteksi')
    );

    renderXmlSummary(kv);
    renderRroSummary(kv, rros);

    for (const key of FEATURE_KEYS) {
      const lower = key.toLowerCase();
      setSegmentValue(key, kv['cfg_' + lower] || defaultFeatureValue(key));
      renderVerifyPill(key, kv['verify_' + lower] || '', pendingSet.has(key), kv['eff_' + lower] || '0');
    }

    renderOverriddenList(overridden);
    renderPropsList(props, kv);
    document.getElementById('diag-log').textContent = logs.join('\n') || 'Belum ada entri log.';
  } catch (err) {
    envList.replaceChildren(makeKvRow('Kesalahan', err.message));
    setToast('Gagal membaca status: ' + err.message);
  }
}

async function updateConfig(key, value) {
  const isLive = LIVE_ENGINE_KEYS.has(key);
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

async function applyPreset(presetName) {
  setToast('Menerapkan preset "' + presetName + '"…');
  try {
    const res = await ksuExec(CTL_SCRIPT + ' preset ' + presetName);
    document.getElementById('reboot-banner').classList.remove('hidden');
    setToast(res);
    await refreshStatus();
  } catch (err) {
    setToast('Gagal menerapkan preset: ' + err.message);
  }
}

async function runHotSync() {
  setToast('Menjalankan Hot-Apply Motion Engine + settings & verifikasi ulang…');
  try {
    const res = await ksuExec(CTL_SCRIPT + ' hot-sync');
    setToast(res);
    await refreshStatus();
  } catch (err) {
    setToast('Gagal Hot-Apply: ' + err.message);
  }
}

async function installEngineApk() {
  setToast('Memasang CoreSurfaceEngine.apk…');
  try {
    const res = await ksuExec(CTL_SCRIPT + ' install-engine');
    setToast(res);
    await refreshStatus();
  } catch (err) {
    setToast('Gagal memasang Engine APK: ' + err.message);
  }
}

async function exportDiagReport() {
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
        // Fallback to selectable textarea below
      }
    }
    box.focus();
    box.select();
    setToast('Laporan diagnostik siap disalin dari kotak teks di bawah.');
  } catch (err) {
    setToast('Gagal membuat laporan: ' + err.message);
  }
}

async function resetSafeMode() {
  setToast('Mereset Safe-Mode…');
  try {
    const res = await ksuExec(CTL_SCRIPT + ' reset-safemode');
    document.getElementById('reboot-banner').classList.remove('hidden');
    setToast(res);
    await refreshStatus();
  } catch (err) {
    setToast('Gagal reset Safe-Mode: ' + err.message);
  }
}

document.getElementById('btn-refresh').addEventListener('click', () => {
  setToast('');
  refreshStatus();
});

document.getElementById('btn-reset-safemode').addEventListener('click', resetSafeMode);
document.getElementById('btn-hot-sync').addEventListener('click', runHotSync);
document.getElementById('btn-install-engine').addEventListener('click', installEngineApk);
document.getElementById('btn-export-diag').addEventListener('click', exportDiagReport);

for (const btn of document.querySelectorAll('.btn-preset')) {
  btn.addEventListener('click', () => applyPreset(btn.dataset.preset));
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
