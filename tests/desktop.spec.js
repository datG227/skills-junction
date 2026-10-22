const { test, expect, chromium } = require('@playwright/test');
const { spawn, execFileSync } = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

// Official WebView2 automation: https://playwright.dev/docs/webview2
const publish = path.resolve(process.env.APP_PUBLISH_DIR || 'artifacts/publish');
let app, browser, page, root;

async function unusedPort() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

test.beforeEach(async () => {
  const executable = path.join(publish, 'SkillsJunction.WebView2.exe');
  expect(fs.existsSync(executable), 'Run scripts/build.ps1 first to publish the desktop app').toBeTruthy();
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'skills-junction-desktop-'));
  const port = await unusedPort();
  app = spawn(executable, [], {
    cwd: publish, windowsHide: false,
    env: { ...process.env, LOCALAPPDATA: path.join(root, 'profile'),
      WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${port}` },
  });
  app.on('error', error => console.error('Desktop launch failed:', error.message));
  let connectionError;
  try {
    await expect.poll(async () => {
      try {
        const response = await fetch(`http://127.0.0.1:${port}/json/version`);
        connectionError = `HTTP ${response.status}`;
        return response.ok;
      } catch (error) { connectionError = String(error.cause || error); return false; }
    }, { timeout: 30_000 }).toBeTruthy();
    browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`);
    page = browser.contexts()[0].pages()[0];
    await expect(page.getByRole('heading', { name: 'Quản lý Junction' })).toBeVisible();
  } catch (error) {
    const log = path.join(root, 'profile', 'SkillsJunction', 'WebView2.log');
    console.error('Desktop startup exit code:', app.exitCode, 'CDP port:', port, connectionError);
    if (fs.existsSync(log)) console.error(fs.readFileSync(log, 'utf8'));
    try {
      console.error(execFileSync('powershell.exe', ['-NoProfile', '-Command',
        `Get-CimInstance Win32_Process -Filter 'ParentProcessId = ${app.pid}' | Select-Object Name,ProcessId,CommandLine | ConvertTo-Json -Depth 3`],
      { encoding: 'utf8', windowsHide: true }));
    } catch (diagnosticError) { console.error('Process diagnostics:', diagnosticError.message); }
    throw error;
  }
});

test.afterEach(async () => {
  try {
    if (app && app.exitCode === null) {
      // Graceful native-window close also tests that the owned backend is stopped.
      execFileSync('powershell.exe', ['-NoProfile', '-Command',
        `$p=Get-Process -Id ${app.pid} -ErrorAction SilentlyContinue; if($p){$null=$p.CloseMainWindow()}`],
      { windowsHide: true });
      await expect.poll(() => app.exitCode, { timeout: 10_000 }).not.toBeNull();
    }
  } finally {
    if (browser) await browser.close().catch(() => {});
    if (app && app.exitCode === null) app.kill();
    // Never follow junctions or remove paths outside this test's generated root.
    if (root) {
      expect(path.dirname(path.resolve(root))).toBe(path.resolve(os.tmpdir()));
      expect(path.basename(root)).toMatch(/^skills-junction-desktop-/);
      const profile = path.join(root, 'profile');
      // WebView2 may release its profile slightly after the app closes.
      await expect.poll(() => {
        try { fs.rmSync(profile, { recursive: true, force: true }); return true; }
        catch { return false; }
      }, { timeout: 10_000 }).toBeTruthy();
      fs.rmSync(root, { recursive: true, force: true });
    }
    app = browser = page = root = undefined;
  }
});

async function request(action, fields = {}) {
  return page.evaluate(({ action, fields }) => new Promise((resolve, reject) => {
    const requestId = 'desktop-' + crypto.randomUUID();
    const timeout = setTimeout(() => {
      window.chrome.webview.removeEventListener('message', onMessage);
      reject(new Error('Backend request timed out: ' + action));
    }, 15_000);
    function onMessage(event) {
      if (event.data.requestId !== requestId) return;
      clearTimeout(timeout);
      window.chrome.webview.removeEventListener('message', onMessage);
      resolve(event.data);
    }
    window.chrome.webview.addEventListener('message', onMessage);
    window.chrome.webview.postMessage({ requestId, action, ...fields });
  }), { action, fields });
}

test('published host serves only web content and closes its backend', async () => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await expect(page.getByText('Chưa có Junction nào', { exact: true })).toBeVisible();
  expect((await request('load')).pairs).toEqual([]);
  const denied = await page.evaluate(async () => {
    try {
      const response = await fetch('/backend/SkillsJunction.WebView2.ps1');
      return response.status >= 400;
    } catch { return true; }
  });
  expect(denied).toBeTruthy();
  const children = JSON.parse(execFileSync('powershell.exe', ['-NoProfile', '-Command',
    `ConvertTo-Json -Compress -InputObject @(Get-CimInstance Win32_Process -Filter 'ParentProcessId = ${app.pid}' | Where-Object Name -eq 'powershell.exe' | Select-Object -ExpandProperty ProcessId)`],
  { encoding: 'utf8', windowsHide: true }));
  expect(children.length).toBe(1);
  execFileSync('powershell.exe', ['-NoProfile', '-Command', `$null=(Get-Process -Id ${app.pid}).CloseMainWindow()`], { windowsHide: true });
  await expect.poll(() => app.exitCode).not.toBeNull();
  for (const pid of children) {
    await expect.poll(() => {
      try { process.kill(pid, 0); return true; } catch { return false; }
    }).toBeFalsy();
  }
  expect(errors).toEqual([]);
});

test('actual host preserves Vietnamese text and per-skill exclusions', async () => {
  const source = path.join(root, 'nguồn');
  const target = path.join(root, 'đích');
  for (const name of ['kỹ-năng', 'beta']) {
    fs.mkdirSync(path.join(source, name), { recursive: true });
    fs.writeFileSync(path.join(source, name, 'SKILL.md'), name, 'utf8');
  }
  const added = await request('add', { name: 'Kiểm tra tiếng Việt', group: 'Thử nghiệm', source, target });
  expect(added.ok).toBeTruthy();
  expect(added.pairs[0].name).toBe('Kiểm tra tiếng Việt');
  await page.getByRole('button', { name: 'Skills', exact: true }).click();
  const control = page.getByRole('switch', { name: 'Junction skill kỹ-năng', exact: true });
  await expect(control).toBeChecked();
  await control.click();
  await expect(control).not.toBeChecked();
  expect(fs.existsSync(path.join(target, 'kỹ-năng'))).toBeFalsy();
  const id = added.pairs[0].id;
  expect((await request('toggle', { id, enabled: false })).ok).toBeTruthy();
  expect((await request('toggle', { id, enabled: true })).ok).toBeTruthy();
  expect(fs.existsSync(path.join(target, 'kỹ-năng'))).toBeFalsy();
  await control.click();
  await expect(control).toBeChecked();
  expect(fs.readFileSync(path.join(target, 'kỹ-năng', 'SKILL.md'), 'utf8')).toBe('kỹ-năng');
  expect(fs.readFileSync(path.join(source, 'kỹ-năng', 'SKILL.md'), 'utf8')).toBe('kỹ-năng');
});
