//! **THE TOP BAR'S STYLE**, one copy: the app bar (`.app-top`, home and
//! user on either side) and the chat's (`.chat-top`, its title, links and
//! notification line). **STICKY AND OPAQUE, EVERYWHERE** (home.zig's
//! PRODUCT_DECISION): position sticky, top 0, z-index 10 and a background,
//! so scrolled content never shows through. The generic pages' stylesheet
//! (home.zig) and the chat's chrome (chat_chrome.zig) splice it in where
//! each wrote it out (shale's cookbook/zig/clones.shale found the two).

/// The rules, as a `<style>` holds them.
pub const css =
    \\.app-top { background: var(--cc-top-bar-bg, #f0ede4);
    \\           border-bottom: 1px solid var(--cc-top-bar-border, #c9bfa7);
    \\           padding: 8px 24px;
    \\           font-family: sans-serif; display: flex; justify-content: space-between;
    \\           align-items: baseline;
    \\           position: sticky; top: 0; z-index: 10; }
    \\.app-top-home a { color: var(--cc-accent, #000080); text-decoration: none; font-weight: bold; }
    \\.app-top-home a:hover { text-decoration: underline; }
    \\.app-top-user { font-size: 13px; color: var(--cc-body-muted-fg, #444); }
    \\.app-top-user a { color: var(--cc-accent, #000080); }
    \\.chat-top .chat-top-left { display: flex; align-items: baseline; gap: 14px;
    \\                           flex-wrap: wrap; min-width: 0; }
    \\.chat-top-home { color: var(--cc-accent, #000080); text-decoration: none; font-size: 13px; }
    \\.chat-top-home:hover { text-decoration: underline; }
    \\.chat-top-title { font-weight: bold; color: var(--cc-accent, #000080); }
    \\.chat-top-links { font-size: 13px; }
    \\.chat-top-links a { color: var(--cc-accent, #000080); text-decoration: none; }
    \\.chat-top-links a:hover { text-decoration: underline; }
    \\.chat-notify { font-size:13px; color:var(--cc-notify-fg, #1a5fb4); overflow:hidden; text-overflow:ellipsis;
    \\               white-space:nowrap; min-width:0; }
    \\.chat-notify a { color:inherit; }
    \\.chat-notify a:hover { text-decoration:underline; }
;
