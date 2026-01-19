import { sessionManager } from "../lib/session-manager";
import type { Message } from "../lib/types";

describe("Window Ownership", () => {
  beforeEach(() => {
    // Clear all sessions before each test
    const sessions = sessionManager.getAllSessions();
    sessions.forEach((s) => sessionManager.deleteSession(s.id));
  });

  describe("createSession with windowId", () => {
    it("should create session with windowId", () => {
      const windowId = "test-window-123";
      const session = sessionManager.createSession("/home/user", windowId);

      expect(session.windowId).toBe(windowId);
      expect(sessionManager.validateOwnership(session.id, windowId)).toBe(true);
    });

    it("should track ownership mapping", () => {
      const windowId1 = "window-1";
      const windowId2 = "window-2";

      const session1 = sessionManager.createSession("/home/user1", windowId1);
      const session2 = sessionManager.createSession("/home/user2", windowId2);

      expect(sessionManager.getOwner(session1.id)).toBe(windowId1);
      expect(sessionManager.getOwner(session2.id)).toBe(windowId2);
    });
  });

  describe("validateOwnership", () => {
    it("should return true for correct windowId", () => {
      const windowId = "correct-window";
      const session = sessionManager.createSession("/home/user", windowId);

      expect(sessionManager.validateOwnership(session.id, windowId)).toBe(true);
    });

    it("should return false for incorrect windowId", () => {
      const windowId = "correct-window";
      const wrongWindowId = "wrong-window";
      const session = sessionManager.createSession("/home/user", windowId);

      expect(sessionManager.validateOwnership(session.id, wrongWindowId)).toBe(false);
    });

    it("should return false for non-existent session", () => {
      expect(sessionManager.validateOwnership("fake-session-id", "any-window")).toBe(false);
    });
  });

  describe("getSessionWithOwnershipCheck", () => {
    it("should return session for correct windowId", () => {
      const windowId = "correct-window";
      const session = sessionManager.createSession("/home/user", windowId);

      const retrieved = sessionManager.getSessionWithOwnershipCheck(
        session.id,
        windowId
      );

      expect(retrieved).not.toBeNull();
      expect(retrieved?.id).toBe(session.id);
    });

    it("should return null for incorrect windowId", () => {
      const windowId = "correct-window";
      const wrongWindowId = "wrong-window";
      const session = sessionManager.createSession("/home/user", windowId);

      const retrieved = sessionManager.getSessionWithOwnershipCheck(
        session.id,
        wrongWindowId
      );

      expect(retrieved).toBeNull();
    });

    it("should return null for non-existent session", () => {
      const retrieved = sessionManager.getSessionWithOwnershipCheck(
        "fake-session-id",
        "any-window"
      );

      expect(retrieved).toBeNull();
    });
  });

  describe("resumeSession with ownership", () => {
    it("should resume session with correct windowId", () => {
      const windowId = "window-123";
      const sessionId = "session-abc";
      const messages: Message[] = [
        {
          role: "user",
          content: [{ type: "text", text: "test message" }],
          timestamp: new Date(),
        },
      ];

      const session = sessionManager.resumeSession(
        sessionId,
        windowId,
        "/home/user",
        messages
      );

      expect(session.id).toBe(sessionId);
      expect(session.windowId).toBe(windowId);
      expect(session.messages).toEqual(messages);
      expect(sessionManager.validateOwnership(sessionId, windowId)).toBe(true);
    });

    it("should throw error when resuming with wrong windowId", () => {
      const windowId1 = "window-1";
      const windowId2 = "window-2";
      const sessionId = "session-abc";

      // First create/resume with windowId1
      sessionManager.resumeSession(sessionId, windowId1, "/home/user", []);

      // Try to resume with windowId2 should throw
      expect(() => {
        sessionManager.resumeSession(sessionId, windowId2, "/home/user", []);
      }).toThrow("Session ownership mismatch");
    });

    it("should allow resuming unowned session", () => {
      const windowId = "new-window";
      const sessionId = "new-session";
      const messages: Message[] = [];

      // Resume a session that has no owner yet
      const session = sessionManager.resumeSession(
        sessionId,
        windowId,
        "/home/user",
        messages
      );

      expect(session.windowId).toBe(windowId);
      expect(sessionManager.getOwner(sessionId)).toBe(windowId);
    });
  });

  describe("deleteSession ownership cleanup", () => {
    it("should remove ownership mapping when deleting session", () => {
      const windowId = "window-123";
      const session = sessionManager.createSession("/home/user", windowId);

      expect(sessionManager.getOwner(session.id)).toBe(windowId);

      sessionManager.deleteSession(session.id);

      expect(sessionManager.getOwner(session.id)).toBeUndefined();
      expect(sessionManager.validateOwnership(session.id, windowId)).toBe(false);
    });
  });

  describe("cross-tab interference prevention", () => {
    it("should isolate sessions by windowId", () => {
      const windowId1 = "tab-a";
      const windowId2 = "tab-b";

      const sessionA = sessionManager.createSession("/home/userA", windowId1);
      const sessionB = sessionManager.createSession("/home/userB", windowId2);

      // Tab A can access its own session
      expect(sessionManager.validateOwnership(sessionA.id, windowId1)).toBe(true);
      expect(sessionManager.validateOwnership(sessionA.id, windowId2)).toBe(false);

      // Tab B can access its own session
      expect(sessionManager.validateOwnership(sessionB.id, windowId2)).toBe(true);
      expect(sessionManager.validateOwnership(sessionB.id, windowId1)).toBe(false);
    });

    it("should prevent tab B from hijacking tab A's session", () => {
      const tabA = "window-tab-a";
      const tabB = "window-tab-b";

      const sessionA = sessionManager.createSession("/home/user", tabA);

      // Tab B tries to access Tab A's session
      const hijackAttempt = sessionManager.getSessionWithOwnershipCheck(
        sessionA.id,
        tabB
      );

      expect(hijackAttempt).toBeNull();
      expect(sessionManager.validateOwnership(sessionA.id, tabB)).toBe(false);
    });
  });
});
