//! login: the identity-ISSUANCE front door.
//! Two tiers, both keyed by a numeric user id (the cookie carries the id, not the
//! name):
//!   /login       — guests: pick a non-reserved name; a fresh login allocates a
//!                  new user id. Plays Lyn Rummy, no chat.
//!   /login/full  — the chat password gate (members get a signed session cookie).
//!                  A stranger types a name and picks Log in or Create account; a
//!                  cookied guest upgrades in place (name locked); an existing
//!                  member name verifies. A show/hide eyeball replaces a confirm
//!                  field. See PwMode.
//!   /logout      — clears the cookies; "release" also deletes the user's data.
//!
//! This is the last piece the resolution port (users.zig) deliberately left for
//! last: resolution reads identity, issuance CREATES it. The account-store
//! mechanics (allocate, password, name validation, session signing) live in
//! users.zig next to their resolution peers; this file owns only the HTTP shell —
//! the forms, the cookies, the redirects — plus the new-member sidebar fan-out
//! (a direct call here — there's only the one listener).

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const users = @import("users.zig");
const storage = @import("storage.zig");
const chat = @import("chat.zig");
const html = @import("html.zig");
const store = @import("chat_store.zig");
const Bus = @import("bus.zig").Bus;

const Alloc = std.mem.Allocator;
const Request = std.http.Server.Request;

/// uid_max_age is the long-lived identity cookie's lifetime (one year).
const uid_max_age = 60 * 60 * 24 * 365;

// Cleared cookies use Max-Age=0, which tells the browser to delete the cookie now.
const clear_uid_cookie = "gopher_uid=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax";
const clear_auth_cookie = "gopher_auth=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax";

/// handle dispatches /login* — `sub` is the path after "/login" ("" for the guest
/// page, "/full" for the password gate).
pub fn handle(req: *Request, io: Io, alloc: Alloc, bus: *Bus, sub: []const u8) !void {
    if (sub.len == 0) return handleLogin(req, io, alloc);
    if (std.mem.eql(u8, sub, "/full")) return handleLoginFull(req, io, alloc, bus);
    return http.notFound(req);
}

// ── /login (guest tier) ───────────────────────────────────────────────────────

/// handleLogin: GET renders the name-entry page; POST validates the name and
/// either flags a reserved name, or allocates a fresh guest id and logs in.
fn handleLogin(req: *Request, io: Io, alloc: Alloc) !void {
    if (req.head.method == .POST) {
        // Resolve identity (reads cookie headers) BEFORE the body: iterateHeaders
        // asserts on received_head, and reading the body invalidates header
        // strings. The "currently playing as" line needs it on the error path.
        const cur = try users.currentUser(io, alloc, req);
        const body = (try http.readLimitedBody(req, alloc, 64 * 1024)) orelse return;
        const raw = (try chat.formField(alloc, body, "name")) orelse "";
        const vr = try users.validateUserName(alloc, raw);
        if (vr.err.len != 0) {
            return renderLoginPage(req, alloc, cur.name, vr.err);
        }
        if (users.isNameReserved(io, alloc, vr.name)) {
            // Password-protected name — guests can't claim it.
            return renderReservedNotice(req, alloc, vr.name);
        }
        // Guests are honor-system: a fresh login allocates a new user id with
        // this name. Identity is the cookie; protect a name by becoming a member.
        const id = try users.allocateUser(io, alloc, vr.name);
        // loginAsGuest: set the identity cookie, clear any stale member session.
        const uid_ck = try uidCookie(alloc, id);
        return sendRedirect(req, alloc, "/", &.{ uid_ck, clear_auth_cookie });
    }
    const cur = try users.currentUser(io, alloc, req);
    return renderLoginPage(req, alloc, cur.name, "");
}

// ── /login/full (member tier) ─────────────────────────────────────────────────

/// The three shapes of the password page, selected by who's asking:
///   stranger     — no identity: editable name + Log in / Create account buttons
///                  (we don't guess returning-vs-new; the button is the intent).
///   upgrade      — a cookied guest: name LOCKED (it's theirs, and /login never
///                  hands a guest a member's name, so upgrade-in-place is safe);
///                  set a password to become a member.
///   member_login — an existing member name (already a member, or an explicit
///                  ?name= from the reserved-name notice): name LOCKED, verify.
const PwMode = enum { stranger, upgrade, member_login };

/// handleLoginFull is the password gate for chat. It never bounces to /login to
/// collect a name: a stranger types one here (and chooses Log in or Create
/// account), a cookied guest upgrades in place with the name locked, and an
/// existing-member name verifies. On success it issues a member session and
/// returns to `next`.
fn handleLoginFull(req: *Request, io: Io, alloc: Alloc, bus: *Bus) !void {
    // Resolve header-derived state BEFORE touching the body: iterateHeaders
    // asserts on received_head, and the body read invalidates header/target
    // strings — so resolve identity and dup the query target up front.
    const cur = try users.currentUser(io, alloc, req);
    const target = try alloc.dupe(u8, req.head.target);
    var body: []const u8 = "";
    if (req.head.method == .POST) {
        body = (try http.readLimitedBody(req, alloc, 64 * 1024)) orelse return;
    }
    const next = sanitizeNext((try formValue(alloc, target, body, "next")) orelse "");
    const has_identity = cur.id.len != 0;

    // Pick the mode + the page name, in precedence order:
    //   1. an explicit name that's already a member ("log in as them") wins even
    //      over a cookie — this is the reserved-name notice's /login/full?name=X
    //      link. Suppressed when the stranger form's button says "register" (then
    //      a taken name should error in stranger mode, not flip to login).
    //   2. else, with an identity, the name is the cookie's (locked, so we ignore
    //      any posted name): a member re-verifies, a guest upgrades in place.
    //   3. else a free-choosing stranger (editable name, Log in / Create account).
    const explicit = try users.sanitizeUser(alloc, (try formValue(alloc, target, body, "name")) orelse "");
    const wants_register = std.mem.eql(u8, (try formValue(alloc, target, body, "action")) orelse "", "register");
    const explicit_member = explicit.len != 0 and (try users.findMemberByName(io, alloc, explicit)) != null;

    var mode: PwMode = undefined;
    var name: []const u8 = "";
    if (explicit_member and !wants_register) {
        name = explicit;
        mode = .member_login;
    } else if (has_identity) {
        name = cur.name;
        mode = if (cur.member) .member_login else .upgrade;
    } else {
        name = explicit;
        mode = .stranger;
    }

    if (req.head.method != .POST) {
        return renderPwPage(req, alloc, mode, name, next, "");
    }

    const password = (try chat.formField(alloc, body, "password")) orelse "";

    switch (mode) {
        .member_login => {
            // Verify against the existing member of this (locked) name.
            const member_id = try users.findMemberByName(io, alloc, name);
            if (member_id == null) {
                // The name lost its member between GET and POST, or a stranger
                // typed a non-member and clicked Log in — offer to register.
                return renderPwPage(req, alloc, .stranger, name, next, try std.fmt.allocPrint(alloc, "No account named \u{201C}{s}\u{201D}. Create one instead?", .{name}));
            }
            if (!users.checkUserPassword(io, alloc, member_id.?, password)) {
                return renderPwPage(req, alloc, mode, name, next, try std.fmt.allocPrint(alloc, "Wrong password for \u{201C}{s}\u{201D}.", .{name}));
            }
            return loginAsMember(req, io, alloc, member_id.?, next);
        },
        .upgrade => {
            // Cookied guest → member, in place (registerMember keeps cur.id).
            if (password.len == 0) return renderPwPage(req, alloc, mode, name, next, "Please enter a password.");
            const id = try registerMember(cur, io, alloc, name, password);
            publishUserArrived(io, alloc, bus, id, name);
            return loginAsMember(req, io, alloc, id, next);
        },
        .stranger => {
            const vr = try users.validateUserName(alloc, name);
            if (vr.err.len != 0) return renderPwPage(req, alloc, .stranger, name, next, vr.err);
            const valid = vr.name;
            const member_id = try users.findMemberByName(io, alloc, valid);
            const action = (try chat.formField(alloc, body, "action")) orelse "";
            if (std.mem.eql(u8, action, "login")) {
                if (member_id == null) return renderPwPage(req, alloc, .stranger, valid, next, try std.fmt.allocPrint(alloc, "No account named \u{201C}{s}\u{201D}. Create one instead?", .{valid}));
                if (!users.checkUserPassword(io, alloc, member_id.?, password)) {
                    return renderPwPage(req, alloc, .stranger, valid, next, try std.fmt.allocPrint(alloc, "Wrong password for \u{201C}{s}\u{201D}.", .{valid}));
                }
                return loginAsMember(req, io, alloc, member_id.?, next);
            }
            // Create account.
            if (member_id != null) return renderPwPage(req, alloc, .stranger, valid, next, try std.fmt.allocPrint(alloc, "\u{201C}{s}\u{201D} is taken — log in instead.", .{valid}));
            if (password.len == 0) return renderPwPage(req, alloc, .stranger, valid, next, "Please enter a password.");
            const id = try registerMember(cur, io, alloc, valid, password);
            publishUserArrived(io, alloc, bus, id, valid);
            return loginAsMember(req, io, alloc, id, next);
        },
    }
}

/// registerMember turns `name` into a password member and returns its id. If the
/// current guest IS this name (not yet a member), it upgrades that guest's id in
/// place so their identity and data carry over; otherwise it allocates a fresh
/// id.
fn registerMember(cur: users.ResolvedUser, io: Io, alloc: Alloc, name: []const u8, password: []const u8) ![]const u8 {
    if (cur.id.len != 0 and !cur.member and std.mem.eql(u8, cur.name, name)) {
        try users.setUserPassword(io, alloc, cur.id, password);
        return cur.id;
    }
    const id = try users.allocateUser(io, alloc, name);
    try users.setUserPassword(io, alloc, id, password);
    return id;
}

/// loginAsMember sets the identity cookie + signed member session for `id` and
/// returns to `next`.
fn loginAsMember(req: *Request, io: Io, alloc: Alloc, id: []const u8, next: []const u8) !void {
    const signed = (try users.signSessionNow(io, alloc, id)) orelse {
        // The shared session secret is missing — unrecoverable here (prod always
        // has it). Fail loudly rather than issue an unsigned/forgeable cookie.
        return req.respond("session unavailable\n", .{ .status = .internal_server_error });
    };
    const uid_ck = try uidCookie(alloc, id);
    const auth_ck = try authCookie(alloc, signed);
    users.touchUser(io, alloc, id); // logging on counts as activity
    return sendRedirect(req, alloc, next, &.{ uid_ck, auth_ck });
}

// ── /logout ───────────────────────────────────────────────────────────────────

/// handleLogout shows the logout page (GET) and performs logout (POST). A
/// "release" deletes the account + all its data, freeing the name; the default
/// (unchecked) just clears the cookies and keeps the data.
pub fn handleLogout(req: *Request, io: Io, alloc: Alloc) !void {
    const user = try users.currentUser(io, alloc, req);
    if (req.head.method == .POST) {
        const body = (try http.readLimitedBody(req, alloc, 64 * 1024)) orelse return;
        const release = (try chat.formField(alloc, body, "release")) orelse "";
        if (std.mem.eql(u8, release, "yes") and user.id.len != 0) {
            // Release: delete game data and the user record (frees the name; no id
            // is ever reissued, so no name-backdoor remains).
            storage.deleteUserData(io, alloc, user.id) catch {};
            users.deleteUserRecord(io, alloc, user.id);
        }
        return renderLogoutComplete(req, alloc);
    }
    if (user.id.len == 0) return sendRedirect(req, alloc, "/", &.{});
    return renderLogoutPage(req, alloc, user.name);
}

// ── new-member fan-out ──────────────

/// publishUserArrived broadcasts a "user-arrived" sidebar event to every
/// authorized principal except the new user, so their open conversation sidebars
/// upsert a row. URL is pre-resolved per-recipient (the client builds /chat/c/<conv>
/// without knowing its own uid). Best-effort.
fn publishUserArrived(io: Io, alloc: Alloc, bus: *Bus, new_uid: []const u8, new_name: []const u8) void {
    const authorized = users.listAuthorized(io, alloc) catch return;
    for (authorized) |u| {
        if (std.mem.eql(u8, u.id, new_uid)) continue;
        const pk = store.chatPairKey(alloc, u.id, new_uid) catch continue;
        const url = std.fmt.allocPrint(alloc, "/chat/c/{s}", .{pk}) catch continue;
        const key = store.sidebarBusKey(alloc, u.id) catch continue;
        const ev = std.fmt.allocPrint(alloc, "{{\"kind\":\"user-arrived\",\"user_id\":{f},\"user_name\":{f},\"conv\":{f},\"url\":{f}}}", .{
            std.json.fmt(new_uid, .{}), std.json.fmt(new_name, .{}), std.json.fmt(pk, .{}), std.json.fmt(url, .{}),
        }) catch continue;
        bus.publish(key, ev);
    }
}

// ── cookies + response helpers ────────────────────────────────────────────────

/// uidCookie is the long-lived identity cookie (the user id).
fn uidCookie(alloc: Alloc, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "gopher_uid={s}; Path=/; Max-Age={d}; HttpOnly; SameSite=Lax", .{ id, uid_max_age });
}

/// authCookie is the signed member session cookie.
fn authCookie(alloc: Alloc, signed: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "gopher_auth={s}; Path=/; Max-Age={d}; HttpOnly; SameSite=Lax", .{ signed, uid_max_age });
}

/// sendRedirect issues a 303 See Other to `location` carrying any Set-Cookie
/// headers. Each cookie is its own header.
fn sendRedirect(req: *Request, alloc: Alloc, location: []const u8, cookies: []const []const u8) !void {
    var hs: std.ArrayList(std.http.Header) = .empty;
    try hs.append(alloc, .{ .name = "location", .value = location });
    for (cookies) |c| try hs.append(alloc, .{ .name = "set-cookie", .value = c });
    try req.respond("", .{ .status = .see_other, .extra_headers = hs.items });
}

/// sendHTML responds with an HTML body plus any Set-Cookie headers.
fn sendHTML(req: *Request, alloc: Alloc, body: []const u8, cookies: []const []const u8) !void {
    var hs: std.ArrayList(std.http.Header) = .empty;
    try hs.append(alloc, http.html_ct);
    for (cookies) |c| try hs.append(alloc, .{ .name = "set-cookie", .value = c });
    try req.respond(body, .{ .extra_headers = hs.items });
}

/// formValue reads a form field from the POST body first, then the query string
///. `body` is "" for non-POST; `target` is the duped
/// request target (the body read invalidates the live one). The query after '?'
/// has the same a=b&c=d shape chat.formField parses.
fn formValue(alloc: Alloc, target: []const u8, body: []const u8, name: []const u8) !?[]const u8 {
    if (body.len != 0) {
        if (try chat.formField(alloc, body, name)) |v| return v;
    }
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    return chat.formField(alloc, target[q + 1 ..], name);
}

/// sanitizeNext keeps only internal redirect targets, to avoid open redirects.
fn sanitizeNext(next: []const u8) []const u8 {
    if (std.mem.startsWith(u8, next, "/") and !std.mem.startsWith(u8, next, "//")) return next;
    return "/";
}

// ── HTML pages (verbatim ports of the render* funcs) ──────────────────────────

/// renderLoginPage: the guest name-entry screen. `current` is the current display
/// name (the "Currently playing as" line); `err_msg` an optional error.
fn renderLoginPage(req: *Request, alloc: Alloc, current: []const u8, err_msg: []const u8) !void {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, login_page_head);
    if (current.len != 0) {
        try b.print(alloc, "<p class=\"muted\">Currently playing as <strong>{s}</strong>.</p>", .{try html.htmlEscape(alloc, current)});
    }
    if (err_msg.len != 0) {
        try b.print(alloc, "<p class=\"err\">{s}</p>", .{try html.htmlEscape(alloc, err_msg)});
    }
    try b.appendSlice(alloc, login_page_tail);
    try sendHTML(req, alloc, b.items, &.{});
}

/// renderReservedNotice tells a guest a name belongs to a member, offering the
/// password login or a different name.
fn renderReservedNotice(req: *Request, alloc: Alloc, name: []const u8) !void {
    const esc = try html.htmlEscape(alloc, name);
    var b: std.ArrayList(u8) = .empty;
    try b.print(alloc,
        \\<!DOCTYPE html>
        \\<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
        \\<style>
        \\body {{ font-family: sans-serif; margin: 80px auto; max-width: 440px; padding: 0 24px; }}
        \\h1 {{ color: #000080; font-size: 22px; }}
        \\.muted {{ color: #888; font-size: 14px; }}
        \\button {{ background: #000080; color: white; border: none; padding: 10px 20px;
        \\         font-size: 15px; border-radius: 4px; cursor: pointer; }}
        \\a {{ color: #000080; }}
        \\</style></head><body>
        \\<h1>“{s}” is reserved</h1>
        \\<p>That name belongs to a registered member.</p>
        \\<form method="get" action="/login/full"><input type="hidden" name="name" value="{s}">
        \\  <button type="submit">Log in with your password</button></form>
        \\<p class="muted" style="margin-top:16px"><a href="/login">← Pick a different name</a></p>
        \\</body></html>
    , .{ esc, esc });
    try sendHTML(req, alloc, b.items, &.{});
}

/// renderPwPage renders the chat password screen in one of three modes (see
/// PwMode). The name is an editable field for a stranger and a locked
/// display + hidden input otherwise; the password box carries a show/hide
/// eyeball (typo guard, no confirm field). `next` rides through as a hidden
/// field so we return where the user was headed.
fn renderPwPage(req: *Request, alloc: Alloc, mode: PwMode, name: []const u8, next: []const u8, err_msg: []const u8) !void {
    const en = try html.htmlEscape(alloc, name);
    const enx = try html.htmlEscape(alloc, next);
    var b: std.ArrayList(u8) = .empty;

    try b.print(alloc,
        \\<!DOCTYPE html>
        \\<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
        \\{s}</head><body>
    , .{login_full_css});

    // Heading + hint per mode.
    switch (mode) {
        .stranger => try b.appendSlice(alloc,
            \\<h1>Log in or create an account</h1>
            \\<p class="muted">Chat needs a password. Log in if you already have an account, or create one — your name is yours alone.</p>
        ),
        .upgrade => try b.appendSlice(alloc,
            \\<h1>Set a password to use chat</h1>
            \\<p class="muted">This keeps your name and game history, and unlocks chat. Pick a password.</p>
        ),
        .member_login => try b.appendSlice(alloc,
            \\<h1>Log in to chat</h1>
            \\<p class="muted">Enter the password for this name.</p>
        ),
    }

    if (err_msg.len != 0) {
        try b.print(alloc, "<p class=\"err\">{s}</p>", .{try html.htmlEscape(alloc, err_msg)});
    }

    try b.print(alloc, "<form method=\"post\" action=\"/login/full\"><input type=\"hidden\" name=\"next\" value=\"{s}\">", .{enx});

    // Name: editable for a stranger, locked (display + hidden field) otherwise.
    if (mode == .stranger) {
        try b.print(alloc, "<label>Name</label><input name=\"name\" type=\"text\" value=\"{s}\" maxlength=\"40\" autocomplete=\"off\" autofocus>", .{en});
    } else {
        try b.print(alloc, "<div class=\"name\">{s}</div><input type=\"hidden\" name=\"name\" value=\"{s}\">", .{ en, en });
    }

    // Password + eyeball. Autofocus the password when the name is locked.
    const pw_autofocus = if (mode == .stranger) "" else " autofocus";
    try b.print(alloc,
        \\<label>Password</label>
        \\<div class="pw-row"><input id="pw" name="password" type="password"{s}>
        \\<button type="button" class="pw-toggle" aria-label="Show password">👁</button></div>
    , .{pw_autofocus});

    // Buttons: two for a stranger (the chosen one is the intent), one otherwise.
    switch (mode) {
        .stranger => try b.appendSlice(alloc,
            \\<div class="btn-row"><button type="submit" name="action" value="login">Log in</button>
            \\<button type="submit" name="action" value="register" class="secondary">Create account</button></div>
        ),
        .upgrade => try b.appendSlice(alloc, "<button type=\"submit\" name=\"action\" value=\"register\">Create account</button>"),
        .member_login => try b.appendSlice(alloc, "<button type=\"submit\" name=\"action\" value=\"login\">Log in</button>"),
    }
    try b.appendSlice(alloc, "</form>");

    // Footer: a stranger / reserved-name visitor can drop to the no-password
    // game; the cookied upgrader just steps back.
    switch (mode) {
        .stranger => try b.appendSlice(alloc, "<p class=\"muted\" style=\"margin-top:16px\">Just want to play Lyn Rummy? <a href=\"/login\">No password needed →</a></p>"),
        .member_login => try b.appendSlice(alloc, "<p class=\"muted\" style=\"margin-top:16px\"><a href=\"/login\">← Pick a different name</a></p>"),
        .upgrade => try b.appendSlice(alloc, "<p class=\"muted\" style=\"margin-top:16px\"><a href=\"/\">← Back</a></p>"),
    }

    try b.appendSlice(alloc, pw_toggle_script);
    try b.appendSlice(alloc, "</body></html>");
    try sendHTML(req, alloc, b.items, &.{});
}

/// renderLogoutPage shows the logout confirmation with the release checkbox.
fn renderLogoutPage(req: *Request, alloc: Alloc, user: []const u8) !void {
    const esc = try html.htmlEscape(alloc, user);
    var b: std.ArrayList(u8) = .empty;
    try b.print(alloc,
        \\<!DOCTYPE html>
        \\<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
        \\<style>
        \\body {{ font-family: sans-serif; margin: 80px auto; max-width: 460px; padding: 0 24px; }}
        \\h1 {{ color: #000080; font-size: 22px; }}
        \\.muted {{ color: #888; font-size: 14px; }}
        \\.warn {{ color: #b00020; font-size: 14px; }}
        \\label {{ display: block; margin: 16px 0 8px; }}
        \\button {{ background: #000080; color: white; border: none; padding: 10px 20px;
        \\         font-size: 15px; border-radius: 4px; cursor: pointer; }}
        \\button:hover {{ background: #0000a0; }}
        \\a {{ color: #000080; margin-left: 16px; }}
        \\</style>
        \\</head><body>
        \\<h1>Log out</h1>
        \\<p>You're logged in as <strong>{s}</strong>.</p>
        \\<form method="post" action="/logout">
        \\  <label><input type="checkbox" name="release" value="yes"> Release my account and all associated data</label>
        \\  <p class="muted">Leave this unchecked to keep your games — you can log back in later from any device.</p>
        \\  <p class="warn">Checking it permanently deletes all of “{s}”'s games and puzzles and frees the name.</p>
        \\  <button type="submit">Log out</button>
        \\  <a href="/">Cancel</a>
        \\</form>
        \\</body></html>
    , .{ esc, esc });
    try sendHTML(req, alloc, b.items, &.{});
}

/// renderLogoutComplete clears the localStorage name prefill and sends the player
/// to /login. The clear-cookie headers ride on THIS response.
fn renderLogoutComplete(req: *Request, alloc: Alloc) !void {
    // Home: a logged-out visitor picks where to go next (Driving is public, plus
    // Lyn Rummy and chat).
    const body =
        \\<!doctype html><meta charset="utf-8">
        \\<script>
        \\  localStorage.removeItem('gopher_user');
        \\  location.replace('/');
        \\</script>
    ;
    try sendHTML(req, alloc, body, &.{ clear_uid_cookie, clear_auth_cookie });
}

// login_full_css: the shared stylesheet for the chat password screens.
const login_full_css =
    \\<style>
    \\body { font-family: sans-serif; margin: 80px auto; max-width: 420px; padding: 0 24px; }
    \\h1 { color: #000080; font-size: 24px; }
    \\.muted { color: #888; font-size: 14px; }
    \\.err { color: #b00020; font-size: 14px; }
    \\.name { font-size: 18px; font-weight: bold; color: #000080; margin: 12px 0 4px; }
    \\label { display: block; font-size: 13px; color: #444; margin-top: 10px; }
    \\input[type=password], input[type=text] { font-size: 16px; padding: 8px; width: 100%; box-sizing: border-box; margin: 4px 0; }
    \\button { background: #000080; color: white; border: none; padding: 10px 20px;
    \\         font-size: 15px; border-radius: 4px; cursor: pointer; margin-top: 12px; }
    \\a { color: #000080; }
    \\.pw-row { position: relative; }
    \\.pw-row input { padding-right: 46px; }
    \\.pw-toggle { position: absolute; right: 2px; top: 4px; margin: 0; padding: 6px 8px;
    \\             background: none; border: none; font-size: 17px; line-height: 1; cursor: pointer; }
    \\.btn-row { display: flex; gap: 8px; }
    \\.btn-row button { flex: 1; }
    \\button.secondary { background: #fff; color: #000080; border: 1px solid #000080; }
    \\</style>
;

// pw_toggle_script: the show/hide eyeball for the password box. A typo guard
// without a confirm field — the user can reveal what they typed. Self-contained,
// inline (these standalone pre-chat pages aren't part of the chat JS substrate).
const pw_toggle_script =
    \\<script>
    \\(function(){
    \\  var btn=document.querySelector('.pw-toggle'), inp=document.getElementById('pw');
    \\  if(!btn||!inp) return;
    \\  btn.addEventListener('click', function(){
    \\    var reveal = inp.type === 'password';
    \\    inp.type = reveal ? 'text' : 'password';
    \\    btn.textContent = reveal ? '🙈' : '👁';
    \\    btn.setAttribute('aria-label', reveal ? 'Hide password' : 'Show password');
    \\    inp.focus();
    \\  });
    \\})();
    \\</script>
;

// login_page_head / login_page_tail bracket the guest-login page's two optional
// lines (currentLine + errLine).
const login_page_head =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>
    \\<style>
    \\body { font-family: sans-serif; margin: 80px auto; max-width: 420px; padding: 0 24px; }
    \\h1 { color: #000080; }
    \\.muted { color: #888; font-size: 14px; }
    \\.err { color: #b00020; font-size: 14px; }
    \\input[type=text] { font-size: 16px; padding: 8px; width: 100%; box-sizing: border-box; margin: 8px 0; }
    \\button { background: #000080; color: white; border: none; padding: 10px 20px;
    \\         font-size: 15px; border-radius: 4px; cursor: pointer; }
    \\button:hover { background: #0000a0; }
    \\</style>
    \\</head><body>
    \\<h1>Log in to Lyn Rummy</h1>
    \\<p class="muted">No password — just a name. Letters, numbers, spaces, and apostrophes; names are unique.</p>
    \\
;

const login_page_tail =
    \\
    \\<form id="f" method="post" action="/login">
    \\  <input id="name" name="name" type="text" maxlength="40" placeholder="Your name" autofocus>
    \\  <button type="submit">Continue</button>
    \\</form>
    \\<script>
    \\  var inp = document.getElementById('name');
    \\  if (!inp.value) { var n = localStorage.getItem('gopher_user'); if (n) inp.value = n; }
    \\  document.getElementById('f').addEventListener('submit', function () {
    \\    localStorage.setItem('gopher_user', inp.value);
    \\  });
    \\</script>
    \\</body></html>
;
