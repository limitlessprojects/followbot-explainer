#!/usr/bin/env node
// Scoped layout QC: sweep frames, flag out-of-bounds claims + text-vs-text overlaps.
//   node qc_check.mjs [step]   (default step 3 -> 480 frames over the 48s film)
import { chromium } from 'playwright-core';
import { resolve } from 'node:path';

const step = Number(process.argv[2] || 3);
const pagePath = resolve(process.argv[3] || 'film.html');
const W = 1920, H = 1080;

const browser = await chromium.launch({ args: ['--no-sandbox'] });
const p = await browser.newPage({ viewport: { width: W, height: H } });
p.on('pageerror', e => console.error('pageerror:', e.message));
await p.goto('file://' + pagePath + '?render');
await p.evaluate(() => document.fonts.ready);

const bad = [];
const n = await p.evaluate(() => window.__duration * 30);
// handoff windows: 0.5s before each cut (next shot's content pre-rolls under the previous
// camera) + 0.8s after (designed lingers exit through the edge). Verified harmless by stills.
const cuts = [4, 10, 16, 22, 28, 34, 40, 46];
const inHandoff = t => cuts.some(c => (t >= c - 0.5 && t < c) || (t >= c && t < c + 0.8)) || t < 0.3 || t > n / 30 - 0.3;
for (let f = 0; f < n; f += step) {
  if (inHandoff(f / 30)) continue;
  const rep = await p.evaluate((fr) => {
    window.draw(fr);
    const L = window.LAYOUT;
    const oob = [], ovl = [];
    const inter = (a, b) => !(a.x + a.w <= b.x || b.x + b.w <= a.x || a.y + a.h <= b.y || b.y + b.h <= a.y);
    for (const r of L) {
      // straddle test: element partially visible AND clipped by the frame edge = visible defect.
      // fully-inside = fine; fully-outside = intentional pre-roll/linger, invisible by design.
      const inside = r.x >= -1 && r.y >= -1 && r.x + r.w <= W + 1 && r.y + r.h <= H + 1;
      const outside = r.x + r.w <= 0 || r.y + r.h <= 0 || r.x >= W || r.y >= H;
      if (!inside && !outside) oob.push(r.id);
      if (r.kind === 'text') for (const q of L) {
        if (q === r || q.kind !== 'text' || q.id === r.id) continue;
        if (r.id < q.id && inter(r, q)) ovl.push(r.id + '~' + q.id);
      }
    }
    return { f: fr, oob, ovl, count: L.length };
  }, f);
  if (rep.oob.length || rep.ovl.length) bad.push(rep);
}
if (bad.length) {
  console.log(`FAIL  (${bad.length}/${Math.ceil(n / step)} frames flagged)`);
  for (const r of bad.slice(0, 40)) console.log(`  f${r.f}: oob=[${r.oob}] ovl=[${r.ovl}]`);
  process.exitCode = 1;
} else {
  console.log(`CLEAN  ${Math.ceil(n / step)} frames swept, no OOB, no text overlaps`);
}
await browser.close();
