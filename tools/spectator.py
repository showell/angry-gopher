#!/usr/bin/env python3
"""Spectator — agent-side read-only view of Gopher games.

Acts like a human browsing Gopher: HTTP Basic auth to the CRUD pages
on port 9000, parses the HTML with BeautifulSoup. No DB reach-around.

Credentials: env GOPHER_EMAIL + GOPHER_API_KEY (or --email / --api-key).
Base URL: env GOPHER_BASE (default http://localhost:9000).

Commands:
  list            Show all visible games.
  show <id>       Show game detail + event log.
"""

import argparse
import os
import sys

import requests
from bs4 import BeautifulSoup


def get_session(email: str, api_key: str) -> requests.Session:
    s = requests.Session()
    s.auth = (email, api_key)
    return s


def fetch(session: requests.Session, base: str, path: str) -> BeautifulSoup:
    r = session.get(base + path)
    if r.status_code == 401:
        sys.exit("auth failed — check GOPHER_EMAIL / GOPHER_API_KEY")
    r.raise_for_status()
    return BeautifulSoup(r.text, "html.parser")


def cell_text(td) -> str:
    return " ".join(td.get_text(" ", strip=True).split())


def cmd_list(session: requests.Session, base: str) -> None:
    soup = fetch(session, base, "/gopher/game-lobby")
    table = soup.find("table")
    if table is None:
        print("(no games)")
        return
    headers = [cell_text(th) for th in table.find_all("th")]
    rows = []
    for tr in table.find("tbody").find_all("tr"):
        rows.append([cell_text(td) for td in tr.find_all("td")])
    if not rows:
        print("(no games)")
        return
    widths = [max(len(h), *(len(r[i]) for r in rows)) for i, h in enumerate(headers)]
    line = "  ".join(h.ljust(widths[i]) for i, h in enumerate(headers))
    print(line)
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print("  ".join(c.ljust(widths[i]) for i, c in enumerate(r)))


def cmd_show(session: requests.Session, base: str, game_id: int) -> None:
    soup = fetch(session, base, f"/gopher/game-lobby?id={game_id}")
    title = soup.find("h1")
    if title:
        print(title.get_text(strip=True))
        print("=" * len(title.get_text(strip=True)))

    tables = soup.find_all("table")
    if len(tables) >= 1:
        print("\n-- Metadata --")
        for tr in tables[0].find_all("tr"):
            cells = [cell_text(td) for td in tr.find_all("td")]
            if len(cells) == 2:
                print(f"  {cells[0]:15} {cells[1]}")

    if len(tables) >= 2:
        ev = tables[1]
        headers = [cell_text(th) for th in ev.find_all("th")]
        rows = []
        body = ev.find("tbody")
        if body:
            for tr in body.find_all("tr"):
                rows.append([cell_text(td) for td in tr.find_all("td")])
        print(f"\n-- Event Log ({len(rows)} events) --")
        if rows:
            widths = [max(len(h), *(len(r[i]) for r in rows)) for i, h in enumerate(headers)]
            print("  ".join(h.ljust(widths[i]) for i, h in enumerate(headers)))
            print("  ".join("-" * w for w in widths))
            for r in rows:
                print("  ".join(c.ljust(widths[i]) for i, c in enumerate(r)))
        else:
            print("  (no events)")


def main() -> None:
    p = argparse.ArgumentParser(description="Read-only view of Gopher games via CRUD HTML.")
    p.add_argument("--email", default=os.environ.get("GOPHER_EMAIL"))
    p.add_argument("--api-key", default=os.environ.get("GOPHER_API_KEY"))
    p.add_argument("--base", default=os.environ.get("GOPHER_BASE", "http://localhost:9000"))
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="List games")
    s = sub.add_parser("show", help="Show a game's detail")
    s.add_argument("game_id", type=int)
    args = p.parse_args()

    if not args.email or not args.api_key:
        sys.exit("set GOPHER_EMAIL + GOPHER_API_KEY (or pass --email / --api-key)")

    session = get_session(args.email, args.api_key)

    if args.cmd == "list":
        cmd_list(session, args.base)
    elif args.cmd == "show":
        cmd_show(session, args.base, args.game_id)


if __name__ == "__main__":
    main()
