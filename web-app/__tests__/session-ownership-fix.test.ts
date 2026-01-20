import { sessionManager } from "../lib/session-manager";

describe("Session Ownership Fix Verification", () => {
  beforeEach(() => {
    const sessions = sessionManager.getAllSessions();
    sessions.forEach((s) => sessionManager.deleteSession(s.id));
  });

  it("should maintain ownership consistency across create and get", () => {
    const windowId = "test-window-123";
    const cwd = "/home/user";

    // Simulate POST /api/sessions - create session
    const session = sessionManager.createSession(cwd, windowId);

    // Verify ownership is set
    expect(sessionManager.getOwner(session.id)).toBe(windowId);
    expect(sessionManager.validateOwnership(session.id, windowId)).toBe(true);

    // Simulate GET /api/sessions/[id] - load session
    const loadedSession = sessionManager.getSession(session.id);
    expect(loadedSession).toBeDefined();
    expect(loadedSession?.id).toBe(session.id);

    // Ownership validation should pass
    expect(sessionManager.validateOwnership(session.id, windowId)).toBe(true);

    // Should fail with different windowId
    expect(sessionManager.validateOwnership(session.id, "different-window")).toBe(false);
  });

  it("should handle resumeSession and maintain ownership", () => {
    const windowId = "window-abc";
    const sessionId = "session-123";
    const cwd = "/home/user";

    // Simulate POST /api/sessions/resume
    const session = sessionManager.resumeSession(sessionId, windowId, cwd, []);

    // Verify ownership is set
    expect(sessionManager.getOwner(sessionId)).toBe(windowId);
    expect(sessionManager.validateOwnership(sessionId, windowId)).toBe(true);

    // Simulate subsequent GET /api/sessions/[id]
    const loadedSession = sessionManager.getSession(sessionId);
    expect(loadedSession).toBeDefined();
    expect(sessionManager.validateOwnership(sessionId, windowId)).toBe(true);
  });

  it("should prevent cross-window access", () => {
    const windowId1 = "window-1";
    const windowId2 = "window-2";
    const cwd = "/home/user";

    // Window 1 creates session
    const session = sessionManager.createSession(cwd, windowId1);

    // Window 1 can access
    expect(sessionManager.validateOwnership(session.id, windowId1)).toBe(true);

    // Window 2 cannot access
    expect(sessionManager.validateOwnership(session.id, windowId2)).toBe(false);

    // Verify getSessionWithOwnershipCheck works
    expect(sessionManager.getSessionWithOwnershipCheck(session.id, windowId1)).not.toBeNull();
    expect(sessionManager.getSessionWithOwnershipCheck(session.id, windowId2)).toBeNull();
  });

  it("should handle ownership transfer via resumeSession", () => {
    const oldWindowId = "old-window";
    const newWindowId = "new-window";
    const sessionId = "transferable-session";
    const cwd = "/home/user";

    // First window creates session
    sessionManager.resumeSession(sessionId, oldWindowId, cwd, []);
    expect(sessionManager.validateOwnership(sessionId, oldWindowId)).toBe(true);

    // Try to transfer to new window (this should fail with current logic)
    expect(() => {
      sessionManager.resumeSession(sessionId, newWindowId, cwd, []);
    }).toThrow("Session ownership mismatch");

    // Old window still owns it
    expect(sessionManager.validateOwnership(sessionId, oldWindowId)).toBe(true);
    expect(sessionManager.validateOwnership(sessionId, newWindowId)).toBe(false);
  });

  it("should allow resuming unowned session", () => {
    const windowId = "new-owner";
    const sessionId = "unowned-session";
    const cwd = "/home/user";

    // Resume a session that doesn't exist yet (no owner)
    const session = sessionManager.resumeSession(sessionId, windowId, cwd, []);

    expect(session.id).toBe(sessionId);
    expect(sessionManager.getOwner(sessionId)).toBe(windowId);
    expect(sessionManager.validateOwnership(sessionId, windowId)).toBe(true);
  });
});
