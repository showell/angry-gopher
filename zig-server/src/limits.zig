//! limits: **EVERY BOUND ON WHAT A REQUEST MAY BRING, DEFINED ONCE**
//! (Steve, 2026-10-07; gopher-metal HOST.md, "Limits").
//!
//! The same bound used to be written wherever it was needed: the request
//! head's 16 KiB in Linux's server.zig and again in gopher-metal's kernel,
//! each route's body cap as a literal at its call, the upload caps inside
//! chat_upload.zig, and Caddy's caps in deploy/Caddyfile. Now each is here,
//! and everything else reads it:
//!
//!   - both hosts size the request head's buffer from `head_bytes`
//!     (server.zig; gopher-metal's probe/gopher.zig, as router.request_limits);
//!   - each route reads its body with its cap from `body`;
//!   - tools/check_caddy_limits.py fails `ops/check_zig` if Caddy would refuse
//!     a body the application allows (its caps below these) or lets through
//!     one far past them (a cap gone stale).
//!
//! The Store's limits (a name, a path, a depth) are FAT's and live in
//! store.zig, checked against gopher-metal's by its tools/check_limits.py.

/// The request line and headers together, the most either host reads before
/// answering 431.
pub const head_bytes = 16 * 1024;

/// Each route's body cap, in bytes: a body past it is refused with 413.
pub const body = struct {
    /// A form an admin sends with a secret in it (rotation, a backup's key).
    pub const secret_form = 4096;
    /// The admin's retire form: a list of names to keep.
    pub const retire_form = 16 * 1024;
    /// An ordinary form: logins, settings, a player's name, admin forms.
    pub const form = 64 * 1024;
    /// One chat message, as typed.
    pub const chat_message = 64 * 1024;
    /// A reaction: a message number and an emoji.
    pub const reaction = 1024;
    /// A document, whole.
    pub const doc = 1 << 20;
    /// A new game's starting state.
    pub const game_new_session = 256 * 1024;
    /// One move or annotation appended to a game, or to a puzzle.
    pub const game_append = 64 * 1024;

    /// An uploaded picture, and a video.
    pub const upload_image = 10 << 20;
    pub const upload_video = 100 << 20;
    /// What an upload's body is read up to before its kind is known: the
    /// larger kind, and a margin for the multipart framing around it.
    pub const upload_any = upload_video + (1 << 20);

    /// The largest body any route but the upload takes: Caddy's ordinary cap
    /// must be at least this.
    pub const largest_ordinary = @max(secret_form, retire_form, form, chat_message, reaction, doc, game_new_session, game_append);
};
