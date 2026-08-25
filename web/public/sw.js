// Cache strategy is split by request type. The previous version was
// cache-first for everything including the HTML shell, so a phone that had
// once loaded the app kept serving that copy forever — new deploys were
// invisible without a hard refresh, which mobile browsers barely offer.
const VERSION = 'v4';
const SHELL = `looper-shell-${VERSION}`;   // HTML, manifest, icon
const ASSETS = `looper-assets-${VERSION}`; // Vite's content-hashed JS/CSS
const KEEP = [SHELL, ASSETS];
const PRECACHE = ['/', '/manifest.webmanifest', '/icon.svg'];

self.addEventListener('install', event => {
  // Activate the new worker immediately instead of waiting for every tab
  // holding the old one to close — on a phone that can be days.
  event.waitUntil(caches.open(SHELL).then(cache => cache.addAll(PRECACHE)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.filter(name => !KEEP.includes(name)).map(name => caches.delete(name)));
    await self.clients.claim();
  })());
});

const isAsset = url => url.pathname.startsWith('/assets/') || /\.(js|css|woff2?)$/.test(url.pathname);

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;   // tiles, fonts: leave to the browser
  if (url.pathname.startsWith('/v1/')) return;       // routes must never come from cache

  // Navigations: network first, so a new deploy is picked up on the next
  // launch. Cache is only the offline fallback.
  if (request.mode === 'navigate') {
    event.respondWith((async () => {
      try {
        const fresh = await fetch(request);
        const cache = await caches.open(SHELL);
        cache.put('/', fresh.clone());
        return fresh;
      } catch {
        return (await caches.match(request)) || (await caches.match('/')) || Response.error();
      }
    })());
    return;
  }

  // Hashed build output: safe to serve cache-first, the filename changes
  // whenever the contents do.
  if (isAsset(url)) {
    event.respondWith((async () => {
      const hit = await caches.match(request);
      if (hit) return hit;
      const fresh = await fetch(request);
      const cache = await caches.open(ASSETS);
      cache.put(request, fresh.clone());
      return fresh;
    })());
    return;
  }

  // Everything else (manifest, icon): serve fast, refresh in the background.
  event.respondWith((async () => {
    const cache = await caches.open(SHELL);
    const hit = await cache.match(request);
    const network = fetch(request).then(response => { cache.put(request, response.clone()); return response }).catch(() => hit);
    return hit || network;
  })());
});
