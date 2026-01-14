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
      const session = sessionManager.createSession("/home/user");

      const request = new NextRequest(
        `http://localhost:3000/api/sessions/${session.id}`,
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
        "http://localhost:3000/api/sessions/non-existent-id",
      );
      const response = await GET(request, {
        params: Promise.resolve({ id: "non-existent-id" }),
      });
      const data = await response.json();

      expect(response.status).toBe(404);
      expect(data.error).toBe("Session not found");
    });

    it("should return session with all fields", async () => {
      const session = sessionManager.createSession("/home/user");
      sessionManager.addMessage(session.id, {
        role: "user",
        content: [{ type: "text", text: "Hello" }],
      });

      const request = new NextRequest(
        `http://localhost:3000/api/sessions/${session.id}`,
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
    it("should clear messages from session", async () => {
      const session = sessionManager.createSession("/home/user");
      sessionManager.addMessage(session.id, {
        role: "user",
        content: [{ type: "text", text: "Test" }],
      });
      sessionManager.addMessage(session.id, {
        role: "assistant",
        content: [{ type: "text", text: "Response" }],
      });

      expect(session.messages).toHaveLength(2);

      const request = new NextRequest(
        `http://localhost:3000/api/sessions/${session.id}`,
        { method: "PATCH" },
      );
      const response = await PATCH(request, {
        params: Promise.resolve({ id: session.id }),
      });
      const data = await response.json();

      expect(response.status).toBe(200);
      expect(data.session.messages).toHaveLength(0);
      expect(session.messages).toHaveLength(0);
    });

    it("should return 404 for non-existent session", async () => {
      const request = new NextRequest(
        "http://localhost:3000/api/sessions/non-existent-id",
        { method: "PATCH" },
      );
      const response = await PATCH(request, {
        params: Promise.resolve({ id: "non-existent-id" }),
      });
      const data = await response.json();

      expect(response.status).toBe(404);
      expect(data.error).toBe("Session not found");
    });

    it("should preserve other session fields", async () => {
      const session = sessionManager.createSession("/home/user");
      sessionManager.addMessage(session.id, {
        role: "user",
        content: [{ type: "text", text: "Test" }],
      });

      const originalCwd = session.cwd;
      const originalModel = session.model;

      const request = new NextRequest(
        `http://localhost:3000/api/sessions/${session.id}`,
        { method: "PATCH" },
      );
      await PATCH(request, {
        params: Promise.resolve({ id: session.id }),
      });

      expect(session.cwd).toBe(originalCwd);
      expect(session.model).toBe(originalModel);
    });
  });

  describe("DELETE /api/sessions/[id]", () => {
    it("should delete existing session", async () => {
      const session = sessionManager.createSession("/home/user");

      const request = new NextRequest(
        `http://localhost:3000/api/sessions/${session.id}`,
        { method: "DELETE" },
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
        "http://localhost:3000/api/sessions/non-existent-id",
        { method: "DELETE" },
      );
      const response = await DELETE(request, {
        params: Promise.resolve({ id: "non-existent-id" }),
      });
      const data = await response.json();

      expect(response.status).toBe(404);
      expect(data.error).toBe("Session not found");
    });

    it("should not affect other sessions", async () => {
      const session1 = sessionManager.createSession("/home/user1");
      const session2 = sessionManager.createSession("/home/user2");

      const request = new NextRequest(
        `http://localhost:3000/api/sessions/${session1.id}`,
        { method: "DELETE" },
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
});
