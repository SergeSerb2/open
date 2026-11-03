// page-platform §8.3 N6: a notification click focuses the tab that shows the
// target URL, or opens it (clients.openWindow → a new Today tab through P1).
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const target = event.notification.data && event.notification.data.url;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({type: 'window', includeUncontrolled: true});
    const match = windows.find(client => client.url === target);
    if (match) return match.focus();
    return self.clients.openWindow(target);
  })());
});
