'use strict';

// Always invoke webui_ctl.sh with its absolute module path (id=coresurface).
const CTL_SCRIPT = '/system/bin/sh /data/adb/modules/coresurface/lib/webui_ctl.sh';

const FEATURE_KEYS = [
  'FEAT_BLUR',
  'FEAT_ANIMATIONS',
  'FEAT_XML_PATCHER',
  'FEAT_MULTITASK',
  'FEAT_DISPLAY_HZ',
  'FEAT_HYPERAI',
  'FEAT_AOD_UNLOCK'
];

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
  const props = [];
  const overridden = [];
  const logs = [];
  let section = 'kv';

  for (const line of raw.split(/\r?\n/)) {
    if (line === 'props_start') { section = 'props'; continue; }
    if (line === 'props_end') { section = 'kv'; continue; }
    if (line === 'overridden_start') { section = 'overridden'; continue; }
    if (line === 'overridden_end') { section = 'kv'; continue; }
    if (line === 'log_start') { section = 'log'; continue; }
    if (line === 'log_end') { section = 'kv'; continue; }

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

  return { kv, props, overridden, logs };
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

  if (isPending) {
    el.classList.add('v-info');
    el.textContent = 'Pending Reboot';
    return;
  }

  switch (verifyStatus) {
    case 'verified_active':
      el.classList.add('v-ok');
      el.textContent = 'Verified Active';
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
      if (effValue === '1') {
        el.classList.add('v-info');
        el.textContent = 'Pending Verify';
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

async function refreshStatus() {
  const envList = document.getElementById('env-list');
  try {
    const raw = await ksuExec(CTL_SCRIPT + ' status');
    const { kv, props, overridden, logs } = parseStatusOutput(raw);

    if (!kv.rom_family || !kv.ram_tier) {
      throw new Error('Respons status tidak lengkap dari webui_ctl.sh');
    }

    renderWatchdogBadge(kv);

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

    for (const key of FEATURE_KEYS) {
      const lower = key.toLowerCase();
      setSegmentValue(key, kv['cfg_' + lower] || (key === 'FEAT_HYPERAI' || key === 'FEAT_AOD_UNLOCK' ? '0' : 'auto'));
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
  setToast('Menyimpan ' + key + '=' + value + '…');
  try {
    const res = await ksuExec(CTL_SCRIPT + ' set ' + key + ' ' + value);
    document.getElementById('reboot-banner').classList.remove('hidden');
    setToast(res);
    await refreshStatus();
  } catch (err) {
    setToast('Gagal menyimpan: ' + err.message);
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
