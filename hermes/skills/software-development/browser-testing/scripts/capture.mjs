import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';

// Playwright HEADLESS recipe for capturing clinical-panel screens.
// No focus competition, forms filled via CDP (page.fill), no CGEvent truncation.
// Usage:  node capture.mjs   (override with PANEL_URL / PANEL_EMAIL / PANEL_PASSWORD)

const BASE = process.env.PANEL_URL || 'http://localhost:5050';
const OUT = process.env.PANEL_OUT || `${process.env.HOME}/clinical-panel-playwright/screens`;
const EMAIL = process.env.PANEL_EMAIL || 'dev@genialcare.com.br';
const PASSWORD = process.env.PANEL_PASSWORD || 'dev@genialcare.com.br';

mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  locale: 'pt-BR',
});
const page = await context.newPage();

const shot = async (name) => {
  await page.screenshot({ path: `${OUT}/${name}.png` });
  console.log(`  ✓ ${name}.png`);
};

try {
  // 1 · Welcome / clinic selection
  console.log('1 · Welcome (clinic select)');
  await page.goto(BASE, { waitUntil: 'load', timeout: 30000 });
  await page.waitForSelector('[data-testid="tenant-option-genial_care"]', { timeout: 20000 });
  await page.waitForTimeout(800);
  await shot('01-bem-vindo-clinica');

  await page.click('[data-testid="tenant-option-genial_care"]');
  await page.waitForTimeout(300);
  await page.click('button:has-text("Entrar")');

  // 2 · Auth0 email
  console.log('2 · Auth0 (email)');
  await page.waitForURL(/auth0\.com/, { timeout: 25000 });
  await page.waitForSelector('input[type="email"], input#username, input[name="username"]', { timeout: 25000 });
  await page.waitForTimeout(500);
  await shot('02-auth0-email');
  await page.fill('input[type="email"], input#username, input[name="username"]', EMAIL);
  await page.click('button[type="submit"]');

  // 3 · Auth0 password
  console.log('3 · Auth0 (password)');
  await page.waitForSelector('input[type="password"], input#password', { timeout: 25000 });
  await page.waitForTimeout(500);
  await shot('03-auth0-senha');
  await page.fill('input[type="password"], input#password', PASSWORD);
  await page.click('button[type="submit"]');

  await page.waitForURL(/panel\/home/, { timeout: 40000 });
  await page.waitForTimeout(2000);

  // wait for the "Carregando..." spinner to clear (fixed timeout is too short —
  // GraphQL data loads after the spinner hides)
  const waitLoaded = async () => {
    const spinner = page.locator('text=Carregando').first();
    try {
      await spinner.waitFor({ state: 'visible', timeout: 2500 });
      await spinner.waitFor({ state: 'hidden', timeout: 20000 });
    } catch {
      /* no spinner (fast page) or didn't clear in time */
    }
    await page.waitForTimeout(800);
  };

  const routes = [
    ['04-panel-home', '/panel/home'],
    ['05-settings', '/panel/settings'],
    ['06-pendencias', '/panel/users/pendencies'],
    ['07-tarefas', '/panel/users/tasks'],
    ['08-sessoes', '/panel/users/sessions'],
    ['09-marketplace', '/panel/users/marketplace'],
    ['10-planning', '/panel/users/planning'],
  ];

  for (const [name, path] of routes) {
    console.log(`· ${name} → ${path}`);
    await page.goto(`${BASE}${path}`, { waitUntil: 'load', timeout: 30000 });
    await waitLoaded();
    await shot(name);
  }

  console.log(`\nDONE — screenshots in ${OUT}`);
} catch (err) {
  console.error('\nERROR:', err.message);
  await page.screenshot({ path: `${OUT}/_erro.png` });
  process.exitCode = 1;
} finally {
  await browser.close();
}
