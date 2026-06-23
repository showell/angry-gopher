# One binary, one site

Everything you see at lynrummy.com — the rummy game, the puzzles, the
first-person driving demo, the chat, the docs, and this blog — is served by a
single statically-linked [zig](https://ziglang.org) binary. No database, no
application server, no container. One process reading and writing plain files.

That isn't a stunt. It's the smallest thing that could possibly work, kept
small on purpose. The whole front end is baked into the binary at build time;
the only things that live outside it are the data (your games, your messages)
and — as of today — these blog posts, which are just markdown files in the
repo.

Publishing a post, then, is the most literal workflow imaginable: write a
markdown file, commit it, and deploy. The deploy ships the file next to the
binary, and the server renders it on the next request. No CMS, no admin screen,
no "publish" button. `git push` is the publish button.

More soon — including the longer story of what it was actually like to build a
nontrivial zig app together with Claude.
