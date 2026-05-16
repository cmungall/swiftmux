'use strict';

const CACHE = 'swiftmux-shell-v1';
const SHELL_ASSETS = [
    '/',
    '/index.html',
    '/app.js',
    '/style.css',
    '/manifest.webmanifest',
    '/icons/icon-192.png',
    '/icons/icon-512.png',
    'https://cdn.jsdelivr.net/npm/xterm@5.5.0/lib/xterm.min.js',
    'https://cdn.jsdelivr.net/npm/xterm@5.5.0/css/xterm.min.css',
    'https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.10.0/lib/xterm-addon-fit.min.js',
];

self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE).then(cache =>
            Promise.all(
                SHELL_ASSETS.map(url =>
                    cache.add(url).catch(() => null)
                )
            )
        )
    );
    self.skipWaiting();
});

self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys().then(keys =>
            Promise.all(
                keys.filter(k => k !== CACHE).map(k => caches.delete(k))
            )
        )
    );
    self.clients.claim();
});

self.addEventListener('fetch', (event) => {
    const url = new URL(event.request.url);

    // Never cache API or WebSocket traffic.
    if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/ws/')) {
        return;
    }

    // Cache-first for shell assets, fall through to network.
    event.respondWith(
        caches.match(event.request).then(cached =>
            cached || fetch(event.request).catch(() => cached)
        )
    );
});
