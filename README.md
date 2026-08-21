# Looper

Mobile-first PWA for choosing circular walks. It uses MapLibre with the OpenFreeMap Bright style and routes through a Vercel serverless endpoint so the ORS key never reaches the browser.

## Run locally

`npm install`, copy `.env.example` to `.env`, add `ORS_API_KEY`, then run `npm run dev`. Vite prints both local and LAN addresses. For phone testing, use the LAN address; browser geolocation requires HTTPS on LAN origins (or localhost), so use an HTTPS tunnel/reverse proxy when testing live location on a phone. For local API testing use the built-in Vite `/api/routes` bridge (or deploy to Vercel); the `api/routes.ts` endpoint is automatically deployed by Vercel.

## HTTPS on phones and public browsers

Deploy to Vercel for a publicly trusted HTTPS URL that works on iPhone and standard browsers without certificate installation. Add `ORS_API_KEY` as a Vercel environment variable before deploying. Local LAN HTTP is useful for layout testing, but browser location permissions on a phone require the deployed HTTPS URL.

Run checks with `npm run lint`, `npm run typecheck`, `npm test`, and `npm run build`.

## Deploy

Import the repository into Vercel and add `ORS_API_KEY` in project environment variables. The app is otherwise static. The service worker caches the app shell and browser-cached selected route data; map tiles are never bulk-prefetched.

## How loops are generated

Loops are not asked for from openrouteservice's `round_trip` option, which picks its own shape from a seed and often doubles back or crosses the same bridge twice. Instead `api/_lib/waypoints.ts` places a triangle of waypoints around the start (deterministically seeded from the rounded start point and target length, so the same search always returns the same walks), and `api/routes.ts` asks ORS for ordinary walking directions through them with `optimized: false`, so the ring order is the walking order.

Every candidate is then measured by `scoreLoopRoute()` in `api/_lib/loopQuality.ts`: it resamples the geometry, finds corridors the walk covers twice, and rejects retracing, out-and-back spurs, U-turns, unbalanced legs and long thin shapes outright. Only survivors are ranked (self-overlap weighted highest) and filtered for diversity. Where the local footpath network cannot support a clean loop, the endpoint returns no routes rather than a poor one, and the app offers a longer distance, a shorter distance, or a different start point.

## Navigation limits and attribution

Keep Looper open while walking for live guidance. Browser PWAs cannot guarantee guidance while backgrounded or locked. Map attribution is displayed in-app; retain OpenStreetMap and OpenFreeMap attribution when deploying. Routes are powered by openrouteservice.
