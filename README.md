# Worksetu Mobile (Demo)

A mobile-app-style demo of [Worksetu](https://worksetu-web.onrender.com), for screen recordings.

- Single static page (`index.html`) with no build step, backend or database.
- All data is hardcoded; network calls are blocked in the page.
- Separate from the live Render site and its repository.

## Demo login
- Email: `master@worksetu.local` (or phone `9999999999`)

Pick Customer, Worker or Admin before signing in, or switch later under Profile → Switch portal.

## Run locally
```bash
python -m http.server 5500
```
Then open http://localhost:5500 and use the browser DevTools device toolbar (Ctrl+Shift+M).
