import { processRegistry } from "./process-registry";
import { streamRegistry } from "./stream-registry";
import { sessionManager } from "./session-manager";

/**
 * Manages heartbeat tracking and stale session detection
 * Cleans up sessions that haven't sent a heartbeat in 30s
 */
class HeartbeatManager {
  private lastBeat = new Map<string, number>();
  private checkInterval: NodeJS.Timeout | null = null;
  private readonly STALE_TIMEOUT = 30000; // 30 seconds
  private readonly CHECK_INTERVAL = 15000; // 15 seconds

  constructor() {
    this.start();
  }

  /**
   * Start the background stale session checker
   */
  start(): void {
    if (this.checkInterval) return;

    console.log("[HeartbeatManager] Starting stale session checker");
    this.checkInterval = setInterval(() => {
      this.checkStale();
    }, this.CHECK_INTERVAL);

    // Don't keep process alive for this interval
    this.checkInterval.unref();
  }

  /**
   * Stop the background checker
   */
  stop(): void {
    if (this.checkInterval) {
      console.log("[HeartbeatManager] Stopping stale session checker");
      clearInterval(this.checkInterval);
      this.checkInterval = null;
    }
  }

  /**
   * Record a heartbeat for a session
   */
  beat(sessionId: string): void {
    const now = Date.now();
    this.lastBeat.set(sessionId, now);
    console.log(
      `[HeartbeatManager] Heartbeat received for session ${sessionId}`,
    );
  }

  /**
   * Check for stale sessions and clean them up
   */
  private async checkStale(): Promise<void> {
    const now = Date.now();
    const staleSessionIds: string[] = [];

    for (const [sessionId, lastBeat] of this.lastBeat.entries()) {
      const timeSinceLastBeat = now - lastBeat;
      if (timeSinceLastBeat > this.STALE_TIMEOUT) {
        console.log(
          `[HeartbeatManager] Session ${sessionId} is stale (${timeSinceLastBeat}ms since last beat)`,
        );
        staleSessionIds.push(sessionId);
      }
    }

    if (staleSessionIds.length > 0) {
      console.log(
        `[HeartbeatManager] Cleaning up ${staleSessionIds.length} stale sessions`,
      );
      await Promise.all(
        staleSessionIds.map((sessionId) => this.cleanupSession(sessionId)),
      );
    }
  }

  /**
   * Clean up a single session
   */
  private async cleanupSession(sessionId: string): Promise<void> {
    console.log(`[HeartbeatManager] Cleaning up session ${sessionId}`);

    try {
      // 1. Terminate Claude process
      await processRegistry.terminate(sessionId);

      // 2. Abort SSE stream
      streamRegistry.abort(sessionId);

      // 3. Delete session from sessionManager
      sessionManager.deleteSession(sessionId);

      // 4. Remove from heartbeat tracking
      this.lastBeat.delete(sessionId);

      console.log(
        `[HeartbeatManager] Successfully cleaned up session ${sessionId}`,
      );
    } catch (error) {
      console.error(
        `[HeartbeatManager] Error cleaning up session ${sessionId}:`,
        error,
      );
    }
  }

  /**
   * Remove a session from heartbeat tracking without cleanup
   */
  remove(sessionId: string): void {
    this.lastBeat.delete(sessionId);
  }

  /**
   * Get debug info about tracked sessions
   */
  getDebugInfo(): Array<{
    sessionId: string;
    lastBeat: number;
    timeSinceLastBeat: number;
    isStale: boolean;
  }> {
    const now = Date.now();
    return Array.from(this.lastBeat.entries()).map(([sessionId, lastBeat]) => {
      const timeSinceLastBeat = now - lastBeat;
      return {
        sessionId,
        lastBeat,
        timeSinceLastBeat,
        isStale: timeSinceLastBeat > this.STALE_TIMEOUT,
      };
    });
  }
}

// Export singleton instance
export const heartbeatManager = new HeartbeatManager();
