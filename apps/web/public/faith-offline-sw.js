/* Public Bible text and static app shell only. Never cache Auth, RPC, media or private records. */
const CACHE = "jaegun-korrv-2.0.1";
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== self.location.origin) return;
  const bible = /^\/bible\/krv\/(?:manifest|[1-9][0-9]{0,3})\.json$/.test(url.pathname);
  const staticAsset = url.pathname.startsWith("/assets/") && /\.(?:js|css|woff2)$/.test(url.pathname);
  const shell = event.request.mode === "navigate" && url.pathname === "/bible";
  if (!bible && !staticAsset && !shell) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    if (bible || staticAsset) {
      const cached = await cache.match(event.request);
      if (cached) return cached;
    }
    try { return await fetch(event.request); }
    catch (error) { const cached = await cache.match(shell ? "/bible" : event.request); if (cached) return cached; throw error; }
  })());
});
