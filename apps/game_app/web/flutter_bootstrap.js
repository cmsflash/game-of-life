{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    // Keep browser traffic on the game's CloudFront origin. The distribution
    // maps this path to Flutter's versioned fallback-font source and caches it.
    fontFallbackBaseUrl: "/font-fallback/",
  },
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
});
