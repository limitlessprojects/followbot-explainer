#!/usr/bin/env node
// Full-film renderer: deterministic draw(f) -> JPEG frames (resumable) -> ffmpeg x264.
// Usage: node render_video.mjs [outDir=frames]
import { chromium } from 'playwright-core';
import { resolve, dirname } from 'node:path';
import { mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const outDir = resolve(process.argv[2] || 'frames');
mkdirSync(outDir, { recursive: true });
const pagePath = resolve('film.html');

const browser = await chromium.launch({ args: ['--no-sandbox'] });
const p = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
p.on('pageerror', e => console.error('pageerror:', e.message));
await p.goto('file://' + pagePath + '?render');
await p.evaluate(() => document.fonts.ready);

const n = await p.evaluate(() => Math.round(window.__duration * 30));
let done = 0, skipped = 0;
for (let f = 0; f < n; f++) {
  const file = resolve(outDir, `f${String(f).padStart(4, '0')}.jpg`);
  if (existsSync(file)) { skipped++; continue; }
  const jpg = await p.evaluate((fr) => { window.draw(fr); return document.querySelector('canvas').toDataURL('image/jpeg', 0.92).split(',')[1]; }, f);
  writeFileSync(file, Buffer.from(jpg, 'base64'));
  done++;
  if (done % 120 === 0) console.log(`  ${done + skipped}/${n} (${done} new, ${skipped} skipped)`);
}
console.log(`frames done: ${done} new + ${skipped} skipped = ${done + skipped}/${n}`);
await browser.close();

const mp4 = resolve('film-noaudio.mp4');
const enc = spawnSync('ffmpeg', ['-y', '-framerate', '30', '-i', resolve(outDir, 'f%04d.jpg'),
  '-c:v', 'libx264', '-crf', '18', '-preset', 'medium', '-pix_fmt', 'yuv420p', mp4],
  { stdio: ['ignore', 'ignore', 'pipe'] });
if (enc.status !== 0) { console.error('ffmpeg encode failed:', enc.stderr?.toString().slice(-600)); process.exit(1); }
console.log('ENCODED', mp4);
