// Client-side heartbeat manager
// Manages Web Worker for sending background heartbeats

// Public constants
const HEARTBEAT_INTERVAL = 15000; // 15 seconds

// Public functions
export function getHeartbeatClient(): _HeartbeatClient {
  if (!_heartbeatClient) {
    _heartbeatClient = new _HeartbeatClient();
  }
  return _heartbeatClient;
}

export function resetHeartbeatClient() {
  if (_heartbeatClient) {
    _heartbeatClient.stop();
    _heartbeatClient = null;
  }
}

// Private singleton instance
let _heartbeatClient: _HeartbeatClient | null = null;

// Private class
class _HeartbeatClient {
  private worker: Worker | null = null;
  private sessionIds: Set<string> = new Set();
  private fallbackIntervalId: NodeJS.Timeout | null = null;
  private usingFallback = false;

  constructor() {
    this.initializeWorker();
  }

  private initializeWorker() {
    // Only initialize in browser environment
    if (typeof window === 'undefined') {
      return;
    }

    try {
      this.worker = new Worker('/heartbeat-worker.js');

      this.worker.onerror = (error) => {
        console.error('[Heartbeat Client] Worker error:', error);
        this.fallbackToMainThread();
      };
    } catch (error) {
      console.error('[Heartbeat Client] Failed to create worker:', error);
      this.fallbackToMainThread();
    }
  }

  private fallbackToMainThread() {
    if (this.usingFallback) {
      return;
    }

    console.warn('[Heartbeat Client] Falling back to main thread setInterval');
    this.usingFallback = true;
    this.worker = null;

    // Start main thread interval
    this.fallbackIntervalId = setInterval(() => {
      this.sendHeartbeatMainThread();
    }, HEARTBEAT_INTERVAL);
  }

  private async sendHeartbeatMainThread() {
    if (this.sessionIds.size === 0) {
      return;
    }

    try {
      const response = await fetch('/api/sessions/heartbeat', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ sessionIds: Array.from(this.sessionIds) }),
      });

      if (!response.ok) {
        console.error('[Heartbeat Client] Failed to send heartbeat:', response.status);
      }
    } catch (error) {
      console.error('[Heartbeat Client] Error sending heartbeat:', error);
    }
  }

  addSession(sessionId: string) {
    if (!sessionId) {
      return;
    }

    this.sessionIds.add(sessionId);

    if (this.usingFallback) {
      // Fallback mode - send immediately
      this.sendHeartbeatMainThread();
    } else if (this.worker) {
      // Worker mode
      this.worker.postMessage({ type: 'add', sessionId });
    }
  }

  removeSession(sessionId: string) {
    if (!sessionId) {
      return;
    }

    this.sessionIds.delete(sessionId);

    if (this.usingFallback) {
      // Stop fallback interval if no sessions
      if (this.sessionIds.size === 0 && this.fallbackIntervalId) {
        clearInterval(this.fallbackIntervalId);
        this.fallbackIntervalId = null;
      }
    } else if (this.worker) {
      // Worker mode
      this.worker.postMessage({ type: 'remove', sessionId });
    }
  }

  stop() {
    // Stop worker
    if (this.worker) {
      this.worker.postMessage({ type: 'stop' });
      this.worker.terminate();
      this.worker = null;
    }

    // Stop fallback interval
    if (this.fallbackIntervalId) {
      clearInterval(this.fallbackIntervalId);
      this.fallbackIntervalId = null;
    }

    this.sessionIds.clear();
    this.usingFallback = false;
  }
}
