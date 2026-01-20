import { promises as fs } from "fs";
import path from "path";
import os from "os";
import {
  loadSessionMessages,
  findSessionsByDirectory,
  validateSessionPath,
} from "../lib/session-storage";
import { dirToClaudePath } from "../lib/symlink-manager";

describe("session-storage", () => {
  let tempDir: string;

  beforeEach(async () => {
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "test-session-"));
    process.env.HOME = tempDir;

    // Create projects structure
    const projectsDir = path.join(tempDir, ".claude", "projects");
    await fs.mkdir(projectsDir, { recursive: true });
  });

  afterEach(async () => {
    await fs.rm(tempDir, { recursive: true, force: true });
  });

  describe("loadSessionMessages", () => {
    it("should load messages from a real file", async () => {
      const sessionId = "test-session-001";
      const testDir = path.join(tempDir, "project1");
      const encoded = dirToClaudePath(testDir);
      const dirPath = path.join(tempDir, ".claude", "projects", encoded);
      await fs.mkdir(dirPath, { recursive: true });

      const sessionFile = path.join(dirPath, `${sessionId}.jsonl`);
      const sessionData = [
        {
          type: "user",
          message: { role: "user", content: "Hello" },
          cwd: testDir,
          sessionId,
          timestamp: new Date().toISOString(),
        },
        {
          type: "assistant",
          message: { role: "assistant", content: "Hi there" },
          timestamp: new Date().toISOString(),
        },
      ];

      await fs.writeFile(
        sessionFile,
        sessionData.map((line) => JSON.stringify(line)).join("\n"),
      );

      const messages = await loadSessionMessages(sessionFile);

      expect(messages).toHaveLength(2);
      expect(messages[0].role).toBe("user");
      expect(messages[0].content).toEqual([{ type: "text", text: "Hello" }]);
      expect(messages[1].role).toBe("assistant");
      expect(messages[1].content).toEqual([{ type: "text", text: "Hi there" }]);
    });

    it("should load messages from a symlink", async () => {
      const sessionId = "test-session-002";
      const sourceDir = path.join(tempDir, "source");
      const targetDir = path.join(tempDir, "target");

      // Create source session
      const sourceEncoded = dirToClaudePath(sourceDir);
      const sourcePath = path.join(
        tempDir,
        ".claude",
        "projects",
        sourceEncoded,
      );
      await fs.mkdir(sourcePath, { recursive: true });

      const realFile = path.join(sourcePath, `${sessionId}.jsonl`);
      const sessionData = [
        {
          type: "user",
          message: { role: "user", content: "Test message" },
          cwd: sourceDir,
          sessionId,
          timestamp: new Date().toISOString(),
        },
      ];

      await fs.writeFile(
        realFile,
        sessionData.map((line) => JSON.stringify(line)).join("\n"),
      );

      // Create symlink
      const targetEncoded = dirToClaudePath(targetDir);
      const targetPath = path.join(
        tempDir,
        ".claude",
        "projects",
        targetEncoded,
      );
      await fs.mkdir(targetPath, { recursive: true });

      const symlinkFile = path.join(targetPath, `${sessionId}.jsonl`);
      await fs.symlink(realFile, symlinkFile);

      // Load via symlink
      const messages = await loadSessionMessages(symlinkFile);

      expect(messages).toHaveLength(1);
      expect(messages[0].role).toBe("user");
      expect(messages[0].content).toEqual([
        { type: "text", text: "Test message" },
      ]);
    });

    it("should handle messages with array content", async () => {
      const sessionId = "test-session-003";
      const testDir = path.join(tempDir, "project2");
      const encoded = dirToClaudePath(testDir);
      const dirPath = path.join(tempDir, ".claude", "projects", encoded);
      await fs.mkdir(dirPath, { recursive: true });

      const sessionFile = path.join(dirPath, `${sessionId}.jsonl`);
      const sessionData = [
        {
          type: "user",
          message: {
            role: "user",
            content: [
              { type: "text", text: "First block" },
              { type: "text", text: "Second block" },
            ],
          },
          cwd: testDir,
          sessionId,
          timestamp: new Date().toISOString(),
        },
      ];

      await fs.writeFile(
        sessionFile,
        sessionData.map((line) => JSON.stringify(line)).join("\n"),
      );

      const messages = await loadSessionMessages(sessionFile);

      expect(messages).toHaveLength(1);
      expect(messages[0].content).toHaveLength(2);
      expect(messages[0].content[0]).toEqual({
        type: "text",
        text: "First block",
      });
    });
  });

  describe("findSessionsByDirectory", () => {
    it("should find sessions in a directory", async () => {
      const testDir = path.join(tempDir, "myproject");
      const encoded = dirToClaudePath(testDir);
      const dirPath = path.join(tempDir, ".claude", "projects", encoded);
      await fs.mkdir(dirPath, { recursive: true });

      // Create two session files
      const session1 = "session-001";
      const session2 = "session-002";

      const createSession = async (sessionId: string) => {
        const sessionFile = path.join(dirPath, `${sessionId}.jsonl`);
        const data = [
          {
            type: "user",
            message: { role: "user", content: "Test" },
            cwd: testDir,
            sessionId,
            timestamp: new Date().toISOString(),
          },
        ];
        await fs.writeFile(
          sessionFile,
          data.map((line) => JSON.stringify(line)).join("\n"),
        );
      };

      await createSession(session1);
      await createSession(session2);

      const sessions = await findSessionsByDirectory(testDir);

      expect(sessions).toHaveLength(2);
      expect(sessions.map((s) => s.id)).toContain(session1);
      expect(sessions.map((s) => s.id)).toContain(session2);
    });

    it("should return empty array for non-existent directory", async () => {
      const nonExistentDir = path.join(tempDir, "nonexistent");

      const sessions = await findSessionsByDirectory(nonExistentDir);

      expect(sessions).toEqual([]);
    });

    it("should mark symlinked sessions correctly", async () => {
      const sourceDir = path.join(tempDir, "source");
      const targetDir = path.join(tempDir, "target");

      // Create source session
      const sessionId = "session-symlink";
      const sourceEncoded = dirToClaudePath(sourceDir);
      const sourcePath = path.join(
        tempDir,
        ".claude",
        "projects",
        sourceEncoded,
      );
      await fs.mkdir(sourcePath, { recursive: true });

      const realFile = path.join(sourcePath, `${sessionId}.jsonl`);
      const data = [
        {
          type: "user",
          message: { role: "user", content: "Original" },
          cwd: sourceDir,
          sessionId,
          timestamp: new Date().toISOString(),
        },
      ];
      await fs.writeFile(
        realFile,
        data.map((line) => JSON.stringify(line)).join("\n"),
      );

      // Create symlink in target
      const targetEncoded = dirToClaudePath(targetDir);
      const targetPath = path.join(
        tempDir,
        ".claude",
        "projects",
        targetEncoded,
      );
      await fs.mkdir(targetPath, { recursive: true });

      const symlinkFile = path.join(targetPath, `${sessionId}.jsonl`);
      await fs.symlink(realFile, symlinkFile);

      // Find sessions from target directory
      const sessions = await findSessionsByDirectory(targetDir);

      expect(sessions).toHaveLength(1);
      expect(sessions[0].id).toBe(sessionId);
      expect(sessions[0].isSymlinked).toBe(true);
      expect(sessions[0].originalCwd).toBe(sourceDir);
    });

    it("should not mark non-symlinked sessions as symlinked", async () => {
      const testDir = path.join(tempDir, "regular");
      const encoded = dirToClaudePath(testDir);
      const dirPath = path.join(tempDir, ".claude", "projects", encoded);
      await fs.mkdir(dirPath, { recursive: true });

      const sessionId = "regular-session";
      const sessionFile = path.join(dirPath, `${sessionId}.jsonl`);
      const data = [
        {
          type: "user",
          message: { role: "user", content: "Regular" },
          cwd: testDir,
          sessionId,
          timestamp: new Date().toISOString(),
        },
      ];
      await fs.writeFile(
        sessionFile,
        data.map((line) => JSON.stringify(line)).join("\n"),
      );

      const sessions = await findSessionsByDirectory(testDir);

      expect(sessions).toHaveLength(1);
      expect(sessions[0].isSymlinked).toBeUndefined();
      expect(sessions[0].originalCwd).toBeUndefined();
    });
  });

  describe("validateSessionPath", () => {
    it("should return real path for valid file", async () => {
      const testDir = path.join(tempDir, "valid");
      const encoded = dirToClaudePath(testDir);
      const dirPath = path.join(tempDir, ".claude", "projects", encoded);
      await fs.mkdir(dirPath, { recursive: true });

      const sessionFile = path.join(dirPath, "session.jsonl");
      await fs.writeFile(sessionFile, "test data");

      const result = await validateSessionPath(sessionFile);
      expect(result).toBe(sessionFile);
    });

    it("should return null for non-existent file", async () => {
      const nonExistent = path.join(tempDir, "nonexistent.jsonl");

      const result = await validateSessionPath(nonExistent);
      expect(result).toBeNull();
    });

    it("should resolve symlink and return real path", async () => {
      const sourceDir = path.join(tempDir, "source");
      const targetDir = path.join(tempDir, "target");

      const sourceEncoded = dirToClaudePath(sourceDir);
      const sourcePath = path.join(
        tempDir,
        ".claude",
        "projects",
        sourceEncoded,
      );
      await fs.mkdir(sourcePath, { recursive: true });

      const realFile = path.join(sourcePath, "session.jsonl");
      await fs.writeFile(realFile, "real data");

      const targetEncoded = dirToClaudePath(targetDir);
      const targetPath = path.join(
        tempDir,
        ".claude",
        "projects",
        targetEncoded,
      );
      await fs.mkdir(targetPath, { recursive: true });

      const symlinkFile = path.join(targetPath, "session.jsonl");
      await fs.symlink(realFile, symlinkFile);

      const result = await validateSessionPath(symlinkFile);
      expect(result).toBe(realFile);
    });

    it("should return null for broken symlink", async () => {
      const testDir = path.join(tempDir, "broken");
      const encoded = dirToClaudePath(testDir);
      const dirPath = path.join(tempDir, ".claude", "projects", encoded);
      await fs.mkdir(dirPath, { recursive: true });

      const nonExistentTarget = path.join(dirPath, "nonexistent.jsonl");
      const brokenSymlink = path.join(dirPath, "broken-link.jsonl");

      // Create symlink pointing to non-existent file
      await fs.symlink(nonExistentTarget, brokenSymlink);

      const result = await validateSessionPath(brokenSymlink);
      expect(result).toBeNull();
    });
  });

  describe("getRecentSessions", () => {
    it("should return empty array when no sessions exist", async () => {
      const sessions = await import("../lib/session-storage");
      const recent = await sessions.getRecentSessions();
      expect(recent).toEqual([]);
    });

    it("should return sessions sorted by last activity", async () => {
      const testDir1 = path.join(tempDir, "project1");
      const testDir2 = path.join(tempDir, "project2");

      const encoded1 = dirToClaudePath(testDir1);
      const dirPath1 = path.join(tempDir, ".claude", "projects", encoded1);
      await fs.mkdir(dirPath1, { recursive: true });

      const encoded2 = dirToClaudePath(testDir2);
      const dirPath2 = path.join(tempDir, ".claude", "projects", encoded2);
      await fs.mkdir(dirPath2, { recursive: true });

      const now = new Date();
      const oldTime = new Date(now.getTime() - 3600000);

      const session1Data = [
        {
          type: "user",
          message: { role: "user", content: "Old session" },
          cwd: testDir1,
          sessionId: "session-old",
          timestamp: oldTime.toISOString(),
        },
      ];

      const session2Data = [
        {
          type: "user",
          message: { role: "user", content: "Recent session" },
          cwd: testDir2,
          sessionId: "session-recent",
          timestamp: now.toISOString(),
        },
      ];

      await fs.writeFile(
        path.join(dirPath1, "session-old.jsonl"),
        session1Data.map((line) => JSON.stringify(line)).join("\n"),
      );

      await fs.writeFile(
        path.join(dirPath2, "session-recent.jsonl"),
        session2Data.map((line) => JSON.stringify(line)).join("\n"),
      );

      const sessions = await import("../lib/session-storage");
      const recent = await sessions.getRecentSessions();

      expect(recent.length).toBeGreaterThan(0);
      expect(recent[0].id).toBe("session-recent");
      expect(recent[0].lastMessagePreview).toBe("Recent session");
    });

    it("should limit results to specified count", async () => {
      const testDir = path.join(tempDir, "projectMany");
      const encoded = dirToClaudePath(testDir);
      const dirPath = path.join(tempDir, ".claude", "projects", encoded);
      await fs.mkdir(dirPath, { recursive: true });

      for (let i = 0; i < 5; i++) {
        const sessionData = [
          {
            type: "user",
            message: { role: "user", content: `Session ${i}` },
            cwd: testDir,
            sessionId: `session-${i}`,
            timestamp: new Date().toISOString(),
          },
        ];
        await fs.writeFile(
          path.join(dirPath, `session-${i}.jsonl`),
          sessionData.map((line) => JSON.stringify(line)).join("\n"),
        );
      }

      const sessions = await import("../lib/session-storage");
      const recent = await sessions.getRecentSessions(2);

      expect(recent.length).toBeLessThanOrEqual(2);
    });

    it("should deduplicate sessions by ID", async () => {
      const sourceDir = path.join(tempDir, "source");
      const targetDir = path.join(tempDir, "target");

      const sourceEncoded = dirToClaudePath(sourceDir);
      const sourcePath = path.join(
        tempDir,
        ".claude",
        "projects",
        sourceEncoded,
      );
      await fs.mkdir(sourcePath, { recursive: true });

      const targetEncoded = dirToClaudePath(targetDir);
      const targetPath = path.join(
        tempDir,
        ".claude",
        "projects",
        targetEncoded,
      );
      await fs.mkdir(targetPath, { recursive: true });

      const sessionData = [
        {
          type: "user",
          message: { role: "user", content: "Shared session" },
          cwd: sourceDir,
          sessionId: "shared-session",
          timestamp: new Date().toISOString(),
        },
      ];

      const realFile = path.join(sourcePath, "shared-session.jsonl");
      await fs.writeFile(
        realFile,
        sessionData.map((line) => JSON.stringify(line)).join("\n"),
      );

      const symlinkFile = path.join(targetPath, "shared-session.jsonl");
      await fs.symlink(realFile, symlinkFile);

      const sessions = await import("../lib/session-storage");
      const recent = await sessions.getRecentSessions();

      const sharedSessions = recent.filter((s) => s.id === "shared-session");
      expect(sharedSessions.length).toBe(1);
    });
  });

  describe("firstMessagePreview", () => {
    it("should extract first user message as preview", async () => {
      const testDir = path.join(tempDir, "test-preview");
      const encoded = dirToClaudePath(testDir);
      const dirPath = path.join(tempDir, ".claude", "projects", encoded);
      await fs.mkdir(dirPath, { recursive: true });

      const sessionFile = path.join(dirPath, "test-session.jsonl");
      const sessionData = [
        {
          type: "user",
          message: { role: "user", content: "Fix the authentication bug" },
          cwd: testDir,
          sessionId: "test-session",
          timestamp: new Date().toISOString(),
        },
        {
          type: "assistant",
          message: { role: "assistant", content: "I'll help fix that" },
          timestamp: new Date().toISOString(),
        },
      ];

      await fs.writeFile(
        sessionFile,
        sessionData.map((line) => JSON.stringify(line)).join("\n"),
      );

      const sessions = await findSessionsByDirectory(testDir);

      expect(sessions).toHaveLength(1);
      expect(sessions[0].firstMessagePreview).toBe("Fix the authentication bug");
    });

    it("should clean up command wrapper tags from preview", async () => {
      const testDir = path.join(tempDir, "test-cleanup");
      const encoded = dirToClaudePath(testDir);
      const dirPath = path.join(tempDir, ".claude", "projects", encoded);
      await fs.mkdir(dirPath, { recursive: true });

      const sessionFile = path.join(dirPath, "test-session.jsonl");
      const sessionData = [
        {
          type: "user",
          message: {
            role: "user",
            content: "<command-name>/commit</command-name>\nCommit the changes",
          },
          cwd: testDir,
          sessionId: "test-session",
          timestamp: new Date().toISOString(),
        },
      ];

      await fs.writeFile(
        sessionFile,
        sessionData.map((line) => JSON.stringify(line)).join("\n"),
      );

      const sessions = await findSessionsByDirectory(testDir);

      expect(sessions).toHaveLength(1);
      expect(sessions[0].firstMessagePreview).toBe("Commit the changes");
      expect(sessions[0].firstMessagePreview).not.toContain("<command-name>");
    });

    it("should truncate long messages to 80 chars", async () => {
      const testDir = path.join(tempDir, "test-truncate");
      const encoded = dirToClaudePath(testDir);
      const dirPath = path.join(tempDir, ".claude", "projects", encoded);
      await fs.mkdir(dirPath, { recursive: true });

      const longMessage = "A".repeat(100);
      const sessionFile = path.join(dirPath, "test-session.jsonl");
      const sessionData = [
        {
          type: "user",
          message: { role: "user", content: longMessage },
          cwd: testDir,
          sessionId: "test-session",
          timestamp: new Date().toISOString(),
        },
      ];

      await fs.writeFile(
        sessionFile,
        sessionData.map((line) => JSON.stringify(line)).join("\n"),
      );

      const sessions = await findSessionsByDirectory(testDir);

      expect(sessions).toHaveLength(1);
      expect(sessions[0].firstMessagePreview.length).toBeLessThanOrEqual(83);
      expect(sessions[0].firstMessagePreview).toContain("...");
    });

    it("should use only first line of multiline message", async () => {
      const testDir = path.join(tempDir, "test-multiline");
      const encoded = dirToClaudePath(testDir);
      const dirPath = path.join(tempDir, ".claude", "projects", encoded);
      await fs.mkdir(dirPath, { recursive: true });

      const sessionFile = path.join(dirPath, "test-session.jsonl");
      const sessionData = [
        {
          type: "user",
          message: {
            role: "user",
            content: "First line\nSecond line\nThird line",
          },
          cwd: testDir,
          sessionId: "test-session",
          timestamp: new Date().toISOString(),
        },
      ];

      await fs.writeFile(
        sessionFile,
        sessionData.map((line) => JSON.stringify(line)).join("\n"),
      );

      const sessions = await findSessionsByDirectory(testDir);

      expect(sessions).toHaveLength(1);
      expect(sessions[0].firstMessagePreview).toBe("First line");
    });
  });

  describe("formatRelativeTime", () => {
    it("should format time less than 1 hour", async () => {
      const sessions = await import("../lib/session-storage");
      const now = new Date();
      const timestamp = new Date(now.getTime() - 30 * 60 * 1000).toISOString();

      const formatted = sessions.formatRelativeTime(timestamp);
      expect(formatted).toBe("< 1h ago");
    });

    it("should format time in hours", async () => {
      const sessions = await import("../lib/session-storage");
      const now = new Date();
      const timestamp = new Date(now.getTime() - 5 * 3600 * 1000).toISOString();

      const formatted = sessions.formatRelativeTime(timestamp);
      expect(formatted).toBe("5h ago");
    });

    it("should format time in days", async () => {
      const sessions = await import("../lib/session-storage");
      const now = new Date();
      const timestamp = new Date(now.getTime() - 3 * 24 * 3600 * 1000).toISOString();

      const formatted = sessions.formatRelativeTime(timestamp);
      expect(formatted).toBe("3d ago");
    });

    it("should format time in weeks", async () => {
      const sessions = await import("../lib/session-storage");
      const now = new Date();
      const timestamp = new Date(now.getTime() - 14 * 24 * 3600 * 1000).toISOString();

      const formatted = sessions.formatRelativeTime(timestamp);
      expect(formatted).toBe("2w ago");
    });
  });
});
