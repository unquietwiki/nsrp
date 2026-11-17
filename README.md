# nsrp: "Nim Steam Review Parser"

_nsrp_ is a Steam(TM) game review downloader, that outputs in Markdown, HTML, or JSON; for either casual reading, or consumption by an LLM for analysis.

## Examples

_Windows precompiled version may need HTTPS libraries_

- nsrp -n:50 -m:1459560 -> generates 1459560_review.md for "Untitled Space Game", newest 50 responses
- nsrp -d:"cs2data" -h:730 -> generates 730_review.html & .md for "Counter-Strike 2", and saves it in "cs2data" subfolder
- nsrp -j:1454400 -> generates 1454400_review.json for "Cookie Clicker"
- nsrp -c:"sessionid=ABC..." -m:730 -> sends a logged-in Steam session cookie (helps when the appreviews endpoint is bot-blocked), then generates 730_review.md

## Compilation

```
nimble install markdown
nim c -d:ssl src/nsrp.nim
```

## References

- https://partner.steamgames.com/doc/store/getreviews -> API documentation
- https://github.com/woctezuma/download-steam-reviews -> Inspired this application
- https://www.markdownguide.org/ -> Markdown documentation
- https://github.com/soasme/nim-markdown/ -> Markdown-to-HTML renderer

## AI usage

Anthropic Claude was used to supply minor changes and functions, and acted as a code review mechanism.

## Changelog

- 2026.09.07.1 -> Added HTML output
- 2026.09.02.3 -> Added Markdown output
- 2026.08.30.1 -> First release: JSON-only
