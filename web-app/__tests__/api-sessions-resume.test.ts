/**
 * @jest-environment node
 */
import { NextRequest } from "next/server";
import { POST } from "../app/api/sessions/resume/route";
import { sessionManager } from "../lib/session-manager";
import * as sessionStorage from "../lib/session-storage";

// Mock global Request for Next.js
global.Request = class MockRequest {} as typeof Request;

// Mock session-storage module
jest.mock("../lib/session-storage", () => ({
  validateSessionPath: jest.fn(),
  loadSessionMessages: jest.fn(),
}));

const mockValidateSessionPath = sessionStorage.validateSessionPath as jest.Mock;
const mockLoadSessionMessages = sessionStorage.loadSessionMessages as jest.Mock;

describe("API /api/sessions/resume", () => {
  beforeEach(() => {
    // Clear all sessions before each test
    const sessions = sessionManager.getAllSessions();
    sessions.forEach((s) => sessionManager.deleteSession(s.id));

    // Reset mocks
    jest.clearAllMocks();
  });

  describe("POST /api/sessions/resume", () => {
    it("should resume a new session successfully", async () => {
      const windowId = "test-window-id";
      const sessionId = "test-session-id";
      const filePath = "/path/to/session.jsonl";
      const cwd = "/home/user";
      const mockMessages = [
        {
          role: "user",
          content: [{ type: "text", text: "Hello" }],
          timestamp: new Date().toISOString(),
        },
      ];

      mockValidateSessionPath.mockResolvedValue(filePath);
      mockLoadSessionMessages.mockResolvedValue(mockMessages);

      const request = new NextRequest("http://localhost:6379/api/sessions/resume", {
        method: "POST",
        body: JSON.stringify({ sessionId, windowId, filePath, cwd }),
      });

      const response = await POST(request);
      const data = await response.json();

      expect(response.status).toBe(200);
      expect(data.session.id).toBe(sessionId);
      expect(data.session.windowId).toBe(windowId);
      expect(data.session.cwd).toBe(cwd);
      expect(data.session.isResumed).toBe(true);
      expect(sessionManager.getOwner(sessionId)).toBe(windowId);
    });

    it("should return 400 if required fields are missing", async () => {
      const request = new NextRequest("http://localhost:6379/api/sessions/resume", {
        method: "POST",
        body: JSON.stringify({ sessionId: "test-id" }),
      });

      const response = await POST(request);
      const data = await response.json();

      expect(response.status).toBe(400);
      expect(data.error).toContain("required");
    });

    it("should return 404 if session file not found", async () => {
      const windowId = "test-window-id";
      const sessionId = "test-session-id";
      const filePath = "/path/to/nonexistent.jsonl";
      const cwd = "/home/user";

      mockValidateSessionPath.mockResolvedValue(null);

      const request = new NextRequest("http://localhost:6379/api/sessions/resume", {
        method: "POST",
        body: JSON.stringify({ sessionId, windowId, filePath, cwd }),
      });

      const response = await POST(request);
      const data = await response.json();

      expect(response.status).toBe(404);
      expect(data.error).toContain("Session file not found");
    });

    it("should allow same windowId to resume session multiple times", async () => {
      const windowId = "test-window-id";
      const sessionId = "test-session-id";
      const filePath = "/path/to/session.jsonl";
      const cwd = "/home/user";
      const mockMessages = [];

      mockValidateSessionPath.mockResolvedValue(filePath);
      mockLoadSessionMessages.mockResolvedValue(mockMessages);

      // First resume
      const request1 = new NextRequest("http://localhost:6379/api/sessions/resume", {
        method: "POST",
        body: JSON.stringify({ sessionId, windowId, filePath, cwd }),
      });
      const response1 = await POST(request1);
      expect(response1.status).toBe(200);

      // Second resume with same windowId should succeed
      const request2 = new NextRequest("http://localhost:6379/api/sessions/resume", {
        method: "POST",
        body: JSON.stringify({ sessionId, windowId, filePath, cwd }),
      });
      const response2 = await POST(request2);
      expect(response2.status).toBe(200);
    });

    it("should return 403 when different windowId tries to resume owned session", async () => {
      const windowId1 = "window-1";
      const windowId2 = "window-2";
      const sessionId = "test-session-id";
      const filePath = "/path/to/session.jsonl";
      const cwd = "/home/user";
      const mockMessages = [];

      mockValidateSessionPath.mockResolvedValue(filePath);
      mockLoadSessionMessages.mockResolvedValue(mockMessages);

      // First resume with windowId1
      const request1 = new NextRequest("http://localhost:6379/api/sessions/resume", {
        method: "POST",
        body: JSON.stringify({ sessionId, windowId: windowId1, filePath, cwd }),
      });
      const response1 = await POST(request1);
      expect(response1.status).toBe(200);

      // Second resume with windowId2 should fail with 403
      const request2 = new NextRequest("http://localhost:6379/api/sessions/resume", {
        method: "POST",
        body: JSON.stringify({ sessionId, windowId: windowId2, filePath, cwd }),
      });
      const response2 = await POST(request2);
      const data2 = await response2.json();

      expect(response2.status).toBe(403);
      expect(data2.error).toBe("Session ownership validation failed");
    });

    it("should preserve ownership after resume", async () => {
      const windowId = "test-window-id";
      const sessionId = "test-session-id";
      const filePath = "/path/to/session.jsonl";
      const cwd = "/home/user";
      const mockMessages = [];

      mockValidateSessionPath.mockResolvedValue(filePath);
      mockLoadSessionMessages.mockResolvedValue(mockMessages);

      const request = new NextRequest("http://localhost:6379/api/sessions/resume", {
        method: "POST",
        body: JSON.stringify({ sessionId, windowId, filePath, cwd }),
      });

      await POST(request);

      expect(sessionManager.validateOwnership(sessionId, windowId)).toBe(true);
      expect(sessionManager.getOwner(sessionId)).toBe(windowId);
    });

    it("should handle load errors gracefully", async () => {
      const windowId = "test-window-id";
      const sessionId = "test-session-id";
      const filePath = "/path/to/session.jsonl";
      const cwd = "/home/user";

      mockValidateSessionPath.mockResolvedValue(filePath);
      mockLoadSessionMessages.mockRejectedValue(new Error("Failed to read file"));

      const request = new NextRequest("http://localhost:6379/api/sessions/resume", {
        method: "POST",
        body: JSON.stringify({ sessionId, windowId, filePath, cwd }),
      });

      const response = await POST(request);
      const data = await response.json();

      expect(response.status).toBe(500);
      expect(data.error).toBe("Failed to resume session");
      expect(data.details).toContain("Failed to read file");
    });
  });
});
