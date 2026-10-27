'use strict';
// Generated from the release's static asset hashes. This cache contains no
// API/auth responses, Matrix data, linked images, peer files or sticker bytes.
const CACHE = __RIVER_CACHE__;
const RESOURCES = __RIVER_RESOURCES__;
const CORE = __RIVER_CORE__;
const base = new URL(self.registration.scope);
const assetUrl = (key) => new URL(key.split('/').map(encodeURIComponent).join('/'), base).href;

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await cache.addAll(CORE.map((key) => new Request(assetUrl(key), {cache: 'reload'})));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key.startsWith('river-shell-') && key !== CACHE) await caches.delete(key);
    }
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.origin !== base.origin || !url.pathname.startsWith(base.pathname)) return;
  let key;
  try { key = decodeURIComponent(url.pathname.slice(base.pathname.length)); }
  catch (_) { return; }
  // Never serve cached content in place of session checks or authorization.
  if (/^(api|auth|_matrix|\.well-known)(\/|$)/.test(key)) return;
  if (event.request.mode === 'navigate') {
    event.respondWith((async () => {
      try { return await fetch(event.request); }
      catch (error) {
        const cached = await (await caches.open(CACHE)).match(assetUrl('index.html'));
        if (cached) return cached;
        throw error;
      }
    })());
    return;
  }
  if (!Object.prototype.hasOwnProperty.call(RESOURCES, key)) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const request = new Request(assetUrl(key));
    const cached = await cache.match(request);
    if (cached) return cached;
    const response = await fetch(new Request(event.request, {cache: 'reload'}));
    if (response.ok && !response.redirected && response.type !== 'opaque') {
      await cache.put(request, response.clone());
    }
    return response;
  })());
});
