import { promises as fs } from "fs";
import path from "path";
import os from "os";
import {
  dirToClaudePath,
  createSessionSymlink,
  resolveLinkPath,
  findRealSessionPath,
} from "../lib/symlink-manager";

describe("symlink-manager", () => {
  describe("dirToClaudePath", () => {
    it("should encode forward slashes to hyphens", () => {
      expect(dirToClaudePath("/home/ubuntu/.claude")).toBe(
        "-home-ubuntu--claude",
      );
    });

    it("should encode dots to hyphens", () => {
      expect(dirToClaudePath("/tmp/test.dots")).toBe("-tmp-test-dots");
    });

    it("should encode underscores to hyphens", () => {
      expect(dirToClaudePath("/tmp/test_underscore")).toBe(
        "-tmp-test-underscore",
      );
    });

    it("should encode spaces to hyphens", () => {
      expect(dirToClaudePath("/tmp/test with spaces")).toBe(
        "-tmp-test-with-spaces",
      );
    });

    it("should preserve existing hyphens", () => {
      expect(dirToClaudePath("/tmp/test-with-hyphens")).toBe(
        "-tmp-test-with-hyphens",
      );
    });

    it("should handle special characters", () => {
      expect(dirToClaudePath("/tmp/test@#$%^&*()")).toBe(
        "-tmp-test---------",
      );
    });

    it("should handle single directory", () => {
      expect(dirToClaudePath("/tmp")).toBe("-tmp");
    });

    it("should handle alphanumeric paths", () => {
      expect(dirToClaudePath("/home/user123/project456")).toBe(
        "-home-user123-project456",
      );
    });
  });

  describe("resolveLinkPath", () => {
    let tempDir: string;

    beforeEach(async () => {
      tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "test-symlink-"));
    });

    afterEach(async () => {
      await fs.rm(tempDir, { recursive: true, force: true });
    });

    it("should return real path for symlink", async () => {
      const realFile = path.join(tempDir, "real.txt");
      const symlinkFile = path.join(tempDir, "link.txt");

      await fs.writeFile(realFile, "test content");
      await fs.symlink(realFile, symlinkFile);

      const resolved = await resolveLinkPath(symlinkFile);
      expect(resolved).toBe(realFile);
    });

    it("should return original path for non-symlink", async () => {
      const realFile = path.join(tempDir, "real.txt");
      await fs.writeFile(realFile, "test content");

      const resolved = await resolveLinkPath(realFile);
      expect(resolved).toBe(realFile);
    });

    it("should return original path if file does not exist", async () => {
      const nonExistentFile = path.join(tempDir, "nonexistent.txt");

      const resolved = await resolveLinkPath(nonExistentFile);
      expect(resolved).toBe(nonExistentFile);
    });
  });

  describe("createSessionSymlink", () => {
    let tempDir: string;
    let sourceDir: string;
    let targetDir: string;

    beforeEach(async () => {
      tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "test-sessions-"));
      sourceDir = path.join(tempDir, "source");
      targetDir = path.join(tempDir, "target");

      // Set HOME to temp directory for testing
      process.env.HOME = tempDir;

      // Create projects structure
      const projectsDir = path.join(tempDir, ".claude", "projects");
      await fs.mkdir(projectsDir, { recursive: true });
    });

    afterEach(async () => {
      await fs.rm(tempDir, { recursive: true, force: true });
    });

    it("should create symlink from target to source session file", async () => {
      const sessionId = "test-session-123";

      // Create source directory and session file
      const sourceEncoded = dirToClaudePath(sourceDir);
      const sourcePath = path.join(
        tempDir,
        ".claude",
        "projects",
        sourceEncoded,
      );
      await fs.mkdir(sourcePath, { recursive: true });

      const sessionFile = path.join(sourcePath, `${sessionId}.jsonl`);
      await fs.writeFile(sessionFile, "test session data");

      // Create symlink
      await createSessionSymlink(sessionId, sourceDir, targetDir);

      // Verify symlink exists
      const targetEncoded = dirToClaudePath(targetDir);
      const targetPath = path.join(
        tempDir,
        ".claude",
        "projects",
        targetEncoded,
      );
      const targetFile = path.join(targetPath, `${sessionId}.jsonl`);

      const stats = await fs.lstat(targetFile);
      expect(stats.isSymbolicLink()).toBe(true);

      // Verify symlink points to correct file
      const realPath = await fs.realpath(targetFile);
      expect(realPath).toBe(sessionFile);
    });

    it("should not create symlink if session file does not exist", async () => {
      const sessionId = "nonexistent-session";

      // Create source directory but no session file
      const sourceEncoded = dirToClaudePath(sourceDir);
      const sourcePath = path.join(
        tempDir,
        ".claude",
        "projects",
        sourceEncoded,
      );
      await fs.mkdir(sourcePath, { recursive: true });

      // Attempt to create symlink (should not throw)
      await expect(
        createSessionSymlink(sessionId, sourceDir, targetDir),
      ).resolves.not.toThrow();

      // Verify symlink was not created
      const targetEncoded = dirToClaudePath(targetDir);
      const targetPath = path.join(
        tempDir,
        ".claude",
        "projects",
        targetEncoded,
      );
      const targetFile = path.join(targetPath, `${sessionId}.jsonl`);

      await expect(fs.access(targetFile)).rejects.toThrow();
    });

    it("should not create symlink if source and target are the same", async () => {
      const sessionId = "test-session-123";

      // Create source directory and session file
      const sourceEncoded = dirToClaudePath(sourceDir);
      const sourcePath = path.join(
        tempDir,
        ".claude",
        "projects",
        sourceEncoded,
      );
      await fs.mkdir(sourcePath, { recursive: true });

      const sessionFile = path.join(sourcePath, `${sessionId}.jsonl`);
      await fs.writeFile(sessionFile, "test session data");

      // Try to create symlink to itself
      await createSessionSymlink(sessionId, sourceDir, sourceDir);

      // Verify no symlink was created (file should still be regular file)
      const stats = await fs.lstat(sessionFile);
      expect(stats.isSymbolicLink()).toBe(false);
      expect(stats.isFile()).toBe(true);
    });

    it("should handle empty session ID gracefully", async () => {
      await expect(
        createSessionSymlink("", sourceDir, targetDir),
      ).resolves.not.toThrow();
    });
  });

  describe("findRealSessionPath", () => {
    let tempDir: string;
    let testDir: string;

    beforeEach(async () => {
      tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "test-find-"));
      testDir = path.join(tempDir, "myproject");

      process.env.HOME = tempDir;

      // Create projects structure
      const projectsDir = path.join(tempDir, ".claude", "projects");
      await fs.mkdir(projectsDir, { recursive: true });
    });

    afterEach(async () => {
      await fs.rm(tempDir, { recursive: true, force: true });
    });

    it("should find real session path", async () => {
      const sessionId = "test-session-456";
      const encoded = dirToClaudePath(testDir);
      const dirPath = path.join(tempDir, ".claude", "projects", encoded);
      await fs.mkdir(dirPath, { recursive: true });

      const sessionFile = path.join(dirPath, `${sessionId}.jsonl`);
      await fs.writeFile(sessionFile, "test data");

      const found = await findRealSessionPath(sessionId, testDir);
      expect(found).toBe(sessionFile);
    });

    it("should return null if session does not exist", async () => {
      const sessionId = "nonexistent-session";

      const found = await findRealSessionPath(sessionId, testDir);
      expect(found).toBeNull();
    });

    it("should resolve symlink to real path", async () => {
      const sessionId = "test-session-789";
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
      await fs.writeFile(realFile, "real session data");

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

      // Find from target directory should resolve to real file
      const found = await findRealSessionPath(sessionId, targetDir);
      expect(found).toBe(realFile);
    });
  });
});
