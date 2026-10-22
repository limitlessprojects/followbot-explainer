#!/usr/bin/env node
// Offline-render the film's groove score (window.SCORE) to a WAV file.
// Usage: node render_audio.mjs [out=score.wav]
import { chromium } from 'playwright-core';
import { resolve } from 'node:path';
import { writeFileSync, statSync } from 'node:fs';

const out = resolve(process.argv[2] || 'score.wav');
const browser = await chromium.launch({ args: ['--no-sandbox'] });
const p = await browser.newPage();
p.on('pageerror', e => console.error('pageerror:', e.message));
await p.goto('file://' + resolve('film.html') + '?render');

const wavB64 = await p.evaluate(async () => {
  const SR = 48000, dur = window.__duration;
  const ac = new OfflineAudioContext(2, Math.ceil(SR * dur), SR);
  window.SCORE(ac);
  const buf = await ac.startRendering();
  // encode stereo 16-bit WAV
  const n = buf.length, ch = buf.numberOfChannels;
  const bytes = 44 + n * ch * 2;
  const dv = new DataView(new ArrayBuffer(bytes));
  const wr = (o, s) => { for (let i = 0; i < s.length; i++) dv.setUint8(o + i, s.charCodeAt(i)); };
  wr(0, 'RIFF'); dv.setUint32(4, bytes - 8, true); wr(8, 'WAVEfmt ');
  dv.setUint32(16, 16, true); dv.setUint16(20, 1, true); dv.setUint16(22, ch, true);
  dv.setUint32(24, buf.sampleRate, true); dv.setUint32(28, buf.sampleRate * ch * 2, true);
  dv.setUint16(32, ch * 2, true); dv.setUint16(34, 16, true); wr(36, 'data');
  dv.setUint32(40, n * ch * 2, true);
  const chans = Array.from({ length: ch }, (_, c) => buf.getChannelData(c));
  let off = 44;
  for (let i = 0; i < n; i++) for (let c = 0; c < ch; c++) {
    const v = Math.max(-1, Math.min(1, chans[c][i]));
    dv.setInt16(off, v < 0 ? v * 0x8000 : v * 0x7fff, true); off += 2;
  }
  let bin = ''; const u8 = new Uint8Array(dv.buffer);
  for (let i = 0; i < u8.length; i += 0x8000) bin += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
  return btoa(bin);
});
await browser.close();
writeFileSync(out, Buffer.from(wavB64, 'base64'));
console.log('WAV', out, Math.round(statSync(out).size / 1024) + 'KB');
