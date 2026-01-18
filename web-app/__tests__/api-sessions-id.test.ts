/**
 * @jest-environment node
 */
import { NextRequest } from "next/server";
import { GET, PATCH, DELETE } from "../app/api/sessions/[id]/route";
import { sessionManager } from "../lib/session-manager";

// Mock global Request for Next.js
global.Request = class MockRequest {} as typeof Request;

describe("API /api/sessions/[id]", () => {
  beforeEach(() => {
    const sessions = sessionManager.getAllSessions();
    sessions.forEach((s) => sessionManager.deleteSession(s.id));
  });

  describe("GET /api/sessions/[id]", () => {
    it("should return session by ID", async () => {
      const windowId = "test-window-id";
      const session = sessionManager.createSession("/home/user", windowId);

      const request = new NextRequest(
        `http://localhost:6379/api/sessions/${session.id}`,
        {
          headers: { "x-window-id": windowId },
        }
      );
      const response = await GET(request, {
        params: Promise.resolve({ id: session.id }),
      });
      const data = await response.json();

      expect(response.status).toBe(200);
      expect(data.session.id).toBe(session.id);
      expect(data.session.cwd).toBe("/home/user");
    });

    it("should return 404 for non-existent session", async () => {
      const request = new NextRequest(
        "http://localhost:6379/api/sessions/non-existent-id",
        {
          headers: { "x-window-id": "test-window-id" },
        }
      );
      const response = await GET(request, {
        params: Promise.resolve({ id: "non-existent-id" }),
      });
      const data = await response.json();

      expect(response.status).toBe(404);
      expect(data.error).toBe("Session not found");
    });

    it("should return session with all fields", async () => {
      const windowId = "test-window-id";
      const session = sessionManager.createSession("/home/user", windowId);
      sessionManager.addMessage(session.id, {
        role: "user",
        content: [{ type: "text", text: "Hello" }],
      });

      const request = new NextRequest(
        `http://localhost:6379/api/sessions/${session.id}`,
        {
          headers: { "x-window-id": windowId },
        }
      );
      const response = await GET(request, {
        params: Promise.resolve({ id: session.id }),
      });
      const data = await response.json();

      expect(data.session).toHaveProperty("id");
      expect(data.session).toHaveProperty("cwd");
      expect(data.session).toHaveProperty("model");
      expect(data.session).toHaveProperty("messages");
      expect(data.session.messages).toHaveLength(1);
    });
  });

  describe("PATCH /api/sessions/[id]", () => {
    it("should update audioNotificationsEnabled setting", async () => {
      const windowId = "test-window-id";
      const session = sessionManager.createSession("/home/user", windowId);
      expect(session.audioNotificationsEnabled).toBe(true);

      const request = new NextRequest(
        `http://localhost:6379/api/sessions/${session.id}`,
        {
          method: "PATCH",
          headers: { "x-window-id": windowId },
          body: JSON.stringify({ audioNotificationsEnabled: false }),
        },
      );
      const response = await PATCH(request, {
        params: Promise.resolve({ id: session.id }),
      });
      const data = await response.json();

      expect(response.status).toBe(200);
      expect(data.session.audioNotificationsEnabled).toBe(false);
      expect(session.audioNotificationsEnabled).toBe(false);
    });

    it("should update includePartialMessages setting", async () => {
      const windowId = "test-window-id";
      const session = sessionManager.createSession("/home/user", windowId);
      expect(session.includePartialMessages).toBe(true);

      const request = new NextRequest(
        `http://localhost:6379/api/sessions/${session.id}`,
        {
          method: "PATCH",
          headers: { "x-window-id": windowId },
          body: JSON.stringify({ includePartialMessages: false }),
        },
      );
      const response = await PATCH(request, {
        params: Promise.resolve({ id: session.id }),
      });
      const data = await response.json();

      expect(response.status).toBe(200);
      expect(data.session.includePartialMessages).toBe(false);
      expect(session.includePartialMessages).toBe(false);
    });

    it("should update both settings simultaneously", async () => {
      const windowId = "test-window-id";
      const session = sessionManager.createSession("/home/user", windowId);

      const request = new NextRequest(
        `http://localhost:6379/api/sessions/${session.id}`,
        {
          method: "PATCH",
          headers: { "x-window-id": windowId },
          body: JSON.stringify({
            audioNotificationsEnabled: false,
            includePartialMessages: false,
          }),
        },
      );
      const response = await PATCH(request, {
        params: Promise.resolve({ id: session.id }),
      });
      const data = await response.json();

      expect(response.status).toBe(200);
      expect(data.session.audioNotificationsEnabled).toBe(false);
      expect(data.session.includePartialMessages).toBe(false);
    });

    it("should return 404 for non-existent session", async () => {
      const request = new NextRequest(
        "http://localhost:6379/api/sessions/non-existent-id",
        {
          method: "PATCH",
          headers: { "x-window-id": "test-window-id" },
          body: JSON.stringify({ includePartialMessages: false }),
        },
      );
      const response = await PATCH(request, {
        params: Promise.resolve({ id: "non-existent-id" }),
      });
      const data = await response.json();

      expect(response.status).toBe(404);
      expect(data.error).toBe("Session not found");
    });

    it("should preserve other session fields when updating", async () => {
      const windowId = "test-window-id";
      const session = sessionManager.createSession("/home/user", windowId);
      sessionManager.addMessage(session.id, {
        role: "user",
        content: [{ type: "text", text: "Test" }],
      });

      const originalCwd = session.cwd;
      const originalModel = session.model;
      const originalMessageCount = session.messages.length;

      const request = new NextRequest(
        `http://localhost:6379/api/sessions/${session.id}`,
        {
          method: "PATCH",
          headers: { "x-window-id": windowId },
          body: JSON.stringify({ includePartialMessages: false }),
        },
      );
      await PATCH(request, {
        params: Promise.resolve({ id: session.id }),
      });

      expect(session.cwd).toBe(originalCwd);
      expect(session.model).toBe(originalModel);
      expect(session.messages.length).toBe(originalMessageCount);
    });
  });

  describe("DELETE /api/sessions/[id]", () => {
    it("should delete existing session", async () => {
      const windowId = "test-window-id";
      const session = sessionManager.createSession("/home/user", windowId);

      const request = new NextRequest(
        `http://localhost:6379/api/sessions/${session.id}`,
        {
          method: "DELETE",
          headers: { "x-window-id": windowId },
        },
      );
      const response = await DELETE(request, {
        params: Promise.resolve({ id: session.id }),
      });
      const data = await response.json();

      expect(response.status).toBe(200);
      expect(data.success).toBe(true);

      const retrieved = sessionManager.getSession(session.id);
      expect(retrieved).toBeUndefined();
    });

    it("should return 404 for non-existent session", async () => {
      const request = new NextRequest(
        "http://localhost:6379/api/sessions/non-existent-id",
        {
          method: "DELETE",
          headers: { "x-window-id": "test-window-id" },
        },
      );
      const response = await DELETE(request, {
        params: Promise.resolve({ id: "non-existent-id" }),
      });
      const data = await response.json();

      expect(response.status).toBe(404);
      expect(data.error).toBe("Session not found");
    });

    it("should not affect other sessions", async () => {
      const windowId = "test-window-id";
      const session1 = sessionManager.createSession("/home/user1", windowId);
      const session2 = sessionManager.createSession("/home/user2", windowId);

      const request = new NextRequest(
        `http://localhost:6379/api/sessions/${session1.id}`,
        {
          method: "DELETE",
          headers: { "x-window-id": windowId },
        },
      );
      await DELETE(request, {
        params: Promise.resolve({ id: session1.id }),
      });

      const retrieved1 = sessionManager.getSession(session1.id);
      const retrieved2 = sessionManager.getSession(session2.id);

      expect(retrieved1).toBeUndefined();
      expect(retrieved2).toBeDefined();
      expect(retrieved2.cwd).toBe("/home/user2");
    });
  });

  describe("Ownership validation", () => {
    describe("GET with wrong windowId", () => {
      it("should return 403 when windowId does not match", async () => {
        const correctWindowId = "window-abc";
        const wrongWindowId = "window-xyz";
        const session = sessionManager.createSession("/home/user", correctWindowId);

        const request = new NextRequest(
          `http://localhost:6379/api/sessions/${session.id}`,
          {
            headers: { "x-window-id": wrongWindowId },
          }
        );
        const response = await GET(request, {
          params: Promise.resolve({ id: session.id }),
        });
        const data = await response.json();

        expect(response.status).toBe(403);
        expect(data.error).toBe("Session ownership validation failed");
      });

      it("should return 400 when windowId header is missing", async () => {
        const session = sessionManager.createSession("/home/user", "window-abc");

        const request = new NextRequest(
          `http://localhost:6379/api/sessions/${session.id}`
        );
        const response = await GET(request, {
          params: Promise.resolve({ id: session.id }),
        });
        const data = await response.json();

        expect(response.status).toBe(400);
        expect(data.error).toBe("x-window-id header required");
      });
    });

    describe("PATCH with wrong windowId", () => {
      it("should return 403 when windowId does not match", async () => {
        const correctWindowId = "window-abc";
        const wrongWindowId = "window-xyz";
        const session = sessionManager.createSession("/home/user", correctWindowId);

        const request = new NextRequest(
          `http://localhost:6379/api/sessions/${session.id}`,
          {
            method: "PATCH",
            headers: { "x-window-id": wrongWindowId },
            body: JSON.stringify({ audioNotificationsEnabled: false }),
          }
        );
        const response = await PATCH(request, {
          params: Promise.resolve({ id: session.id }),
        });
        const data = await response.json();

        expect(response.status).toBe(403);
        expect(data.error).toBe("Session ownership validation failed");
        // Verify the session was not modified
        expect(session.audioNotificationsEnabled).toBe(true);
      });

      it("should return 400 when windowId header is missing", async () => {
        const session = sessionManager.createSession("/home/user", "window-abc");

        const request = new NextRequest(
          `http://localhost:6379/api/sessions/${session.id}`,
          {
            method: "PATCH",
            body: JSON.stringify({ audioNotificationsEnabled: false }),
          }
        );
        const response = await PATCH(request, {
          params: Promise.resolve({ id: session.id }),
        });
        const data = await response.json();

        expect(response.status).toBe(400);
        expect(data.error).toBe("x-window-id header required");
      });
    });

    describe("DELETE with wrong windowId", () => {
      it("should return 403 when windowId does not match", async () => {
        const correctWindowId = "window-abc";
        const wrongWindowId = "window-xyz";
        const session = sessionManager.createSession("/home/user", correctWindowId);

        const request = new NextRequest(
          `http://localhost:6379/api/sessions/${session.id}`,
          {
            method: "DELETE",
            headers: { "x-window-id": wrongWindowId },
          }
        );
        const response = await DELETE(request, {
          params: Promise.resolve({ id: session.id }),
        });
        const data = await response.json();

        expect(response.status).toBe(403);
        expect(data.error).toBe("Session ownership validation failed");
        // Verify the session was not deleted
        expect(sessionManager.getSession(session.id)).toBeDefined();
      });

      it("should return 400 when windowId header is missing", async () => {
        const session = sessionManager.createSession("/home/user", "window-abc");

        const request = new NextRequest(
          `http://localhost:6379/api/sessions/${session.id}`,
          {
            method: "DELETE",
          }
        );
        const response = await DELETE(request, {
          params: Promise.resolve({ id: session.id }),
        });
        const data = await response.json();

        expect(response.status).toBe(400);
        expect(data.error).toBe("x-window-id header required");
      });
    });
  });
});
