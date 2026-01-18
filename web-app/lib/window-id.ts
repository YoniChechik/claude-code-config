/**
 * Generate and manage unique window/tab ID
 * Stored in sessionStorage so it survives tab refresh but not tab close
 */

/**
 * Get existing windowId or create a new one
 * Uses sessionStorage to persist across page refreshes within the same tab
 */
export function getOrCreateWindowId(): string {
  if (typeof window === "undefined") {
    throw new Error("getOrCreateWindowId can only be called in browser context");
  }

  const stored = sessionStorage.getItem("windowId");
  if (stored) return stored;

  const windowId = crypto.randomUUID();
  sessionStorage.setItem("windowId", windowId);
  return windowId;
}

/**
 * Clear the current windowId from sessionStorage
 * Used when explicitly cleaning up a tab session
 */
export function clearWindowId(): void {
  if (typeof window === "undefined") return;
  sessionStorage.removeItem("windowId");
}

/**
 * Get the current windowId without creating a new one
 * Returns null if no windowId exists yet
 */
export function getCurrentWindowId(): string | null {
  if (typeof window === "undefined") return null;
  return sessionStorage.getItem("windowId");
}
