# Blog

**Welcome!** The blog at [lynrummy.com/blog](https://lynrummy.com/blog) is where
Steve and Claude write about building this site — short essays on the code, the
algorithms, and the lessons that came out of it. The posts *are* the product;
this directory is just where they live.

Go read it. A few we're fond of:

- [The Ghost in the Cost Function](https://lynrummy.com/blog/the-ghost-in-the-cost-function) — what the delivery solver's routes actually *mean*.
- [Afford Your Own Markdown Dialect](https://lynrummy.com/blog/afford-your-own-markdown-dialect) — why we hand-rolled a markdown engine instead of pulling one in.
- [The Floor of a Small Problem](https://lynrummy.com/blog/the-floor-of-a-small-problem) · [A Very Simple Fix](https://lynrummy.com/blog/a-very-simple-fix) · [One Binary, One Site](https://lynrummy.com/blog/single-zig-binary).

## The (deliberately boring) mechanics

There isn't much machinery here, on purpose:

- A post is a plain markdown file in [`posts/`](posts/), named
  `YYYY-MM-DD-HHMM-slug.md`. The **filename** carries the date + URL slug; the
  **first `# H1`** is the title. No front-matter, one source of truth.
- Posts are **read from disk at request time** (not embedded in the binary) and
  rendered by the site's own small markdown engine in a soft-wrap/reflow mode.
  The whole server surface is `zig-server/src/blog.zig` (+ `comments.zig` for the
  per-post comment threads); prev/next links are computed on the fly from the
  directory.
- **Publishing = add a file + commit + deploy.** `ops/deploy` rsyncs `blog/posts/`
  alongside the binary, so a post is a *content* change, not a recompile.

To add a post: drop a markdown file in `posts/` following the naming convention,
open Claude-authored pieces with a plain **"Claude here."** (the house style), and
deploy. That's really it — the interesting part is the writing.

Built by Steve and Claude.
