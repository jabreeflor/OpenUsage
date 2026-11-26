import { chromium } from 'playwright-core';
import { mkdirSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
const here = path.dirname(new URL(import.meta.url).pathname);
const variant = process.argv[2] || 'tiles';
const fps = 30;
const frames = path.join(here, 'frames', variant);
rmSync(frames, { recursive: true, force: true });
mkdirSync(frames, { recursive: true });
const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
await page.goto('file://' + path.join(here, 'demo.html') + '?record=1&variant=' + variant);
await page.waitForFunction(() => window.ready === true);
const dur = await page.evaluate(() => window.DURATION);
const n = Math.round(dur * fps);
for (let i = 0; i < n; i++) {
  await page.evaluate((t) => window.renderAt(t), i / fps);
  await page.screenshot({ path: path.join(frames, String(i).padStart(4, '0') + '.jpg'), type: 'jpeg', quality: 92 });
}
await browser.close();
const out = path.join(here, `openusage-demo-${variant}.mp4`);
execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', path.join(frames, '%04d.jpg'), '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '18', '-preset', 'medium', '-movflags', '+faststart', out]);
console.log('wrote', out, n, 'frames');
