# followbot2 — the vetted, ratio-governed campaign bot

The production bot behind the film. v1 (the film's story) proved the vetting
gates; v2 is the same discipline scaled into a campaign system with a governor
that lands on a healthy follower:following ratio instead of a bloated graph.

## Run it

```bash
GH_TOKEN=<your-pat> python3 followbot2.py --budget 900   # 15-min slice, then exit
GH_TOKEN=<your-pat> python3 followbot2.py                # run until Ctrl-C
```

- `--budget N` runs a self-contained N-second slice — built for sandboxed or
  ephemeral runners where long-lived processes are killed. The ledger makes
  every slice resumable; no state is held in memory across runs.
- Rate discipline: one follow every ~1.6–2.2s (≈120/hr ceiling), well under
  GitHub's abuse radar. The bot sleeps on 403/429 and honors
  `X-RateLimit-Reset`.

## Sources (priority order)

1. **Warm orbit** — people who already touched us: Go-Hybrid fork owners,
   stargazers, issue/PR participants. Highest conversion; they know the name.
2. **Followback-bio search** — 14 query shapes (`followback`, `f4f`,
   `teamfollowback`, `"i follow back"` …) with randomized result pages.
3. **Neighbors** — one hop from proven recippers: followers of accounts that
   already followed us back.

## Vetting gates (all must pass)

- `type: User` (no orgs), no bot-pattern name (`bot|script|scraper|crawler|
  dependabot|renovate|github-actions`)
- account older than 3 weeks (brand-new accounts are spam/suspension risk)
- public activity within 8 weeks (`updated_at` moves on any public action)
- not self, not already handled (ledger remembers everyone: followed,
  rejected + reason, unfollowed — nobody is retried or double-touched)

## The governor

- **climb mode** (followers < 100): following cap = `2.2 × followers` with an
  early floor of 60 while followers < 10; pendings soak 15 min to 2 h, dead
  pendings recycle so slots never starve; absolute cap 150 simultaneous
  non-reciprocals (abuse radar + ratio optics).
- **ratio mode** (followers ≥ 100): following cap = `followers / 0.93`;
  anything non-mutual older than 5 minutes churns. End state: a matched,
  >90% ratio that can't rot.

## The ledger

`ledger.json` beside the script: `followed` (with timestamps), `recip`,
`unfollowed`, `rejected` (with reasons), `whitelist`, `source` (which pool
produced each account + profile metadata at vet time), `followers_seen`.
Rewritten atomically (tmp + rename) after every single mutation.

## Honest field notes

Vetting is the correct discipline — torvalds still fails the mutual gate —
but vetting is not conversion. After ~135 outbound follows the cold pools
(followback-bio searches) produced near-zero recips: most of those accounts
are dormant (`updated_at` moves on login, not on activity). The conversion
engine is the warm orbit plus visible reasons to follow back: landed
contributions, review issues on other people's repos, a real org story.
The governor guarantees the *shape* of the graph; the content work earns the
*reciprocals*. Both are needed, and only one of them can be automated.
