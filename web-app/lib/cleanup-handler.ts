// Tab cleanup handler
// Sends cleanup requests when tab closes or navigates away

// Public functions
export function getCleanupHandler(): _CleanupHandler {
  if (!_cleanupHandler) {
    _cleanupHandler = new _CleanupHandler();
  }
  return _cleanupHandler;
}

export function resetCleanupHandler() {
  if (_cleanupHandler) {
    _cleanupHandler.stop();
    _cleanupHandler = null;
  }
}

// Private singleton instance
let _cleanupHandler: _CleanupHandler | null = null;

// Private class
class _CleanupHandler {
  private sessionIds: Set<string> = new Set();
  private pagehideListener: (() => void) | null = null;
  private beforeunloadListener: (() => void) | null = null;

  addSession(sessionId: string) {
    if (!sessionId) {
      return;
    }
    this.sessionIds.add(sessionId);
  }

  removeSession(sessionId: string) {
    if (!sessionId) {
      return;
    }
    this.sessionIds.delete(sessionId);
  }

  private sendCleanup = () => {
    if (this.sessionIds.size === 0) {
      return;
    }

    const payload = JSON.stringify({
      sessionIds: Array.from(this.sessionIds),
    });

    // Use sendBeacon for best-effort delivery
    // Works even if tab is closing
    if (navigator.sendBeacon) {
      navigator.sendBeacon('/api/sessions/cleanup', payload);
    } else {
      // Fallback to synchronous fetch (may not complete if tab closes)
      try {
        fetch('/api/sessions/cleanup', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
          },
          body: payload,
          keepalive: true, // Keep request alive even if tab closes
        });
      } catch (error) {
        console.error('[Cleanup Handler] Error sending cleanup:', error);
      }
    }
  };

  start() {
    // Only initialize in browser environment
    if (typeof window === 'undefined') {
      return;
    }

    // Register pagehide listener (more reliable than beforeunload)
    this.pagehideListener = () => {
      this.sendCleanup();
    };
    window.addEventListener('pagehide', this.pagehideListener);

    // Register beforeunload as backup
    this.beforeunloadListener = () => {
      this.sendCleanup();
    };
    window.addEventListener('beforeunload', this.beforeunloadListener);
  }

  stop() {
    if (this.pagehideListener) {
      window.removeEventListener('pagehide', this.pagehideListener);
      this.pagehideListener = null;
    }

    if (this.beforeunloadListener) {
      window.removeEventListener('beforeunload', this.beforeunloadListener);
      this.beforeunloadListener = null;
    }

    this.sessionIds.clear();
  }
}
