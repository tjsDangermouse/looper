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
