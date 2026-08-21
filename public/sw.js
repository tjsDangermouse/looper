const CACHE='loopwalk-v1'; const SHELL=['/','/manifest.webmanifest','/icon.svg'];
self.addEventListener('install', e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL))));
self.addEventListener('fetch', e=>{ if(e.request.method!=='GET') return; e.respondWith(caches.match(e.request).then(c=>c||fetch(e.request).then(r=>{const copy=r.clone(); caches.open(CACHE).then(x=>x.put(e.request,copy)); return r}).catch(()=>c))); });
