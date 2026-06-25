#!/usr/bin/env python3
"""Render the live /steve-resume page to a print-quality PDF via WeasyPrint.

Single source of truth: we fetch the HTML the zig server actually renders (the
running dev server, localhost:9001 by default) rather than re-parsing the
markdown in Python — so the PDF can never drift from the web page's own markdown
dialect. The page's own `@media print` rules drop the nav bar and the in-page
"download PDF" link; the @page block below only sets paper size + margins.

Requires WeasyPrint (`pip install --user weasyprint`; its native libs — pango,
cairo, gdk-pixbuf — are already present on this box) and the local server up
(ops/start). Driven by ops/build_resume_pdf.

Usage: resume_to_pdf.py <out.pdf> [url]
"""
import sys
import urllib.request

DEFAULT_URL = "http://localhost:9001/steve-resume"

# Paper setup only — the page supplies its own typography + print rules.
PRINT_CSS = "@page { size: Letter; margin: 0.75in 0.9in; }"


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: resume_to_pdf.py <out.pdf> [url]")
    out = sys.argv[1]
    url = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_URL

    try:
        html = urllib.request.urlopen(url, timeout=5).read().decode("utf-8")
    except Exception as e:
        sys.exit(f"fetch failed ({url}): {e}\nIs the local server up? Run ops/start.")

    try:
        from weasyprint import HTML, CSS
    except ImportError:
        sys.exit("WeasyPrint not installed. Run: pip install --user weasyprint")

    HTML(string=html, base_url=url).write_pdf(out, stylesheets=[CSS(string=PRINT_CSS)])
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
