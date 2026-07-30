{{flutter_js}}
{{flutter_build_config}}

(() => {
  "use strict";

  const startup = document.getElementById("life-startup");
  const startupMessage = document.getElementById("life-startup-message");
  const retryButton = document.getElementById("life-startup-retry");
  const engineConfig = {
    // Keep browser traffic on the game's CloudFront origin. The distribution
    // maps this path to Flutter's versioned fallback-font source and caches it.
    fontFallbackBaseUrl: "/font-fallback/",
  };

  let startupFinished = false;

  const setStartupMessage = (message) => {
    if (!startupFinished && startupMessage) {
      startupMessage.textContent = message;
    }
  };

  const showRetry = () => {
    if (!startupFinished && retryButton) {
      retryButton.classList.add("is-visible");
      retryButton.removeAttribute("aria-hidden");
    }
  };

  const slowTimer = window.setTimeout(() => {
    setStartupMessage(
      "Still loading the game engine. A slow mobile connection can take up to a minute.",
    );
  }, 8000);

  const retryTimer = window.setTimeout(() => {
    setStartupMessage(
      "This is taking longer than usual. Check your connection or retry.",
    );
    showRetry();
  }, 30000);

  const clearStartupTimers = () => {
    window.clearTimeout(slowTimer);
    window.clearTimeout(retryTimer);
  };

  const finishStartup = () => {
    if (startupFinished) return;
    startupFinished = true;
    clearStartupTimers();
    startup?.remove();
  };

  const failStartup = (error) => {
    if (startupFinished) return;
    clearStartupTimers();
    console.error("The Game of Life failed to start.", error);
    startup?.setAttribute("data-state", "error");
    startup?.setAttribute("aria-busy", "false");
    setStartupMessage(
      "The game could not start. Check your connection, then retry.",
    );
    showRetry();
  };

  retryButton?.addEventListener("click", () => window.location.reload());

  window.addEventListener(
    "error",
    (event) => {
      if (!startupFinished) {
        failStartup(
          event.error ??
            new Error(event.message || "A startup resource could not be loaded."),
        );
      }
    },
    true,
  );

  window.addEventListener("unhandledrejection", (event) => {
    if (!startupFinished) {
      failStartup(event.reason);
    }
  });

  _flutter.loader
    .load({
      config: engineConfig,
      serviceWorkerSettings: {
        serviceWorkerVersion: {{flutter_service_worker_version}},
      },
      onEntrypointLoaded: async (engineInitializer) => {
        try {
          setStartupMessage("Starting the game…");
          const appRunner =
            await engineInitializer.initializeEngine(engineConfig);
          await appRunner.runApp();
          window.requestAnimationFrame(() => {
            window.requestAnimationFrame(finishStartup);
          });
        } catch (error) {
          failStartup(error);
        }
      },
    })
    .catch(failStartup);
})();
