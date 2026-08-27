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
The editor manages the complete custom-style catalogue and the route-option colours.
You can create, duplicate, rename and delete styles while every palette change appears
on the live vector map. **Save to apps** validates the catalogue and writes all three
tracked files together:

- `../map-styles.json` — the human-readable source of truth.
- `src/mapStyleConfig.generated.ts` — consumed by the web app.
- `../ios/LooperKit/Sources/LooperKit/MapStyleConfig.generated.swift` — consumed by iOS.

The write endpoint exists only in the local Vite development server and refuses remote
connections. Do not edit the generated TypeScript or Swift files by hand; reopen the
editor, make the change, and save again. Restart or rebuild the iOS app after saving so
Xcode recompiles the generated Swift package source.
