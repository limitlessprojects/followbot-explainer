//! followbot2.zig — faithful Zig port of followbot2.py (v2 campaign bot).
//!
//! Same constants, same sourcing order, same vetting gates, same climb→ratio
//! governor, same crash-safe ledger semantics, same pacing (1.6s + 0-0.6s
//! jitter between follow writes).
//!
//! Safety changes vs the Python original (deliberate):
//!   * DEFAULT MODE IS DRY-RUN: no PUT/DELETE is ever sent. Every mutation is
//!     logged as "[dry]" and bookkeeping goes to ledger.dry.json so your real
//!     ledger.json is never touched by a dry run.
//!   * Writes require an explicit --live flag.
//!
//! Run:
//!   GH_TOKEN=<pat> zig run followbot2.zig -- --budget 300            # dry
//!   GH_TOKEN=<pat> ./followbot2 --budget 900 --live                  # live
//!   GH_TOKEN=<pat> ./followbot2 --budget 120 --max-follows 5 --live  # capped slice
const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------- config --
// Every constant mirrors followbot2.py exactly.
const ME = "limitlessprojects";
const FOLLOW_INTERVAL_S: f64 = 1.6; // seconds between follow PUTs (~37.5/min hard floor, ~31.6/min mean)
const JITTER_MAX_S: f64 = 0.6;
const SOAK_S: i64 = 900; // 15 min soak before a pending is recycle-eligible
const CYCLE_SLEEP_S: u64 = 60;
const BATCH_MAX: i64 = 55; // max follows per sourcing round
const CLIMB_MULT: f64 = 2.2; // following cap multiplier mid-climb
const CLIMB_BASE: i64 = 60; // early-game floor while followers < 10
const RATIO_TARGET: f64 = 0.93; // end-state governor (followers/following)
const FOLLOWERS_GOAL: i64 = 100; // climb→ratio switch point
const HARD_PENDING_CAP: i64 = 150; // max simultaneous non-reciprocal follows
const VET_CAP: usize = 130; // candidates deep-vetted per sourcing round

const API = "https://api.github.com";

const whitelist = [_][]const u8{"dezzy-music"};
const hubs = [_][]const u8{ ME, "sonson0910", "rickymulya", "airdropia", "dezzy-music" };

const fb_queries = [_][]const u8{
    "followback in:bio type:user",
    "\"follow back\" in:bio type:user",
    "\"i follow back\" in:bio type:user",
    "follback in:bio type:user",
    "\"follow 4 follow\" in:bio type:user",
    "\"follow for follow\" in:bio type:user",
    "\"instant follow back\" in:bio type:user",
    "teamfollowback in:bio type:user",
    "\"always follow back\" in:bio type:user",
    "\"mutual follow\" in:bio type:user",
    "\"i always follow back\" in:bio type:user",
    "\"followback guaranteed\" in:bio type:user",
    "\"gain followers\" in:bio type:user",
    "\"f4f\" in:bio type:user followers:<400",
};

const bot_tokens = [_][]const u8{ "bot", "b0t", "script", "scraper", "crawler", "spider", "official" };
const bot_substrings = [_][]const u8{ "dependabot", "renovate", "github-actions" };
const fb_substrings = [_][]const u8{
    "followback",     "follow back",  "f4f",             "follback",
    "follow 4 follow", "follow for follow", "teamfollowback", "mutual follow",
    "instant follow", "reciproco",    "sigue de vuelta",
};

// ------------------------------------------------------------------ log --
var log_file: ?std.fs.File = null;

fn logMsg(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const ts: u64 = @intCast(@max(0, std.time.timestamp()));
    const line = std.fmt.bufPrint(&buf, "[{d:0>2}:{d:0>2}:{d:0>2}] " ++ fmt ++ "\n", .{
        (ts / 3600) % 24,
        (ts / 60) % 60,
        ts % 60,
    } ++ args) catch return;
    std.io.getStdOut().writeAll(line) catch {};
    if (log_file) |f| f.writeAll(line) catch {};
}

// ------------------------------------------------------------------ api --
const Api = struct {
    client: http.Client,
    token: []const u8,
    gpa: Allocator,

    const Result = struct { status: u16, body: []u8 };

    fn init(gpa: Allocator, token: []const u8) Api {
        return .{ .client = .{ .allocator = gpa }, .token = token, .gpa = gpa };
    }

    fn deinit(self: *Api) void {
        self.client.deinit();
    }

    /// One API call with the python version's retry semantics:
    /// on 403/429 sleep to X-RateLimit-Reset (cap 900s), retry up to 3 times.
    fn call(self: *Api, arena: Allocator, path: []const u8, method: http.Method) !Result {
        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ API, path });
            const uri = std.Uri.parse(url) catch {
                logMsg("bad uri: {s}", .{url});
                return .{ .status = 0, .body = try arena.alloc(u8, 0) };
            };
            var header_buf: [64 * 1024]u8 = undefined;
            const auth = try std.fmt.allocPrint(arena, "token {s}", .{self.token});
            var req = try self.client.open(method, uri, .{
                .server_header_buffer = &header_buf,
                .headers = .{
                    .authorization = .{ .override = auth },
                    .user_agent = .{ .override = "followbot2-zig" },
                },
                .extra_headers = &.{
                    .{ .name = "accept", .value = "application/vnd.github+json" },
                },
            });
            defer req.deinit();
            try req.send();
            try req.finish();
            try req.wait();

            const status = @intFromEnum(req.response.status);
            const body = req.reader().readAllAlloc(arena, 32 * 1024 * 1024) catch |e| switch (e) {
                error.StreamTooLong => try arena.alloc(u8, 0),
                else => try arena.alloc(u8, 0),
            };

            if (status == 403 or status == 429) {
                // hunt for x-ratelimit-reset in the raw header buffer
                var wait_s: u64 = 120;
                var it = req.response.iterateHeaders();
                while (it.next()) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "x-ratelimit-reset")) {
                        const reset = std.fmt.parseInt(i64, h.value, 10) catch 0;
                        const delta = reset - std.time.timestamp() + 2;
                        if (delta > 5) wait_s = @intCast(@min(delta, 900));
                    }
                }
                logMsg("RATE LIMIT on {s}, sleeping {d}s", .{ path, wait_s });
                std.time.sleep(@as(u64, @intCast(wait_s)) * @as(u64, 1_000_000_000));
                continue;
            }
            return .{ .status = status, .body = body };
        }
        return .{ .status = 0, .body = try arena.alloc(u8, 0) };
    }

    fn getJson(self: *Api, arena: Allocator, path: []const u8) !struct { status: u16, val: ?std.json.Value } {
        const r = try self.call(arena, path, .GET);
        if (r.body.len == 0) return .{ .status = r.status, .val = null };
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, r.body, .{}) catch {
            return .{ .status = r.status, .val = null };
        };
        return .{ .status = r.status, .val = parsed };
    }
};

// -------------------------------------------------------------- json help --
fn jGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}
fn jInt(v: std.json.Value, key: []const u8) ?i64 {
    const x = jGet(v, key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}
fn jStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = jGet(v, key) orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

// -------------------------------------------------------------- patterns --
fn isBotPattern(arena: Allocator, text_in: []const u8) bool {
    if (text_in.len == 0) return false;
    const text = std.ascii.allocLowerString(arena, text_in) catch return false;
    for (bot_substrings) |sub| {
        if (std.mem.indexOf(u8, text, sub) != null) return true;
    }
    var toks = std.mem.tokenizeAny(u8, text, "-_ .");
    while (toks.next()) |tok| {
        for (bot_tokens) |bt| {
            if (std.mem.eql(u8, tok, bt)) return true;
        }
    }
    return false;
}

fn isFbBio(arena: Allocator, bio_in: []const u8) bool {
    if (bio_in.len == 0) return false;
    const lowered = std.ascii.allocLowerString(arena, bio_in) catch return false;
    const norm = arena.alloc(u8, lowered.len) catch return false;
    for (lowered, 0..) |c, i| norm[i] = if (c == '-') ' ' else c;
    for (fb_substrings) |sub| {
        if (std.mem.indexOf(u8, norm, sub) != null) return true;
    }
    return false;
}

// --------------------------------------------------------------- ledger --
const Ledger = struct {
    root: std.json.Value,
    arena: Allocator, // arena backing root; all inserted values allocated here

    fn load(gpa: Allocator, path: []const u8) !Ledger {
        // heap-stable arena: an ArenaAllocator returned by value would dangle
        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        arena_state.* = std.heap.ArenaAllocator.init(gpa);
        const a = arena_state.allocator();
        if (std.fs.cwd().openFile(path, .{})) |f| {
            defer f.close();
            const data = try f.readToEndAlloc(gpa, 64 * 1024 * 1024);
            defer gpa.free(data);
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, gpa, data, .{});
            const root = try cloneValue(a, parsed);
            return .{ .root = root, .arena = a };
        } else |e| switch (e) {
            error.FileNotFound => {
                var root = std.json.Value{ .object = std.json.ObjectMap.init(a) };
                const keys = [_][]const u8{ "followed", "recip", "unfollowed", "rejected", "source" };
                for (keys) |k| try root.object.put(k, std.json.Value{ .object = std.json.ObjectMap.init(a) });
                var wl = std.json.Value{ .array = std.json.Array.init(a) };
                try wl.array.append(std.json.Value{ .string = "dezzy-music" });
                try root.object.put("whitelist", wl);
                try root.object.put("followers_seen", std.json.Value{ .array = std.json.Array.init(a) });
                return .{ .root = root, .arena = a };
            },
            else => return e,
        }
    }

    fn save(self: *Ledger, gpa: Allocator, path: []const u8) !void {
        const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
        defer gpa.free(tmp);
        {
            var f = try std.fs.cwd().createFile(tmp, .{});
            defer f.close();
            var bw = std.io.bufferedWriter(f.writer());
            try std.json.stringify(self.root, .{ .whitespace = .indent_1 }, bw.writer());
            try bw.flush();
        }
        try std.fs.cwd().rename(tmp, path);
    }

    fn obj(self: *Ledger, key: []const u8) *std.json.ObjectMap {
        return &self.root.object.getPtr(key).?.object;
    }
    fn has(self: *Ledger, key: []const u8, login: []const u8) bool {
        return self.obj(key).contains(login);
    }
    fn mark(self: *Ledger, key: []const u8, login: []const u8) !void {
        try self.obj(key).put(login, std.json.Value{ .integer = std.time.timestamp() });
    }
    fn markReason(self: *Ledger, key: []const u8, login: []const u8, reason: []const u8) !void {
        try self.obj(key).put(login, std.json.Value{ .string = try self.arena.dupe(u8, reason) });
    }
    fn count(self: *Ledger, key: []const u8) usize {
        return self.obj(key).count();
    }
    /// deep-clone a parsed json value into an arena (used when loading)
    fn cloneValue(a: Allocator, v: std.json.Value) Allocator.Error!std.json.Value {
        return switch (v) {
            .null => .null,
            .bool => |b| .{ .bool = b },
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
            .string => |s| .{ .string = try a.dupe(u8, s) },
            .array => |arr| blk: {
                var out = std.json.Array.init(a);
                try out.ensureTotalCapacity(arr.items.len);
                for (arr.items) |item| out.appendAssumeCapacity(try cloneValue(a, item));
                break :blk .{ .array = out };
            },
            .object => |objv| blk: {
                var out = std.json.ObjectMap.init(a);
                try out.ensureTotalCapacity(objv.count());
                var it = objv.iterator();
                while (it.next()) |e| {
                    try out.put(try a.dupe(u8, e.key_ptr.*), try cloneValue(a, e.value_ptr.*));
                }
                break :blk .{ .object = out };
            },
        };
    }
};

// ------------------------------------------------------------ candidates --
const Candidate = struct { login: []const u8, src: []const u8 };

fn percentEncode(arena: Allocator, raw: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    for (raw) |c| {
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == ':' or c == '<' or c == '>';
        if (safe) {
            try out.append(c);
        } else {
            try out.writer().print("%{X:0>2}", .{c});
        }
    }
    return out.items;
}

fn inStringArray(comptime arr: []const []const u8, s: []const u8) bool {
    for (arr) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn sourceWarmOrbit(api: *Api, arena: Allocator, out: *std.ArrayList(Candidate), seen: *std.StringHashMap(void)) !void {
    const routes = [_]struct { path: []const u8, tag: []const u8 }{
        .{ .path = "/repos/" ++ ME ++ "/stargazers?per_page=100", .tag = "star" },
        .{ .path = "/repos/" ++ ME ++ "/forks?per_page=100&sort=stargazers", .tag = "fork" },
    };
    for (routes) |r| {
        const res = try api.getJson(arena, r.path);
        if (res.status == 200) {
            if (res.val) |v| {
                if (v == .array) {
                    for (v.array.items) |item| {
                        const login = jStr(item, "login") orelse
                            (if (jGet(item, "owner")) |ow| jStr(ow, "login") else null) orelse
                            continue;
                        if (!seen.contains(login)) {
                            try out.append(.{ .login = try arena.dupe(u8, login), .src = r.tag });
                            try seen.put(try arena.dupe(u8, login), {});
                        }
                    }
                }
            }
        }
    }
    const res = try api.getJson(arena, "/repos/" ++ ME ++ "/issues?state=all&sort=created&direction=desc&per_page=60");
    if (res.status == 200) {
        if (res.val) |v| {
            if (v == .array) {
                for (v.array.items) |item| {
                    const user = jGet(item, "user") orelse continue;
                    const login = jStr(user, "login") orelse continue;
                    if (std.ascii.eqlIgnoreCase(login, ME)) continue;
                    if (!seen.contains(login)) {
                        try out.append(.{ .login = try arena.dupe(u8, login), .src = "author" });
                        try seen.put(try arena.dupe(u8, login), {});
                    }
                }
            }
        }
    }
}

fn sourceFollowbackSearch(api: *Api, arena: Allocator, out: *std.ArrayList(Candidate), seen: *std.StringHashMap(void), rnd: std.Random) !void {
    for (fb_queries) |q| {
        const page = rnd.intRangeLessThan(usize, 1, 4);
        const qe = try percentEncode(arena, q);
        const path = try std.fmt.allocPrint(arena, "/search/users?q={s}&per_page=50&page={d}", .{ qe, page });
        const res = try api.getJson(arena, path);
        if (res.status == 200) {
            if (res.val) |v| {
                if (jGet(v, "items")) |items| {
                    if (items == .array) {
                        for (items.array.items) |item| {
                            const login = jStr(item, "login") orelse continue;
                            if (!seen.contains(login)) {
                                try out.append(.{ .login = try arena.dupe(u8, login), .src = "fbsearch" });
                                try seen.put(try arena.dupe(u8, login), {});
                            }
                        }
                    }
                }
            }
        }
        std.time.sleep(@as(u64, 2) * @as(u64, 1_000_000_000)); // search quota politeness (same as python)
    }
}

fn sourceNeighbors(api: *Api, arena: Allocator, out: *std.ArrayList(Candidate), seen: *std.StringHashMap(void)) !void {
    for (hubs) |hub| {
        const path = try std.fmt.allocPrint(arena, "/users/{s}/followers?per_page=80", .{hub});
        const res = try api.getJson(arena, path);
        if (res.status == 200) {
            if (res.val) |v| {
                if (v == .array) {
                    for (v.array.items) |item| {
                        const login = jStr(item, "login") orelse continue;
                        if (std.ascii.eqlIgnoreCase(login, ME)) continue;
                        if (!seen.contains(login)) {
                            const tag = try std.fmt.allocPrint(arena, "neighbor:{s}", .{hub});
                            try out.append(.{ .login = try arena.dupe(u8, login), .src = tag });
                            try seen.put(try arena.dupe(u8, login), {});
                        }
                    }
                }
            }
        }
    }
}

/// Returns ok + reason; on ok stores profile meta under ledger source[login].meta.
fn vet(api: *Api, arena: Allocator, ledger: *Ledger, login: []const u8) !struct { ok: bool, why: []const u8 } {
    if (ledger.has("followed", login)) return .{ .ok = false, .why = "handled" };
    if (ledger.has("rejected", login)) return .{ .ok = false, .why = "handled" };
    if (ledger.has("unfollowed", login)) return .{ .ok = false, .why = "handled" };
    if (inStringArray(&whitelist, login)) return .{ .ok = false, .why = "whitelisted-already" };
    if (std.ascii.eqlIgnoreCase(login, ME)) return .{ .ok = false, .why = "self" };
    if (isBotPattern(arena, login)) return .{ .ok = false, .why = "botname" };

    const path = try std.fmt.allocPrint(arena, "/users/{s}", .{login});
    const res = try api.getJson(arena, path);
    if (res.status == 404) return .{ .ok = false, .why = "suspended/gone" };
    if (res.status != 200 or res.val == null) return .{ .ok = false, .why = "profile-status" };
    const p = res.val.?;
    if (!std.mem.eql(u8, jStr(p, "type") orelse "", "User")) return .{ .ok = false, .why = "org" };
    if (isBotPattern(arena, jStr(p, "name") orelse "")) return .{ .ok = false, .why = "botname-meta" };

    const created = jStr(p, "created_at") orelse "";
    if (std.mem.order(u8, created, "2026-10-01") == .gt) return .{ .ok = false, .why = "brand-new-account" };
    const upd = jStr(p, "updated_at") orelse "";
    if (upd.len > 0 and std.mem.order(u8, upd, "2026-09-01") == .lt) return .{ .ok = false, .why = "inactive-8wk" };

    // record meta in ledger.source[login].meta
    var meta = std.json.ObjectMap.init(ledger.arena);
    if (jInt(p, "followers")) |n| try meta.put("followers", .{ .integer = n });
    if (jInt(p, "following")) |n| try meta.put("following", .{ .integer = n });
    if (jInt(p, "public_repos")) |n| try meta.put("repos", .{ .integer = n });
    const bio = jStr(p, "bio") orelse "";
    try meta.put("fb_bio", .{ .bool = isFbBio(arena, bio) });
    const bio_cut = if (bio.len > 80) bio[0..80] else bio;
    try meta.put("bio", .{ .string = try ledger.arena.dupe(u8, bio_cut) });
    var src_entry = std.json.ObjectMap.init(ledger.arena);
    try src_entry.put("meta", std.json.Value{ .object = meta });
    try ledger.obj("source").put(login, std.json.Value{ .object = src_entry });
    return .{ .ok = true, .why = "ok" };
}

// --------------------------------------------------------------- actions --
fn follow(api: *Api, arena: Allocator, live: bool, login: []const u8) !bool {
    if (!live) {
        logMsg("[dry] would PUT /user/following/{s}", .{login});
        return true;
    }
    const path = try std.fmt.allocPrint(arena, "/user/following/{s}", .{login});
    const r = try api.call(arena, path, .PUT);
    return r.status == 204 or r.status == 200;
}

fn unfollow(api: *Api, arena: Allocator, live: bool, login: []const u8) !bool {
    if (!live) {
        logMsg("[dry] would DELETE /user/following/{s}", .{login});
        return true;
    }
    const path = try std.fmt.allocPrint(arena, "/user/following/{s}", .{login});
    const r = try api.call(arena, path, .DELETE);
    return r.status == 204 or r.status == 200;
}

fn followingSet(api: *Api, arena: Allocator, set: *std.StringHashMap(void)) !void {
    const res = try api.getJson(arena, "/users/" ++ ME ++ "/following?per_page=100");
    if (res.status == 200) {
        if (res.val) |v| {
            if (v == .array) {
                for (v.array.items) |item| {
                    if (jStr(item, "login")) |lg| try set.put(lg, {});
                }
            }
        }
    }
}

fn refreshFollowers(api: *Api, arena: Allocator, ledger: *Ledger, cur: *std.StringHashMap(void)) !void {
    const res = try api.getJson(arena, "/users/" ++ ME ++ "/followers?per_page=100");
    if (res.status != 200 or res.val == null) return;
    const v = res.val.?;
    if (v != .array) return;
    var seen_arr = std.json.Array.init(ledger.arena);
    for (v.array.items) |item| {
        const lg = jStr(item, "login") orelse continue;
        try seen_arr.append(.{ .string = try ledger.arena.dupe(u8, lg) });
        if (cur.contains(lg) and !ledger.has("recip", lg) and !ledger.has("unfollowed", lg)) {
            try ledger.mark("recip", lg);
            logMsg("  RECIP +{s}", .{lg});
        }
    }
    try ledger.root.object.put("followers_seen", .{ .array = seen_arr });
}

// ------------------------------------------------------------------ main --
pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // CLI: --budget N | --live | --max-follows N | --once
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    var budget_s: u64 = 900;
    var live = false;
    var max_follows: i64 = std.math.maxInt(i64);
    var once = false;
    var no_churn = false;
    var cap_override: ?i64 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--budget") and i + 1 < args.len) {
            i += 1;
            budget_s = std.fmt.parseInt(u64, args[i], 10) catch 900;
        } else if (std.mem.eql(u8, a, "--live")) {
            live = true;
        } else if (std.mem.eql(u8, a, "--max-follows") and i + 1 < args.len) {
            i += 1;
            max_follows = std.fmt.parseInt(i64, args[i], 10) catch std.math.maxInt(i64);
        } else if (std.mem.eql(u8, a, "--once")) {
            once = true;
        } else if (std.mem.eql(u8, a, "--no-churn")) {
            no_churn = true;
        } else if (std.mem.eql(u8, a, "--cap") and i + 1 < args.len) {
            i += 1;
            cap_override = std.fmt.parseInt(i64, args[i], 10) catch null;
        }
    }

    const token = std.posix.getenv("GH_TOKEN") orelse {
        std.io.getStdOut().writer().writeAll("set GH_TOKEN env var (a PAT with follow permissions)\n") catch {};
        std.process.exit(1);
    };

    const ledger_path: []const u8 = if (live) "ledger.json" else "ledger.dry.json";
    if (!live) {
        std.io.getStdOut().writer().writeAll(
            "=== DRY-RUN MODE: no PUT/DELETE will be sent. Pass --live to enable writes. ===\n",
        ) catch {};
    }

    log_file = std.fs.cwd().createFile(if (live) "followbot2-zig.log" else "followbot2-zig-dry.log", .{ .truncate = false }) catch null;
    if (log_file) |f| f.seekFromEnd(0) catch {};

    var api = Api.init(gpa, token);
    defer api.deinit();

    var ledger = try Ledger.load(gpa, ledger_path);
    var prng_state = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const rnd = prng_state.random();

    const t_end = std.time.timestamp() + @as(i64, @intCast(budget_s));
    var cycle_arena = std.heap.ArenaAllocator.init(gpa);
    defer cycle_arena.deinit();

    var pool = std.ArrayList(Candidate).init(gpa);
    defer pool.deinit();
    var exhausted = false;
    var cap: i64 = 0;
    var sent_total: i64 = 0;

    logMsg("=== followbot2-zig boot (budget {d}s, {s}) === ledger: followed={d} recip={d} unfollowed={d}", .{
        budget_s, if (live) "LIVE" else "DRY", ledger.count("followed"), ledger.count("recip"), ledger.count("unfollowed"),
    });

    run: while (std.time.timestamp() < t_end or once) {
        _ = cycle_arena.reset(.retain_capacity);
        const arena = cycle_arena.allocator();

        const me = try api.getJson(arena, "/user");
        if (me.status != 200) {
            logMsg("api down, retrying in 120s", .{});
            std.time.sleep(@as(u64, 120) * @as(u64, 1_000_000_000));
            continue :run;
        }
        const followers_n = jInt(me.val.?, "followers") orelse 0;
        var following_n = jInt(me.val.?, "following") orelse 0;
        const recip = ledger.count("recip");
        const pend = ledger.count("followed") -| recip;
        const mode: []const u8 = if (followers_n < FOLLOWERS_GOAL) "climb" else "ratio";
        const ratio = @as(f64, @floatFromInt(followers_n)) / @as(f64, @floatFromInt(@max(1, following_n)));
        logMsg("state: followers={d} following={d} ratio={d:.2} mode={s} ledger-pending={d}", .{ followers_n, following_n, ratio, mode, pend });

        // --- refresh followers, mark recips ---
        var cur = std.StringHashMap(void).init(arena);
        try followingSet(&api, arena, &cur);
        try refreshFollowers(&api, arena, &ledger, &cur);
        try ledger.save(gpa, ledger_path);

        // --- churn due pendings ---
        const now = std.time.timestamp();
        var churned: i64 = 0;
        var to_churn = std.ArrayList([]const u8).init(arena);
        if (!no_churn) {
        var it = cur.keyIterator();
        while (it.next()) |u| {
            if (ledger.has("recip", u.*)) continue;
            if (inStringArray(&whitelist, u.*)) continue;
            const followed_at: i64 = blk: {
                // python: L["followed"].get(u, 0) — unknown age means stale (0)
                const fv = ledger.obj("followed").get(u.*) orelse break :blk 0;
                break :blk switch (fv) {
                    .integer => |n| n,
                    .float => |f| @intFromFloat(f),
                    else => 0,
                };
            };
            var must_go = false;
            const over_ceiling = following_n > HARD_PENDING_CAP;
            const age = now - followed_at;
            if (std.mem.eql(u8, mode, "ratio")) {
                must_go = age > 300;
            } else if (over_ceiling or cap <= 0) {
                must_go = age > SOAK_S * 2;
            } else {
                must_go = age > SOAK_S * 8;
            }
            const second_gate = std.mem.eql(u8, mode, "ratio") or
                (age > SOAK_S * 3 and cap <= 5) or
                (@as(i64, @intCast(cur.count())) - @as(i64, @intCast(ledger.count("recip"))) > 90);
            if (must_go and second_gate) try to_churn.append(u.*);
        }
        }
        for (to_churn.items) |u| {
            if (try unfollow(&api, arena, live, u)) {
                try ledger.mark("unfollowed", u);
                _ = ledger.obj("followed").orderedRemove(u);
                churned += 1;
                following_n -= 1;
                logMsg("  churn -{s}", .{u});
                std.time.sleep(700 * @as(u64, 1_000_000));
            }
        }
        if (churned > 0) try ledger.save(gpa, ledger_path);

        // --- capacity (climb → ratio governor, identical math to python) ---
        if (std.mem.eql(u8, mode, "climb")) {
            var wl_in: i64 = 0;
            for (whitelist) |w| {
                if (cur.contains(w)) wl_in += 1;
            }
            const ceiling: i64 = if (followers_n < 10)
                @max(CLIMB_BASE, @as(i64, @intFromFloat(CLIMB_MULT * @as(f64, @floatFromInt(followers_n)))))
            else
                @min(@as(i64, @intFromFloat(CLIMB_MULT * @as(f64, @floatFromInt(followers_n)))) + CLIMB_BASE, HARD_PENDING_CAP);
            cap = @min(ceiling, HARD_PENDING_CAP) - (following_n - wl_in);
        } else {
            cap = @as(i64, @intFromFloat(@as(f64, @floatFromInt(followers_n)) / RATIO_TARGET)) - following_n;
        }
        cap = @min(cap, BATCH_MAX);
        if (cap_override) |co| cap = @min(co, BATCH_MAX); // explicit human override of the governor
        if (sent_total >= max_follows) cap = 0;
        if (cap <= 0) {
            if (once) break :run;
            const remaining = t_end - std.time.timestamp();
            const s = @min(CYCLE_SLEEP_S, @as(u64, @intCast(@max(0, remaining))));
            logMsg("  capacity 0 (mode={s}, followers={d}, following={d}); sleep {d}s", .{ mode, followers_n, following_n, s });
            std.time.sleep(s * @as(u64, 1_000_000_000));
            continue :run;
        }

        // --- source if pool low ---
        if (pool.items.len < @as(usize, @intCast(cap)) + 10 and !exhausted) {
            var raw = std.ArrayList(Candidate).init(arena);
            var seen = std.StringHashMap(void).init(arena);
            try sourceWarmOrbit(&api, arena, &raw, &seen);
            try sourceNeighbors(&api, arena, &raw, &seen);
            try sourceFollowbackSearch(&api, arena, &raw, &seen, rnd);
            // filter handled
            var filtered = std.ArrayList(Candidate).init(arena);
            for (raw.items) |c| {
                if (!ledger.has("followed", c.login) and !ledger.has("rejected", c.login) and !ledger.has("unfollowed", c.login)) {
                    try filtered.append(c);
                }
            }
            rnd.shuffle(Candidate, filtered.items);
            logMsg("  sourcing: {d} raw candidates", .{filtered.items.len});
            const vetn = @min(filtered.items.len, VET_CAP);
            for (filtered.items[0..vetn]) |c| {
                const v = try vet(&api, arena, &ledger, c.login);
                if (v.ok) {
                    try pool.append(.{ .login = try gpa.dupe(u8, c.login), .src = c.src });
                    if (ledger.obj("source").getPtr(c.login)) |sp| {
                        var inner = sp.object;
                        try inner.put("src", .{ .string = try ledger.arena.dupe(u8, c.src) });
                    }
                } else {
                    try ledger.markReason("rejected", c.login, v.why);
                }
                std.time.sleep(250 * @as(u64, 1_000_000));
            }
            if (raw.items.len == 0 and pool.items.len == 0) {
                exhausted = true;
                logMsg("  SOURCES EXHAUSTED", .{});
            }
            try ledger.save(gpa, ledger_path);
        }

        // --- follow batch (pacing identical to python: 1.6s + U(0,0.6) jitter) ---
        var sent: i64 = 0;
        while (pool.items.len > 0 and sent < cap and sent_total < max_follows) {
            const c = pool.orderedRemove(0);
            if (try follow(&api, arena, live, c.login)) {
                try ledger.mark("followed", c.login);
                sent += 1;
                sent_total += 1;
                logMsg("  +{s} ({s}) [{d}/{d}]", .{ c.login, c.src, sent, cap });
            } else {
                try ledger.markReason("rejected", c.login, "follow-failed");
                logMsg("  FAIL {s}", .{c.login});
                std.time.sleep(@as(u64, 3) * @as(u64, 1_000_000_000));
            }
            try ledger.save(gpa, ledger_path);
            const gap = FOLLOW_INTERVAL_S + rnd.float(f64) * JITTER_MAX_S;
            std.time.sleep(@intFromFloat(gap * 1_000_000_000.0));
        }
        if (once) break :run;
    }

    // final status
    {
        _ = cycle_arena.reset(.retain_capacity);
        const arena = cycle_arena.allocator();
        const me = try api.getJson(arena, "/user");
        if (me.status == 200) {
            const f = jInt(me.val.?, "followers") orelse 0;
            const g = jInt(me.val.?, "following") orelse 0;
            const r = @as(f64, @floatFromInt(f)) / @as(f64, @floatFromInt(@max(1, g)));
            logMsg("=== budget done: followers={d} following={d} ratio={d:.2} ===", .{ f, g, r });
        } else {
            logMsg("=== budget done (api read failed) ===", .{});
        }
    }
    if (log_file) |f| f.close();
}
