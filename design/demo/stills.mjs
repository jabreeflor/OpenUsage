import { chromium } from 'playwright-core';
import path from 'node:path';
const here = path.dirname(new URL(import.meta.url).pathname);
const out = process.argv[2];
const shots = [['tiles', 3.6, '01-menubar-dropdown'], ['tiles', 8.0, '02-dropdown-cursor-selected'], ['tiles', 12.4, '03-statistics-30d'], ['tiles', 17.5, '04-statistics-claude-7d'], ['accounts', 3.4, '05-dropdown-disconnected'], ['accounts', 8.2, '06-accounts-connecting'], ['accounts', 14.4, '07-accounts-all-connected'], ['menu', 5.0, '08-alt-native-menu']];
const browser = await chromium.launch({ channel: 'chrome' });
for (const [v, t, name] of shots) {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
  await page.goto('file://' + path.join(here, 'demo.html') + '?record=1&variant=' + v);
  await page.waitForFunction(() => window.ready === true);
  for (let x = 0; x <= t; x += 1 / 30) await page.evaluate((tt) => window.renderAt(tt), x);
  await page.evaluate(() => { document.getElementById('caption').style.display = 'none'; });
  await page.screenshot({ path: path.join(out, name + '.png') });
  await page.close();
}
await browser.close();
