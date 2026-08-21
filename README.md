# Looper

Mobile-first PWA for choosing circular walks. It uses MapLibre with the OpenFreeMap Bright style and routes through a Vercel serverless endpoint so the ORS key never reaches the browser.

## Run locally

`npm install`, copy `.env.example` to `.env`, add `ORS_API_KEY`, then run `npm run dev`. Vite prints both local and LAN addresses. For phone testing, use the LAN address; browser geolocation requires HTTPS on LAN origins (or localhost), so use an HTTPS tunnel/reverse proxy when testing live location on a phone. For local API testing use the built-in Vite `/api/routes` bridge (or deploy to Vercel); the `api/routes.ts` endpoint is automatically deployed by Vercel.

## HTTPS on phones and public browsers

Deploy to Vercel for a publicly trusted HTTPS URL that works on iPhone and standard browsers without certificate installation. Add `ORS_API_KEY` as a Vercel environment variable before deploying. Local LAN HTTP is useful for layout testing, but browser location permissions on a phone require the deployed HTTPS URL.

Run checks with `npm run lint`, `npm run typecheck`, `npm test`, and `npm run build`.

## Deploy

Import the repository into Vercel and add `ORS_API_KEY` in project environment variables. The app is otherwise static. The service worker caches the app shell and browser-cached selected route data; map tiles are never bulk-prefetched.

## Navigation limits and attribution

Keep Looper open while walking for live guidance. Browser PWAs cannot guarantee guidance while backgrounded or locked. Map attribution is displayed in-app; retain OpenStreetMap and OpenFreeMap attribution when deploying. Routes are powered by openrouteservice.
