#!/usr/bin/env node
// Deterministic still renderer: node render_still.mjs <frames csv> [outPrefix]
// Uses the same draw() path as the video render (pure, boil-4 stepped).
import { chromium } from 'playwright-core';
import { resolve, dirname } from 'node:path';
import { mkdirSync, writeFileSync } from 'node:fs';

const frames = (process.argv[2] || '0').split(',').map(Number).filter(Number.isFinite);
const prefix = process.argv[3] || 'shot';
const pagePath = resolve(process.argv[4] || 'film.html');
const outDir = dirname(resolve(prefix));
mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch({ args: ['--no-sandbox'] });
const p = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
p.on('pageerror', e => console.error('pageerror:', e.message));
await p.goto('file://' + pagePath + '?render');
await p.evaluate(() => document.fonts.ready);

for (const f of frames) {
  const layout = await p.evaluate((fr) => { window.draw(fr); return window.LAYOUT; }, f);
  const jpg = await p.evaluate(() => document.querySelector('canvas').toDataURL('image/jpeg', 0.93).split(',')[1]);
  const out = `${prefix}-${String(f).padStart(4, '0')}.jpg`;
  writeFileSync(resolve(outDir, out), Buffer.from(jpg, 'base64'));
  const oob = layout.filter(r => r.x < -1 || r.y < -1 || r.x + r.w > 1921 || r.y + r.h > 1081);
  console.log(`${out}  claims=${layout.length}${oob.length ? '  OOB=' + JSON.stringify(oob) : ''}`);
}
await browser.close();
