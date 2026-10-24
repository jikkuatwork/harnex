// harnex.zyt.app service worker: an offline-capable shell. The build stamps
// CACHE with a hash of the site, so each deploy starts a fresh cache.
const CACHE = "harnex-9af1ff7d07";
const SHELL = ["/", "/docs/start", "/docs/lanes", "/docs/mcp", "/docs/agents", "/docs/cli",
  "/assets/site.css", "/assets/site.js", "/assets/theme.js",
  "/fonts/JetBrainsMono-Regular.woff2", "/fonts/JetBrainsMono-Bold.woff2", "/fonts/JetBrainsMono-ExtraBold.woff2"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== location.origin) return;
  if (url.pathname.startsWith("/_holm") || url.pathname.startsWith("/auth/")) return;

  if (request.mode === "navigate") {
    // Pages: network first, so docs are never stale; the cache when offline.
    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response.ok) caches.open(CACHE).then((cache) => cache.put(request, response.clone()));
          return response;
        })
        .catch(() => caches.match(request).then((hit) => hit || caches.match("/")))
    );
    return;
  }

  // Assets: cache first; the cache name changes with every deploy.
  event.respondWith(
    caches.match(request).then((hit) => hit || fetch(request).then((response) => {
      if (response.ok) caches.open(CACHE).then((cache) => cache.put(request, response.clone()));
      return response;
    }))
  );
});
