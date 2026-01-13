import type { SlashCommand } from "./types";
import { promises as fs } from "fs";
import path from "path";

/**
 * Server-side autosuggest utilities
 * These functions use Node.js modules and can only be used in server components
 */

// Built-in Claude commands (from autosuggest.sh line 358)
const BUILTIN_COMMANDS = [
  "bug",
  "clear",
  "compact",
  "config",
  "cost",
  "doctor",
  "help",
  "init",
  "login",
  "logout",
  "mcp",
  "memory",
  "model",
  "permissions",
  "resume",
  "review",
  "status",
  "terminal-setup",
  "vim",
];

/**
 * Get slash commands from filesystem
 * Ported from get_slash_commands function (lines 304-365)
 */
export async function getSlashCommands(projectRoot?: string): Promise<SlashCommand[]> {
  const commands: SlashCommand[] = [];
  const seen = new Set<string>();

  // 1. User commands from ~/.claude/commands/*.md (highest priority)
  const homeDir = process.env.HOME;
  if (homeDir) {
    const userCommandsDir = path.join(homeDir, ".claude", "commands");
    try {
      const files = await fs.readdir(userCommandsDir);
      for (const file of files) {
        if (file.endsWith(".md")) {
          const name = file.replace(/\.md$/, "");
          commands.push({ name, source: "user" });
          seen.add(name);
        }
      }
    } catch {
      // Directory doesn't exist, ignore
    }
  }

  // 2. User skills from ~/.claude/skills/*/
  if (homeDir) {
    const userSkillsDir = path.join(homeDir, ".claude", "skills");
    try {
      const dirs = await fs.readdir(userSkillsDir);
      for (const dir of dirs) {
        const skillPath = path.join(userSkillsDir, dir);
        const stat = await fs.stat(skillPath);
        if (stat.isDirectory() && !seen.has(dir)) {
          commands.push({ name: dir, source: "user" });
          seen.add(dir);
        }
      }
    } catch {
      // Directory doesn't exist, ignore
    }
  }

  // 3. Project commands from .claude/commands/*.md
  if (projectRoot) {
    const projectCommandsDir = path.join(projectRoot, ".claude", "commands");
    try {
      const files = await fs.readdir(projectCommandsDir);
      for (const file of files) {
        if (file.endsWith(".md")) {
          const name = file.replace(/\.md$/, "");
          if (!seen.has(name)) {
            commands.push({ name, source: "project" });
            seen.add(name);
          }
        }
      }
    } catch {
      // Directory doesn't exist, ignore
    }
  }

  // 4. Project skills from .claude/skills/*/
  if (projectRoot) {
    const projectSkillsDir = path.join(projectRoot, ".claude", "skills");
    try {
      const dirs = await fs.readdir(projectSkillsDir);
      for (const dir of dirs) {
        const skillPath = path.join(projectSkillsDir, dir);
        const stat = await fs.stat(skillPath);
        if (stat.isDirectory() && !seen.has(dir)) {
          commands.push({ name: dir, source: "project" });
          seen.add(dir);
        }
      }
    } catch {
      // Directory doesn't exist, ignore
    }
  }

  // 5. Built-in commands (lowest priority)
  for (const name of BUILTIN_COMMANDS) {
    if (!seen.has(name)) {
      commands.push({ name, source: "builtin" });
      seen.add(name);
    }
  }

  // Sort alphabetically
  commands.sort((a, b) => a.name.localeCompare(b.name));

  return commands;
}


/**
 * Find project root by looking for .git or .claude directories
 * Ported from find_project_root function (lines 367-372)
 */
export async function findProjectRoot(startDir: string): Promise<string | null> {
  let dir = startDir;

  while (dir !== "/") {
    try {
      const gitPath = path.join(dir, ".git");
      const claudePath = path.join(dir, ".claude");

      const [gitExists, claudeExists] = await Promise.all([
        fs
          .access(gitPath)
          .then(() => true)
          .catch(() => false),
        fs
          .access(claudePath)
          .then(() => true)
          .catch(() => false),
      ]);

      if (gitExists || claudeExists) {
        return dir;
      }

      dir = path.dirname(dir);
    } catch {
      break;
    }
  }

  return null;
}
