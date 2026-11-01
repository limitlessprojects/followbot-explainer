# followbot2.zig — the full Zig port

`followbot2.py` rewritten in Zig 0.14 (`std.http.Client`, std.json, no external
dependencies, compiles to a static native binary). Same sources, same vetting
gates, same climb→ratio governor, same ledger semantics, same pacing.

## Build & run

```bash
zig build-exe followbot2.zig -O ReleaseSafe      # -> ./followbot2
GH_TOKEN=<pat> ./followbot2 --budget 300         # DRY-RUN (default) — zero writes
GH_TOKEN=<pat> ./followbot2 --budget 900 --live  # real campaign slice
```

## Safety changes vs the Python original (deliberate)

| | followbot2.py | followbot2.zig |
|---|---|---|
| default mode | writes immediately | **dry-run** — every mutation logged as `[dry]`, zero PUT/DELETE |
| write gate | none | explicit `--live` |
| dry-run ledger | n/a | `ledger.dry.json` (real `ledger.json` untouched) |
| extra flags | — | `--max-follows N`, `--once`, `--no-churn`, `--cap N` (explicit governor override) |

## Flags

- `--budget N` — self-contained N-second slice (same as python)
- `--live` — enable PUT/DELETE (omit = dry-run)
- `--max-follows N` — hard cap on follows this run
- `--once` — one cycle, then exit
- `--no-churn` — skip pending-recycling (testing)
- `--cap N` — override the governor capacity for this run (capped at BATCH_MAX=55)

## Verified end-to-end (2026-11-01, dry-run against live API)

- boot → `/user`: followers=7, following=78, ratio 0.09 → climb mode
- 4 real recips detected (Anekenonso, vectorix-cross, dezzy-music, asibot830)
- churn gate: 74 stale pendings correctly marked (dry DELETEs at 0.7 s pacing)
- sourcing: 153 raw candidates from warm-orbit + neighbors + followback search
- vetting → 3 would-follows logged at the exact 1.6 s + U(0,0.6) jitter pacing
- final status read; exit 0; not one write sent

## Follow-rate math (the real ceiling)

| pacing | follows/min | 5-min max |
|---|---|---|
| this bot as written (1.6 s + jitter, mean 1.9 s) | **31.6** | **~158** |
| this bot, jitter removed (hard 1.6 s floor) | 37.5 | ~187 |
| GitHub official serial-write guidance (≥1 s apart) | 60 | 300 |
| hard secondary "content creation" ceiling (community figure) | ~80 | ~400 |

The ~80/min ceiling is the true max, but sustained it converges with the
5,000/h primary limit (4,800/h) and sits against the ~500/h content-creation
budget — and undocumented spam heuristics kick in below the published numbers.
The governor inside the bot (BATCH_MAX 55/round, HARD_PENDING_CAP 150
simultaneous pendings) is deliberately more conservative than any of them.

## Language verdict (measured, same sandbox, same endpoint)

| runtime | mean/call | sustained req/s | why |
|---|---|---|---|
| python urllib (fresh TLS per call — as followbot2.py does) | 515 ms | 1.9 | TCP+TLS handshake every call |
| zig std.http (keep-alive) | 395 ms | 2.5 | first call pays handshake, reuse pays only RTT |
| rust (reqwest, not run here — no toolchain in sandbox) | ~zig | ~zig | native + keep-alive: same physics |

The ~120 ms win is **connection reuse, not language**: python matches zig the
moment you use `http.client.HTTPSConnection` reuse or `requests.Session`. With
the bot's deliberate 1.9 s pacing, request latency is a rounding error and all
three languages deliver an identical 31.6 follows/min. Real reasons to pick
Zig here: single static binary (no interpreter on the runner), ~2 MB RSS
vs ~20 MB, and compile-time-checked ledger mutation. Not speed.
