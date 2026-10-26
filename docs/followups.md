# Follow-ups

Small items found during review and verification. Each line: area — issue — where found.

- Favicons — after a candidate is blocked as private (SSRF guard), the fetcher marks the origin failed instead of trying the same-origin `/favicon.ico` fallback. — lead check of PR #12, 2026-10-25
