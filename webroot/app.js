'use strict';

// Always invoke webui_ctl.sh with its absolute module path (id=coresurface).
const CTL_SCRIPT = '/system/bin/sh /data/adb/modules/coresurface/lib/webui_ctl.sh';

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
  const logs = [];
  let section = 'kv';

  for (const line of raw.split(/\r?\n/)) {
    if (line === 'props_start') { section = 'props'; continue; }
    if (line === 'props_end') { section = 'kv'; continue; }
    if (line === 'log_start') { section = 'log'; continue; }
    if (line === 'log_end') { section = 'kv'; continue; }

    if (section === 'props') {
      if (line.trim()) props.push(line.trim());
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

  return { kv, props, logs };
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
      safeReason.textContent = 'Alasan: ' + kv.watchdog_reason + '. Disarankan matikan Tier 3 sebelum mengaktifkan kembali.';
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

function setPill(id, enabled, labelOn, labelOff) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = enabled ? labelOn : labelOff;
  el.classList.toggle('on', Boolean(enabled));
}

function renderPropsList(props) {
  const list = document.getElementById('props-list');
  const count = document.getElementById('props-count');
  count.textContent = String(props.length);
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
    const tier = sep > 0 ? entry.slice(0, sep) : 'prop';
    const pair = sep > 0 ? entry.slice(sep + 1) : entry;

    const li = document.createElement('li');
    const tag = document.createElement('span');
    tag.className = 'prop-tier';
    tag.textContent = tier;
    const text = document.createElement('span');
    text.textContent = pair;
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
    const { kv, props, logs } = parseStatusOutput(raw);

    if (!kv.rom_family || !kv.ram_tier) {
      throw new Error('Respons status tidak lengkap dari webui_ctl.sh');
    }

    renderWatchdogBadge(kv);

    const cfBadge = document.getElementById('coreflow-badge');
    cfBadge.classList.toggle('hidden', kv.coreflow_guard !== 'active');

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

    setSegmentValue('TIER1_VISUAL', kv.cfg_tier1 || 'auto');
    setSegmentValue('TIER2_MULTITASK', kv.cfg_tier2 || 'auto');
    setSegmentValue('TIER3_EXPERIMENTAL', kv.cfg_tier3 || '0');
    setSegmentValue('TIER3_HYPERAI', kv.cfg_tier3_hyperai || '0');
    setSegmentValue('TIER3_AOD_UNLOCK', kv.cfg_tier3_aod || '0');

    setPill('eff-tier1', kv.eff_tier1 === '1', kv.eff_tier1_heavy_blur === '1' ? 'Aktif (Blur Penuh)' : 'Aktif (Ringan)', 'Nonaktif');
    setPill('eff-tier2', kv.eff_tier2 === '1', 'Aktif', 'Nonaktif');
    setPill('eff-tier3', kv.eff_tier3 === '1', 'Aktif (Opt-in)', 'Nonaktif');

    document.getElementById('tier3-sub').classList.toggle('hidden', kv.cfg_tier3 !== '1');

    renderPropsList(props);
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
