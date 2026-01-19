/**
 * Play an audio notification sound
 * Uses Web Audio API to generate a subtle beep
 */
export function playAudioNotification(): void {
  const audioContext = new AudioContext();
  const oscillator = audioContext.createOscillator();
  const gainNode = audioContext.createGain();

  oscillator.connect(gainNode);
  gainNode.connect(audioContext.destination);

  oscillator.frequency.value = 800;
  oscillator.type = "sine";
  gainNode.gain.setValueAtTime(0.3, audioContext.currentTime);
  gainNode.gain.exponentialRampToValueAtTime(
    0.01,
    audioContext.currentTime + 0.5,
  );

  oscillator.start(audioContext.currentTime);
  oscillator.stop(audioContext.currentTime + 0.5);
}

/**
 * Session-aware notification manager
 * Handles per-session completion notifications without cross-session interference
 */
class NotificationManager {
  private pendingNotifications = new Set<string>();
  private originalTitle: string | null = null;

  /**
   * Register a completion notification for a session
   */
  notifyComplete(sessionId: string): void {
    this.pendingNotifications.add(sessionId);
    this._updateTitle();
  }

  /**
   * Acknowledge and clear notification for a specific session
   */
  acknowledge(sessionId: string): void {
    this.pendingNotifications.delete(sessionId);
    if (this.pendingNotifications.size === 0) {
      this._clearTitle();
    } else {
      this._updateTitle();
    }
  }

  /**
   * Clear all notifications (e.g., on window focus)
   */
  clearAll(): void {
    this.pendingNotifications.clear();
    this._clearTitle();
  }

  private _updateTitle(): void {
    if (this.originalTitle === null) {
      this.originalTitle = document.title;
    }
    const count = this.pendingNotifications.size;
    document.title = `${count} task${count > 1 ? "s" : ""} done - ${this.originalTitle}`;
  }

  private _clearTitle(): void {
    if (this.originalTitle !== null) {
      document.title = this.originalTitle;
      this.originalTitle = null;
    }
  }
}

// Singleton instance
export const notificationManager = new NotificationManager();
