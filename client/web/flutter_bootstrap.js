{{flutter_js}}
{{flutter_build_config}}

// The SDK's generated worker only unregisters itself. River owns its static
// app-shell cache; API/auth responses and account data never enter this cache.
(async () => {
  if ('serviceWorker' in navigator) {
    try {
      const controlled = !!navigator.serviceWorker.controller;
      const registration = await navigator.serviceWorker.register(
        'river_service_worker.js', {updateViaCache: 'none'});
      if (registration.active && !registration.installing && !registration.waiting) await registration.update();
      const worker = registration.installing || registration.waiting;
      if (worker && worker.state !== 'activated') {
        await new Promise((resolve, reject) => {
          worker.addEventListener('statechange', () => {
            if (worker.state === 'activated') resolve();
            if (worker.state === 'redundant') reject(new Error('Offline cache installation failed'));
          });
        });
      }
      await navigator.serviceWorker.ready;
      if (worker && controlled) { window.location.reload(); return; }
    } catch (error) {
      console.warn('River offline app cache is unavailable', error);
    }
  }
  _flutter.loader.load();
})();
