#!/usr/bin/env python3
"""followbot v2 — ultra-fast, vetted, ratio-governed GitHub follow campaign.

Run: GH_TOKEN=<pat> python3 followbot2.py --budget 900   # 15-min self-contained slice
The ledger (ledger.json) persists beside the script; slices are resumable
and crash-safe — every mutation is rewritten to disk immediately.

Sources (priority order):
  W  warm orbit      — Go-Hybrid fork owners, stargazers, PR contributors (know us)
  F  followback bios — search: followback / follow back / f4f / follback / teamfollowback ...
  N  neighbors       — followers of accounts that already follow us

Vetting gates: human (type=User, not org/bot-named, not suspended), active
(updated/pushed recently), not self/blacklisted, not already handled.

Governor:
  climb mode  (followers < 100): following cap = 2.2 x followers
  ratio mode  (followers >= 100): following cap = followers / 0.92, churn everything non-mutual
Ledger: ledger.json (crash-safe, rewritten after every mutation).
"""
import json, os, re, time, urllib.request, urllib.error, urllib.parse, random, sys

GH = os.environ.get("GH_TOKEN", "")  # never hardcode tokens
ME = "limitlessprojects"
DIR = os.path.dirname(os.path.abspath(__file__))
LEDGER = os.path.join(DIR, "ledger.json")
LOG = os.path.join(DIR, "followbot2.log")

FOLLOW_INTERVAL = 1.6          # seconds between follow PUTs (~120/hr ceiling — under radar)
SOAK_S = 900                   # 15 min: auto-followback bots recip within minutes; humans later
CYCLE_SLEEP = 60               # poll cadence between checks
BATCH_MAX = 55                 # max follows per sourcing round
CLIMB_MULT = 2.2               # mid-climb following cap multiplier (after followers >= 10)
CLIMB_BASE = 60                # early-game floor: absolute following cap while followers < 10
RATIO_TARGET = 0.93            # end-state governor
FOLLOWERS_GOAL = 100
HARD_PENDING_CAP = 150         # absolute max simultaneous non-recip pendings (abuse radar + ratio optics)

BOT_PAT = re.compile(r"(?i)(^|[-_ .])(bot|b0t|script|scraper|crawler|spider| Official)([-_ .]|$)|dependabot|renovate|github-actions")
FB_PAT = re.compile(r"(?i)(follow\s?back|followback|f4f|follback|follow\s?4\s?follow|follow\s?for\s?follow|teamfollowback|mutual\s?follow|instant\s?follow|reciproco|sigue\s?de\s?vuelta)")

def log(msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    with open(LOG, "a") as f:
        f.write(line + "\n")

def api(path, method="GET", limit_retry=3):
    req = urllib.request.Request(f"https://api.github.com{path}", method=method,
        headers={"Authorization": f"token {GH}", "User-Agent": "followbot2",
                 "Accept": "application/vnd.github+json"})
    for i in range(limit_retry):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = r.read() if r.status != 204 else b""
                return r.status, (json.loads(body) if body else None)
        except urllib.error.HTTPError as e:
            if e.code in (403, 429):
                reset = e.headers.get("X-RateLimit-Reset")
                wait = max(5, int(reset) - int(time.time()) + 2) if reset else 120
                log(f"RATE LIMIT on {path}, sleeping {wait}s")
                time.sleep(min(wait, 900))
                continue
            return e.code, None
        except Exception as ex:
            log(f"ERR {path}: {ex}")
            time.sleep(5)
    return 0, None

# ---------------- ledger ----------------
def load():
    if os.path.exists(LEDGER):
        with open(LEDGER) as f:
            return json.load(f)
    return {"followed": {}, "recip": {}, "unfollowed": {}, "rejected": {}, "whitelist": ["dezzy-music"],
            "source": {}, "followers_seen": []}

def save(L):
    tmp = LEDGER + ".tmp"
    with open(tmp, "w") as f:
        json.dump(L, f, indent=1)
    os.replace(tmp, LEDGER)

def counts(L):
    return len(L["recip"]), len(L["followed"]) - len(L["recip"])  # recip, pending

# ---------------- candidate sourcing ----------------
FB_QUERIES = [
    "followback in:bio type:user", '"follow back" in:bio type:user',
    '"i follow back" in:bio type:user', "follback in:bio type:user",
    '"follow 4 follow" in:bio type:user', '"follow for follow" in:bio type:user',
    '"instant follow back" in:bio type:user', "teamfollowback in:bio type:user",
    '"always follow back" in:bio type:user', '"mutual follow" in:bio type:user',
    '"i always follow back" in:bio type:user', '"followback guaranteed" in:bio type:user',
    '"gain followers" in:bio type:user', '"f4f" in:bio type:user followers:<400',
]

def source_warm_orbit(L, out):
    """fork owners + stargazers + contributors of Go-Hybrid — they know us."""
    seen = set(out)
    for path, tag in [("/repos/limitlessprojects/Go-Hybrid/stargazers?per_page=100", "star"),
                      ("/repos/limitlessprojects/Go-Hybrid/forks?per_page=100&sort=stargazers", "fork")]:
        st, data = api(path)
        if st == 200 and data:
            for u in data:
                login = u.get("login") or (u.get("owner") or {}).get("login")
                if login and login not in seen:
                    out.append((login, tag)); seen.add(login)
    # recent PR/issue authors
    st, data = api("/repos/limitlessprojects/Go-Hybrid/issues?state=all&sort=created&direction=desc&per_page=60")
    if st == 200 and data:
        for it in data:
            if "pull_request" in it or True:
                lg = it["user"]["login"]
                if lg not in seen and lg != ME:
                    out.append((lg, "author")); seen.add(lg)
    return out

def source_followback_search(L, out, per_q=50):
    seen = set(x for x, _ in out)
    for q in FB_QUERIES:
        page = random.randint(1, 3)
        st, data = api(f"/search/users?q={urllib.parse.quote(q)}&per_page={per_q}&page={page}")
        if st == 200 and data:
            for u in data.get("items", []):
                lg = u["login"]
                if lg not in seen:
                    out.append((lg, "fbsearch")); seen.add(lg)
        time.sleep(2)  # search API is separate quota but be polite
    return out

def source_neighbors(L, out):
    """followers of our followers AND of our most-engaged contributors — 1 hop from proven recippers."""
    seen = set(x for x, _ in out)
    hubs = [ME, "sonson0910", "rickymulya", "airdropia", "dezzy-music"]
    for hub in hubs:
        st, data = api(f"/users/{hub}/followers?per_page=80")
        if st == 200 and data:
            for f in data:
                lg = f["login"]
                if lg == ME or lg in seen: continue
                out.append((lg, f"neighbor:{hub}")); seen.add(lg)
    return out

# ---------------- vetting ----------------
def vet(login, L):
    if login in L["followed"] or login in L["rejected"] or login in L["unfollowed"]:
        return False, "handled"
    if login in L["whitelist"]: return False, "whitelisted-already"
    if login.lower() == ME.lower(): return False, "self"
    if BOT_PAT.search(login): return False, "botname"
    st, p = api(f"/users/{login}")
    if st == 404: return False, "suspended/gone"
    if st != 200 or not p: return False, f"profile-{st}"
    if p.get("type") != "User": return False, "org"
    name = p.get("name") or ""
    if BOT_PAT.search(name): return False, "botname-meta"
    created = p.get("created_at") or ""
    if created >= "2026-10-01": return False, "brand-new-account"  # <3wks: spam/suspension risk
    # activity gate: updated_at moves on any public action — require recent activity
    upd = p.get("updated_at") or ""
    if upd and upd < "2026-09-01": return False, "inactive-8wk"
    bio = p.get("bio") or ""
    L["source"].setdefault(login, {})["meta"] = {
        "followers": p.get("followers"), "following": p.get("following"),
        "repos": p.get("public_repos"), "fb_bio": bool(FB_PAT.search(bio)), "bio": bio[:80]}
    return True, "ok"

# ---------------- actions ----------------
def follow(login):
    st, _ = api(f"/user/following/{login}", "PUT")
    return st in (204, 200)

def unfollow(login):
    st, _ = api(f"/user/following/{login}", "DELETE")
    return st in (204, 200)

def refresh_followers(L, cur):
    st, data = api(f"/users/{ME}/followers?per_page=100")
    fl = [u["login"] for u in (data or [])]
    new = [f for f in fl if f not in L["followers_seen"]]
    L["followers_seen"] = fl
    # mutual = follower AND in following set, never previously churned
    for f in fl:
        if f in cur and f not in L["recip"] and f not in L["unfollowed"]:
            L["recip"][f] = time.time()
            log(f"  RECIP +{f}")
    return set(fl), new

def following_set():
    s, data = api(f"/users/{ME}/following?per_page=100")
    return set(u["login"] for u in (data or []))

def pending_following(L, cur_following):
    """following minus recip minus whitelist == pendings"""
    return [u for u in cur_following if u not in L["recip"] and u not in L["whitelist"]]

# ---------------- main loop ----------------
def main():
    if not GH:
        print("set GH_TOKEN env var (a PAT with follow permissions)"); sys.exit(1)
    budget = int(sys.argv[sys.argv.index("--budget") + 1]) if "--budget" in sys.argv else 10**9
    t_end = time.time() + budget
    L = load()
    log(f"=== followbot2 boot (budget {budget}s) === ledger: followed={len(L['followed'])} recip={len(L['recip'])} unfollowed={len(L['unfollowed'])}")
    pool = []          # vetted candidates not yet followed
    exhausted_sources = False
    cap = 0

    while time.time() < t_end:
        st, me = api("/user")
        if st != 200: log("api down, retrying in 120s"); time.sleep(120); continue
        followers_n, following_n = me["followers"], me["following"]
        recip, pend = counts(L)
        mode = "climb" if followers_n < FOLLOWERS_GOAL else "ratio"
        ratio = followers_n / max(1, following_n)
        log(f"state: followers={followers_n} following={following_n} ratio={ratio:.2f} mode={mode} ledger-pending={pend}")

        # --- refresh followers, mark recips ---
        cur = following_set()
        fset, newf = refresh_followers(L, cur)
        if newf: log(f"  NEW FOLLOWERS: {newf}")
        save(L)

        # --- churn due pendings ---
        now = time.time()
        pendings = pending_following(L, cur)
        churned = 0
        for u in pendings:
            t = L["followed"].get(u, 0)
            must_go = False
            over_ceiling = following_n > HARD_PENDING_CAP
            if mode == "ratio":
                must_go = now - t > 300          # end state: aggressive churn
            elif over_ceiling or cap <= 0:
                must_go = now - t > SOAK_S * 2   # need slots: recycle dead pendings at 30 min
            else:
                must_go = now - t > SOAK_S * 8   # comfortable: 2h max soak
            if must_go and (mode == "ratio" or (now - t > SOAK_S * 3 and cap <= 5) or len(pendings) > 90):
                if unfollow(u):
                    L["unfollowed"][u] = now; L["followed"].pop(u, None)
                    churned += 1; following_n -= 1
                    log(f"  churn -{u} (no recip in {int((now-t)/60)}min)")
                    time.sleep(0.7)
        if churned: save(L)

        # --- capacity ---
        if mode == "climb":
            wl_in = len([w for w in L["whitelist"] if w in cur])
            ceiling = max(CLIMB_BASE, int(CLIMB_MULT * followers_n)) if followers_n < 10 else min(int(CLIMB_MULT * followers_n) + CLIMB_BASE, HARD_PENDING_CAP)
            cap = min(ceiling, HARD_PENDING_CAP) - (following_n - wl_in)
        else:
            cap = int(followers_n / RATIO_TARGET) - following_n
        cap = min(cap, BATCH_MAX)
        if cap <= 0:
            remaining = int(t_end - time.time())
            log(f"  capacity 0 (mode={mode}, followers={followers_n}, following={following_n}); sleep {min(CYCLE_SLEEP, max(0, remaining))}s")
            time.sleep(min(CYCLE_SLEEP, max(0, remaining))); continue

        # --- source if pool low ---
        if len(pool) < cap + 10 and not exhausted_sources:
            raw = []
            if not L["source"].get("_orbit_done"):
                source_warm_orbit(L, raw)
            source_neighbors(L, raw)
            source_followback_search(L, raw)
            raw = [(lg, src) for lg, src in raw if lg not in L["followed"] and lg not in L["rejected"]
                   and lg not in L["unfollowed"]]
            random.shuffle(raw)
            log(f"  sourcing: {len(raw)} raw candidates")
            for lg, src in raw[:130]:
                ok, why = vet(lg, L)
                if ok:
                    pool.append((lg, src))
                    L["source"].setdefault(lg, {})["src"] = src
                else:
                    L["rejected"][lg] = why
                time.sleep(0.25)
            if not raw and not pool:
                exhausted_sources = True
                log("  SOURCES EXHAUSTED")
            save(L)

        # --- follow batch ---
        sent = 0
        while pool and sent < cap:
            lg, src = pool.pop(0)
            if follow(lg):
                L["followed"][lg] = time.time()
                L["source"].setdefault(lg, {})["src"] = src
                sent += 1
                log(f"  +{lg} ({src}) [{sent}/{cap}]")
            else:
                L["rejected"][lg] = "follow-failed"
                log(f"  FAIL {lg}")
                time.sleep(3)
            save(L)
            time.sleep(FOLLOW_INTERVAL + random.uniform(0, 0.6))

        if sent == 0 and cap > 0 and exhausted_sources:
            log("  nothing to follow; sleep short")
            time.sleep(min(120, max(0, int(t_end - time.time()))))
    # final status
    st, me = api("/user")
    if st == 200:
        log(f"=== budget done: followers={me['followers']} following={me['following']} ratio={me['followers']/max(1,me['following']):.2f} ===")
    else:
        log("=== budget done (api read failed) ===")

if __name__ == "__main__":
    main()
