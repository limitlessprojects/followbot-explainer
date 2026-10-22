#!/usr/bin/env node
// Render the character sheet: loads film.html with __CH=1 so draw() routes to charSheet().
import { chromium } from 'playwright-core';
import { resolve } from 'node:path';
import { writeFileSync } from 'node:fs';

const page = resolve(process.argv[2] || 'film.html');
const out = process.argv[3] || 'char-0000.jpg';
const browser = await chromium.launch({ args: ['--no-sandbox'] });
const p = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
p.on('pageerror', e => console.error('pageerror:', e.message));
await p.goto('file://' + page + '?render');
await p.evaluate(() => { window.__CH = true; });
const jpg = await p.evaluate(() => {
  window.draw(0);
  return document.querySelector('canvas').toDataURL('image/jpeg', 0.93).split(',')[1];
});
writeFileSync(out, Buffer.from(jpg, 'base64'));
console.log(out);
await browser.close();
