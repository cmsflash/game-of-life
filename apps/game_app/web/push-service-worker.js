"use strict";

const defaultTitle = "Your turn in The Game of Life";
const defaultBody = "Your opponent moved. Open the match to play your turn.";

self.addEventListener("push", (event) => {
  let payload = {};
  try {
    payload = event.data?.json() ?? {};
  } catch (_) {
    payload = { body: event.data?.text() };
  }

  const notification = payload.notification ?? payload;
  const data = payload.data ?? notification.data ?? {};
  const matchId = data.matchId ?? payload.matchId;
  const path =
    data.path ??
    payload.path ??
    (matchId ? `/online/match/${encodeURIComponent(matchId)}` : "/online");

  event.waitUntil(
    self.registration.showNotification(
      notification.title ?? defaultTitle,
      {
        body: notification.body ?? defaultBody,
        icon: "/icons/Icon-192.png?v=20260815-2x2",
        badge: "/icons/Badge-96.png?v=20260815-2x2",
        tag: matchId ? `turn-${matchId}` : "turn-notification",
        renotify: true,
        data: { path },
      },
    ),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const requestedPath = event.notification.data?.path ?? "/online";
  const requestedUrl = new URL(requestedPath, self.location.origin);
  const targetUrl =
    requestedUrl.origin === self.location.origin
      ? requestedUrl
      : new URL("/online", self.location.origin);

  event.waitUntil(
    self.clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then(async (clients) => {
        for (const client of clients) {
          if (new URL(client.url).origin !== targetUrl.origin) continue;
          if ("navigate" in client) await client.navigate(targetUrl.href);
          return client.focus();
        }
        return self.clients.openWindow(targetUrl.href);
      }),
  );
});
