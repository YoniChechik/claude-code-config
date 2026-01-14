/**
 * Global registry for tracking active SSE streams
 * Enables stream abortion when sessions are cleaned up
 */
class StreamRegistry {
  private controllers = new Map<string, AbortController>();

  /**
   * Register an AbortController for a session's stream
   */
  register(sessionId: string, controller: AbortController): void {
    console.log(`[StreamRegistry] Registering stream for session ${sessionId}`);
    this.controllers.set(sessionId, controller);

    // Auto-cleanup on abort
    controller.signal.addEventListener("abort", () => {
      console.log(
        `[StreamRegistry] Stream aborted, auto-unregistering session ${sessionId}`,
      );
      this.controllers.delete(sessionId);
    });
  }

  /**
   * Unregister a stream for a session
   */
  unregister(sessionId: string): void {
    const controller = this.controllers.get(sessionId);
    if (controller) {
      console.log(
        `[StreamRegistry] Unregistering stream for session ${sessionId}`,
      );
      this.controllers.delete(sessionId);
    }
  }

  /**
   * Abort a stream for a session
   */
  abort(sessionId: string): void {
    const controller = this.controllers.get(sessionId);
    if (controller && !controller.signal.aborted) {
      console.log(`[StreamRegistry] Aborting stream for session ${sessionId}`);
      controller.abort();
      this.controllers.delete(sessionId);
    } else {
      console.log(
        `[StreamRegistry] No active stream found for session ${sessionId}`,
      );
    }
  }

  /**
   * Abort all registered streams
   */
  abortAll(): void {
    console.log(
      `[StreamRegistry] Aborting all ${this.controllers.size} streams`,
    );
    const sessionIds = Array.from(this.controllers.keys());
    sessionIds.forEach((id) => this.abort(id));
  }

  /**
   * Get debug info about registered streams
   */
  getDebugInfo(): Array<{ sessionId: string; aborted: boolean }> {
    return Array.from(this.controllers.entries()).map(
      ([sessionId, controller]) => ({
        sessionId,
        aborted: controller.signal.aborted,
      }),
    );
  }
}

// Export singleton instance
export const streamRegistry = new StreamRegistry();
