import { sessionManager } from "../lib/session-manager";
import type { Message } from "../lib/types";

describe("SessionManager", () => {
  beforeEach(() => {
    // Clear all sessions before each test
    const sessions = sessionManager.getAllSessions();
    sessions.forEach((s) => sessionManager.deleteSession(s.id));

    // Clear environment variables
    delete process.env.SSH_CONNECTION;
    delete process.env.WSL_DISTRO_NAME;
    delete process.env.CCWEB_SSH_HOST;
  });

  describe("createSession", () => {
    it("should create session with default values", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");

      expect(session.id).toBeDefined();
      expect(session.id).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
      );
      expect(session.cwd).toBe("/home/user");
      expect(session.model).toBe("claude-sonnet-4-5-20250929");
      expect(session.lastDurationMs).toBe(0);
      expect(session.messages).toEqual([]);
      expect(session.createdAt).toBeInstanceOf(Date);
    });

    it("should normalize trailing slashes in cwd", () => {
      const session = sessionManager.createSession("/home/user/", "test-window-id");
      expect(session.cwd).toBe("/home/user");
    });

    it("should detect local session type by default", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");

      expect(session.sessionType).toBe("local");
      expect(session.hostname).toBeUndefined();
      expect(session.distroName).toBeUndefined();
      expect(session.clientIp).toBeUndefined();
    });

    it("should detect SSH session type", () => {
      process.env.SSH_CONNECTION = "192.168.1.100 12345 192.168.1.1 22";

      const session = sessionManager.createSession("/home/user", "test-window-id");

      expect(session.sessionType).toBe("ssh");
      expect(session.clientIp).toBe("192.168.1.100");
      expect(session.hostname).toBeDefined();
    });

    it("should use CCWEB_SSH_HOST when provided", () => {
      process.env.SSH_CONNECTION = "192.168.1.100 12345 192.168.1.1 22";
      process.env.CCWEB_SSH_HOST = "custom-hostname";

      const session = sessionManager.createSession("/home/user", "test-window-id");

      expect(session.sessionType).toBe("ssh");
      expect(session.hostname).toBe("custom-hostname");
    });

    it("should detect WSL session type", () => {
      process.env.WSL_DISTRO_NAME = "Ubuntu-22.04";

      const session = sessionManager.createSession("/home/user", "test-window-id");

      expect(session.sessionType).toBe("wsl");
      expect(session.distroName).toBe("Ubuntu-22.04");
    });

    it("should store session in manager", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");
      const retrieved = sessionManager.getSession(session.id);

      expect(retrieved).toBe(session);
    });
  });

  describe("resumeSession", () => {
    it("should create session with provided ID and messages", () => {
      const messages: Message[] = [
        {
          role: "user",
          content: [{ type: "text", text: "Hello" }],
        },
        {
          role: "assistant",
          content: [{ type: "text", text: "Hi" }],
        },
      ];

      const session = sessionManager.resumeSession(
        "existing-session-id",
        "test-window-id",
        "/home/user",
        messages,
      );

      expect(session.id).toBe("existing-session-id");
      expect(session.cwd).toBe("/home/user");
      expect(session.messages).toBe(messages);
      expect(session.isResumed).toBe(true);
    });

    it("should normalize cwd on resume", () => {
      const session = sessionManager.resumeSession(
        "test-id",
        "test-window-id",
        "/home/user//",
        [],
      );

      expect(session.cwd).toBe("/home/user");
    });
  });

  describe("getSession", () => {
    it("should retrieve existing session", () => {
      const created = sessionManager.createSession("/home/user", "test-window-id");
      const retrieved = sessionManager.getSession(created.id);

      expect(retrieved).toBe(created);
    });

    it("should return undefined for non-existent session", () => {
      const retrieved = sessionManager.getSession("non-existent-id");
      expect(retrieved).toBeUndefined();
    });
  });

  describe("getAllSessions", () => {
    it("should return empty array when no sessions exist", () => {
      const sessions = sessionManager.getAllSessions();
      expect(sessions).toEqual([]);
    });

    it("should return all created sessions", () => {
      const session1 = sessionManager.createSession("/home/user1");
      const session2 = sessionManager.createSession("/home/user2");
      const session3 = sessionManager.createSession("/home/user3");

      const sessions = sessionManager.getAllSessions();

      expect(sessions).toHaveLength(3);
      expect(sessions).toContainEqual(session1);
      expect(sessions).toContainEqual(session2);
      expect(sessions).toContainEqual(session3);
    });
  });

  describe("deleteSession", () => {
    it("should remove session from manager", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");

      const deleted = sessionManager.deleteSession(session.id);
      expect(deleted).toBe(true);

      const retrieved = sessionManager.getSession(session.id);
      expect(retrieved).toBeUndefined();
    });

    it("should return false for non-existent session", () => {
      const deleted = sessionManager.deleteSession("non-existent-id");
      expect(deleted).toBe(false);
    });

    it("should remove CD tracker when session is deleted", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");

      sessionManager.deleteSession(session.id);

      // Attempting to get tracker should not throw (will create new one)
      expect(() => sessionManager.getCDTracker(session.id)).not.toThrow();
    });
  });

  describe("clearMessages", () => {
    it("should clear all messages from session", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");
      sessionManager.addMessage(session.id, {
        role: "user",
        content: [{ type: "text", text: "Test" }],
      });
      sessionManager.addMessage(session.id, {
        role: "assistant",
        content: [{ type: "text", text: "Response" }],
      });

      expect(session.messages).toHaveLength(2);

      sessionManager.clearMessages(session.id);

      expect(session.messages).toHaveLength(0);
    });
  });

  describe("addMessage", () => {
    it("should add message to session", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");

      const message: Message = {
        role: "user",
        content: [{ type: "text", text: "Hello" }],
      };

      sessionManager.addMessage(session.id, message);

      expect(session.messages).toHaveLength(1);
      expect(session.messages[0]).toBe(message);
    });

    it("should add multiple messages in order", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");

      const msg1: Message = {
        role: "user",
        content: [{ type: "text", text: "First" }],
      };
      const msg2: Message = {
        role: "assistant",
        content: [{ type: "text", text: "Second" }],
      };
      const msg3: Message = {
        role: "user",
        content: [{ type: "text", text: "Third" }],
      };

      sessionManager.addMessage(session.id, msg1);
      sessionManager.addMessage(session.id, msg2);
      sessionManager.addMessage(session.id, msg3);

      expect(session.messages).toHaveLength(3);
      expect(session.messages[0]).toBe(msg1);
      expect(session.messages[1]).toBe(msg2);
      expect(session.messages[2]).toBe(msg3);
    });
  });

  describe("getCDTracker", () => {
    it("should return CD tracker for session", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");
      const tracker = sessionManager.getCDTracker(session.id);

      expect(tracker).toBeDefined();
      expect(tracker.getWantedCwd()).toBeNull();
    });

    it("should return same tracker instance for multiple calls", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");
      const tracker1 = sessionManager.getCDTracker(session.id);
      const tracker2 = sessionManager.getCDTracker(session.id);

      expect(tracker1).toBe(tracker2);
    });
  });

  describe("updateSessionFromTracker", () => {
    it("should update session cwd from tracker", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");
      const tracker = sessionManager.getCDTracker(session.id);

      tracker.processStructuredOutput({
        response: "Changed",
        wanted_cwd: "/home/user/project",
      });

      sessionManager.updateSessionFromTracker(session.id);

      expect(session.cwd).toBe("/home/user/project");
      expect(session.previousCwd).toBe("/home/user");
    });

    it("should not update cwd if tracker has no wanted_cwd", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");

      sessionManager.updateSessionFromTracker(session.id);

      expect(session.cwd).toBe("/home/user");
      expect(session.previousCwd).toBeUndefined();
    });

    it("should update model from tracker", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");
      const tracker = sessionManager.getCDTracker(session.id);

      tracker.processInitEvent({ model: "claude-opus-4-5-20251101" });

      sessionManager.updateSessionFromTracker(session.id);

      expect(session.model).toBe("claude-opus-4-5-20251101");
    });

    it("should update duration from tracker", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");
      const tracker = sessionManager.getCDTracker(session.id);

      tracker.processResultEvent({ duration_ms: 5000 });

      sessionManager.updateSessionFromTracker(session.id);

      expect(session.lastDurationMs).toBe(5000);
    });

    it("should update all fields together", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");
      const tracker = sessionManager.getCDTracker(session.id);

      tracker.processInitEvent({ model: "claude-opus-4-5-20251101" });
      tracker.processStructuredOutput({
        response: "Test",
        wanted_cwd: "/new/path",
      });
      tracker.processResultEvent({ duration_ms: 3456 });

      sessionManager.updateSessionFromTracker(session.id);

      expect(session.cwd).toBe("/new/path");
      expect(session.previousCwd).toBe("/home/user");
      expect(session.model).toBe("claude-opus-4-5-20251101");
      expect(session.lastDurationMs).toBe(3456);
    });
  });

  describe("setClaudeSessionId", () => {
    it("should set Claude session ID", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");

      sessionManager.setClaudeSessionId(session.id, "claude-session-123");

      expect(session.claudeSessionId).toBe("claude-session-123");
    });

    it("should update existing Claude session ID", () => {
      const session = sessionManager.createSession("/home/user", "test-window-id");

      sessionManager.setClaudeSessionId(session.id, "first-id");
      sessionManager.setClaudeSessionId(session.id, "second-id");

      expect(session.claudeSessionId).toBe("second-id");
    });
  });

  describe("integration scenarios", () => {
    it("should handle complete session lifecycle", () => {
      // Create session
      const session = sessionManager.createSession("/home/user", "test-window-id");
      expect(session.messages).toHaveLength(0);

      // Add messages
      sessionManager.addMessage(session.id, {
        role: "user",
        content: [{ type: "text", text: "cd /tmp" }],
      });

      // Update from tracker
      const tracker = sessionManager.getCDTracker(session.id);
      tracker.processStructuredOutput({
        response: "Changed to /tmp",
        wanted_cwd: "/tmp",
      });
      tracker.processResultEvent({ duration_ms: 1000 });
      sessionManager.updateSessionFromTracker(session.id);

      expect(session.cwd).toBe("/tmp");
      expect(session.lastDurationMs).toBe(1000);
      expect(session.messages).toHaveLength(1);

      // Add response
      sessionManager.addMessage(session.id, {
        role: "assistant",
        content: [{ type: "text", text: "Changed to /tmp" }],
      });

      expect(session.messages).toHaveLength(2);

      // Delete session
      const deleted = sessionManager.deleteSession(session.id);
      expect(deleted).toBe(true);

      const retrieved = sessionManager.getSession(session.id);
      expect(retrieved).toBeUndefined();
    });

    it("should handle multiple sessions independently", () => {
      const session1 = sessionManager.createSession("/home/user1");
      const session2 = sessionManager.createSession("/home/user2");

      sessionManager.addMessage(session1.id, {
        role: "user",
        content: [{ type: "text", text: "Session 1 message" }],
      });

      sessionManager.addMessage(session2.id, {
        role: "user",
        content: [{ type: "text", text: "Session 2 message" }],
      });

      expect(session1.messages).toHaveLength(1);
      expect(session2.messages).toHaveLength(1);
      expect(session1.messages[0]).not.toBe(session2.messages[0]);
    });
  });
});
