import { promises as fs } from "fs";
import path from "path";
import os from "os";
import { getSlashCommands, findProjectRoot } from "../lib/autosuggest";

describe("autosuggest", () => {
  let tempDir: string;

  beforeEach(async () => {
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "test-autosuggest-"));
    process.env.HOME = tempDir;
  });

  afterEach(async () => {
    await fs.rm(tempDir, { recursive: true, force: true });
  });

  describe("getSlashCommands", () => {
    it("should return builtin commands when no custom commands exist", async () => {
      const commands = await getSlashCommands();

      expect(commands.length).toBeGreaterThan(0);
      expect(commands).toContainEqual({ name: "help", source: "builtin" });
      expect(commands).toContainEqual({ name: "clear", source: "builtin" });
      expect(commands).toContainEqual({ name: "status", source: "builtin" });
    });

    it("should include user commands from ~/.claude/commands/", async () => {
      const userCommandsDir = path.join(tempDir, ".claude", "commands");
      await fs.mkdir(userCommandsDir, { recursive: true });
      await fs.writeFile(path.join(userCommandsDir, "custom.md"), "# Custom");
      await fs.writeFile(path.join(userCommandsDir, "deploy.md"), "# Deploy");

      const commands = await getSlashCommands();

      expect(commands).toContainEqual({ name: "custom", source: "user" });
      expect(commands).toContainEqual({ name: "deploy", source: "user" });
    });

    it("should include user skills from ~/.claude/skills/", async () => {
      const userSkillsDir = path.join(tempDir, ".claude", "skills");
      await fs.mkdir(path.join(userSkillsDir, "analyze"), {
        recursive: true,
      });
      await fs.mkdir(path.join(userSkillsDir, "review"), { recursive: true });

      const commands = await getSlashCommands();

      expect(commands).toContainEqual({ name: "analyze", source: "user" });
      expect(commands).toContainEqual({ name: "review", source: "user" });
    });

    it("should include project commands when projectRoot is provided", async () => {
      const projectRoot = path.join(tempDir, "myproject");
      const projectCommandsDir = path.join(
        projectRoot,
        ".claude",
        "commands",
      );
      await fs.mkdir(projectCommandsDir, { recursive: true });
      await fs.writeFile(
        path.join(projectCommandsDir, "test.md"),
        "# Test",
      );

      const commands = await getSlashCommands(projectRoot);

      expect(commands).toContainEqual({ name: "test", source: "project" });
    });

    it("should include project skills when projectRoot is provided", async () => {
      const projectRoot = path.join(tempDir, "myproject");
      const projectSkillsDir = path.join(projectRoot, ".claude", "skills");
      await fs.mkdir(path.join(projectSkillsDir, "build"), {
        recursive: true,
      });

      const commands = await getSlashCommands(projectRoot);

      expect(commands).toContainEqual({ name: "build", source: "project" });
    });

    it("should prioritize user commands over builtin", async () => {
      const userCommandsDir = path.join(tempDir, ".claude", "commands");
      await fs.mkdir(userCommandsDir, { recursive: true });
      await fs.writeFile(path.join(userCommandsDir, "help.md"), "# Custom");

      const commands = await getSlashCommands();

      const helpCommand = commands.find((c) => c.name === "help");
      expect(helpCommand).toEqual({ name: "help", source: "user" });
    });

    it("should prioritize user commands over project commands", async () => {
      const userCommandsDir = path.join(tempDir, ".claude", "commands");
      await fs.mkdir(userCommandsDir, { recursive: true });
      await fs.writeFile(
        path.join(userCommandsDir, "deploy.md"),
        "# User deploy",
      );

      const projectRoot = path.join(tempDir, "project");
      const projectCommandsDir = path.join(
        projectRoot,
        ".claude",
        "commands",
      );
      await fs.mkdir(projectCommandsDir, { recursive: true });
      await fs.writeFile(
        path.join(projectCommandsDir, "deploy.md"),
        "# Project deploy",
      );

      const commands = await getSlashCommands(projectRoot);

      const deployCommand = commands.find((c) => c.name === "deploy");
      expect(deployCommand).toEqual({ name: "deploy", source: "user" });
    });

    it("should return sorted commands", async () => {
      const userCommandsDir = path.join(tempDir, ".claude", "commands");
      await fs.mkdir(userCommandsDir, { recursive: true });
      await fs.writeFile(path.join(userCommandsDir, "zebra.md"), "# Zebra");
      await fs.writeFile(path.join(userCommandsDir, "alpha.md"), "# Alpha");
      await fs.writeFile(path.join(userCommandsDir, "beta.md"), "# Beta");

      const commands = await getSlashCommands();

      const customCommands = commands.filter((c) => c.source === "user");
      const names = customCommands.map((c) => c.name);
      expect(names).toEqual(["alpha", "beta", "zebra"]);
    });

    it("should ignore non-markdown files in commands directory", async () => {
      const userCommandsDir = path.join(tempDir, ".claude", "commands");
      await fs.mkdir(userCommandsDir, { recursive: true });
      await fs.writeFile(path.join(userCommandsDir, "valid.md"), "# Valid");
      await fs.writeFile(path.join(userCommandsDir, "ignore.txt"), "Text");
      await fs.writeFile(
        path.join(userCommandsDir, "README"),
        "Documentation",
      );

      const commands = await getSlashCommands();

      const customCommands = commands.filter((c) => c.source === "user");
      expect(customCommands).toHaveLength(1);
      expect(customCommands[0].name).toBe("valid");
    });

    it("should handle empty directories gracefully", async () => {
      const userCommandsDir = path.join(tempDir, ".claude", "commands");
      await fs.mkdir(userCommandsDir, { recursive: true });

      const commands = await getSlashCommands();

      expect(commands.length).toBeGreaterThan(0);
      expect(commands.every((c) => c.source === "builtin")).toBe(true);
    });

    it("should not fail when directories do not exist", async () => {
      const commands = await getSlashCommands("/nonexistent/path");

      expect(commands.length).toBeGreaterThan(0);
      expect(commands.every((c) => c.source === "builtin")).toBe(true);
    });
  });

  describe("findProjectRoot", () => {
    it("should find project root with .git directory", async () => {
      const projectRoot = path.join(tempDir, "myproject");
      const gitDir = path.join(projectRoot, ".git");
      await fs.mkdir(gitDir, { recursive: true });

      const subDir = path.join(projectRoot, "src", "components");
      await fs.mkdir(subDir, { recursive: true });

      const found = await findProjectRoot(subDir);
      expect(found).toBe(projectRoot);
    });

    it("should find project root with .claude directory", async () => {
      const projectRoot = path.join(tempDir, "myproject");
      const claudeDir = path.join(projectRoot, ".claude");
      await fs.mkdir(claudeDir, { recursive: true });

      const subDir = path.join(projectRoot, "src", "lib");
      await fs.mkdir(subDir, { recursive: true });

      const found = await findProjectRoot(subDir);
      expect(found).toBe(projectRoot);
    });

    it("should prefer .git over .claude when both exist", async () => {
      const projectRoot = path.join(tempDir, "myproject");
      const gitDir = path.join(projectRoot, ".git");
      const claudeDir = path.join(projectRoot, ".claude");
      await fs.mkdir(gitDir, { recursive: true });
      await fs.mkdir(claudeDir, { recursive: true });

      const found = await findProjectRoot(projectRoot);
      expect(found).toBe(projectRoot);
    });

    it("should return null when no project root is found", async () => {
      const someDir = path.join(tempDir, "some", "nested", "dir");
      await fs.mkdir(someDir, { recursive: true });

      const found = await findProjectRoot(someDir);
      expect(found).toBeNull();
    });

    it("should stop at root directory", async () => {
      const found = await findProjectRoot("/tmp/nonexistent/deep/path");
      expect(found).toBeNull();
    });

    it("should handle starting from root directory", async () => {
      const found = await findProjectRoot("/");
      expect(found).toBeNull();
    });

    it("should find nearest project root in nested projects", async () => {
      // Outer project
      const outerRoot = path.join(tempDir, "outer");
      const outerGit = path.join(outerRoot, ".git");
      await fs.mkdir(outerGit, { recursive: true });

      // Inner project
      const innerRoot = path.join(outerRoot, "nested", "inner");
      const innerGit = path.join(innerRoot, ".git");
      await fs.mkdir(innerGit, { recursive: true });

      // Search from inside inner project
      const searchFrom = path.join(innerRoot, "src");
      await fs.mkdir(searchFrom, { recursive: true });

      const found = await findProjectRoot(searchFrom);
      expect(found).toBe(innerRoot);
    });
  });
});
