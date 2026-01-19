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

export function clearWindowId(): void {
  if (typeof window === "undefined") return;
  sessionStorage.removeItem("windowId");
}

export function getCurrentWindowId(): string | null {
  if (typeof window === "undefined") return null;
  return sessionStorage.getItem("windowId");
}
