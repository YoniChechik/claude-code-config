import type { CDTrackingState, StructuredOutput } from "./types";

/**
 * CD Tracker - Ported from ccui.sh lines 32-73
 *
 * Tracks:
 * - Current working directory from StructuredOutput (cwd field)
 * - Model information from init events
 * - Duration from result events
 */
export class CDTracker {
  private state: CDTrackingState = {
    sessionCwd: null,
    lastDurationMs: 0,
    model: "claude-sonnet-4-5-20250929", // default
  };

  /**
   * Process JSON output from Claude streaming response
   * Equivalent to: SESSION_CWD=$(echo "$json" | jq -r '.cwd // empty' 2>/dev/null)
   */
  processStructuredOutput(output: StructuredOutput): void {
    if (output.cwd) {
      this.state.sessionCwd = output.cwd;
    }
  }

  /**
   * Process init event to extract model
   * Equivalent to: model=$(grep '"subtype":"init"' "$raw" | jq -r '.model // empty')
   */
  processInitEvent(event: { model?: string }): void {
    if (event.model) {
      this.state.model = event.model;
    }
  }

  /**
   * Process result event to extract duration
   * Equivalent to: LAST_MS=$(echo "$result" | jq -r '.duration_ms // 0')
   */
  processResultEvent(event: { duration_ms?: number }): void {
    if (event.duration_ms !== undefined) {
      this.state.lastDurationMs = event.duration_ms;
    }
  }

  /**
   * Get current tracked working directory
   * Returns null if no cd has occurred
   */
  getCurrentCwd(): string | null {
    return this.state.sessionCwd;
  }

  /**
   * Get last command duration in milliseconds
   */
  getLastDurationMs(): number {
    return this.state.lastDurationMs;
  }

  /**
   * Get current model
   */
  getModel(): string {
    return this.state.model;
  }

  /**
   * Get full state (for debugging)
   */
  getState(): CDTrackingState {
    return { ...this.state };
  }

  /**
   * Reset state (for new session)
   */
  reset(): void {
    this.state = {
      sessionCwd: null,
      lastDurationMs: 0,
      model: "claude-sonnet-4-5-20250929",
    };
  }
}
