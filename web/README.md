# Looper web app

The web PWA is a self-contained Vite/React project. It consumes the route
service only through [Loop API v1](../route-service/contracts/loop-api/v1.md).

## Run and check

```bash
npm install
npm run dev
npm run lint
npm run typecheck
npm test
npm run build
```

The development server proxies `/v1` to `http://localhost:8988` by default.
Set `LOOPER_API_URL` to use another local service, or set
`VITE_LOOPER_API_BASE` to the deployed route-service URL when building for
production. A deployment-ready example is in `.env.example`.

## Map style editor

Run the normal development server, then open
[`http://localhost:5173/map-style-editor`](http://localhost:5173/map-style-editor).
Every Looper basemap category has a live colour control. Drafts save automatically in
that browser; **Copy palette JSON** produces the values needed to update the shared web
and iOS style configuration. The coloured loops on the preview map use the app's real
route colours, so they act as a contrast check rather than another editable basemap layer.
