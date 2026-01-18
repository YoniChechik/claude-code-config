/**
 * @jest-environment node
 */
import { NextRequest } from "next/server";
import { GET, POST } from "../app/api/sessions/route";
import { sessionManager } from "../lib/session-manager";

// Mock global Request for Next.js
global.Request = class MockRequest {} as typeof Request;

describe("API /api/sessions", () => {
  beforeEach(() => {
    const sessions = sessionManager.getAllSessions();
    sessions.forEach((s) => sessionManager.deleteSession(s.id));
  });

  describe("GET /api/sessions", () => {
    it("should return empty list when no sessions exist", async () => {
      const response = await GET();
      const data = await response.json();

      expect(response.status).toBe(200);
      expect(data.sessions).toEqual([]);
    });

    it("should return all sessions", async () => {
      const session1 = sessionManager.createSession("/home/user1", "window-1");
      const session2 = sessionManager.createSession("/home/user2", "window-2");

      const response = await GET();
      const data = await response.json();

      expect(response.status).toBe(200);
      expect(data.sessions).toHaveLength(2);
      expect(data.sessions.map((s: { id: string }) => s.id)).toContain(
        session1.id,
      );
      expect(data.sessions.map((s: { id: string }) => s.id)).toContain(
        session2.id,
      );
    });

    it("should return sessions with correct structure", async () => {
      sessionManager.createSession("/home/test", "test-window");

      const response = await GET();
      const data = await response.json();

      expect(data.sessions[0]).toHaveProperty("id");
      expect(data.sessions[0]).toHaveProperty("cwd");
      expect(data.sessions[0]).toHaveProperty("model");
      expect(data.sessions[0]).toHaveProperty("messages");
      expect(data.sessions[0]).toHaveProperty("createdAt");
    });
  });

  describe("POST /api/sessions", () => {
    it("should create new session with valid cwd", async () => {
      const requestBody = { cwd: "/home/user", windowId: "test-window-id" };
      const request = new NextRequest("http://localhost:6379/api/sessions", {
        method: "POST",
        body: JSON.stringify(requestBody),
      });

      const response = await POST(request);
      const data = await response.json();

      expect(response.status).toBe(200);
      expect(data.session).toBeDefined();
      expect(data.session.cwd).toBe("/home/user");
      expect(data.session.id).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
      );
    });

    it("should return 400 when cwd is missing", async () => {
      const requestBody = {};
      const request = new NextRequest("http://localhost:6379/api/sessions", {
        method: "POST",
        body: JSON.stringify(requestBody),
      });

      const response = await POST(request);
      const data = await response.json();

      expect(response.status).toBe(400);
      expect(data.error).toBe("cwd is required");
    });

    it("should normalize cwd with trailing slash", async () => {
      const requestBody = { cwd: "/home/user/", windowId: "test-window-id" };
      const request = new NextRequest("http://localhost:6379/api/sessions", {
        method: "POST",
        body: JSON.stringify(requestBody),
      });

      const response = await POST(request);
      const data = await response.json();

      expect(response.status).toBe(200);
      expect(data.session.cwd).toBe("/home/user");
    });

    it("should create session with clientHostname", async () => {
      process.env.SSH_CONNECTION = "192.168.1.100 12345 192.168.1.1 22";

      const requestBody = {
        cwd: "/home/user",
        windowId: "test-window-id",
        clientHostname: "my-laptop",
      };
      const request = new NextRequest("http://localhost:6379/api/sessions", {
        method: "POST",
        body: JSON.stringify(requestBody),
      });

      const response = await POST(request);
      const data = await response.json();

      expect(response.status).toBe(200);
      expect(data.session.hostname).toBe("my-laptop");
      expect(data.session.sessionType).toBe("ssh");

      delete process.env.SSH_CONNECTION;
    });

    it("should store created session in manager", async () => {
      const requestBody = { cwd: "/home/user", windowId: "test-window-id" };
      const request = new NextRequest("http://localhost:6379/api/sessions", {
        method: "POST",
        body: JSON.stringify(requestBody),
      });

      const response = await POST(request);
      const data = await response.json();

      const retrieved = sessionManager.getSession(data.session.id);
      expect(retrieved).toBeDefined();
      expect(retrieved.cwd).toBe("/home/user");
    });

    it("should create session with empty messages array", async () => {
      const requestBody = { cwd: "/home/user", windowId: "test-window-id" };
      const request = new NextRequest("http://localhost:6379/api/sessions", {
        method: "POST",
        body: JSON.stringify(requestBody),
      });

      const response = await POST(request);
      const data = await response.json();

      expect(data.session.messages).toEqual([]);
    });

    it("should create session with default model", async () => {
      const requestBody = { cwd: "/home/user", windowId: "test-window-id" };
      const request = new NextRequest("http://localhost:6379/api/sessions", {
        method: "POST",
        body: JSON.stringify(requestBody),
      });

      const response = await POST(request);
      const data = await response.json();

      expect(data.session.model).toBe("claude-sonnet-4-5-20250929");
    });
  });
});
