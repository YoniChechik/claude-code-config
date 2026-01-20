import { execSync } from "child_process";
import * as path from "path";

describe("Git State - Clean Working Directory", () => {
  const webAppRoot = path.resolve(__dirname, "..");
  const repoRoot = path.resolve(webAppRoot, "..");

  it("should have no unstaged changes in web-app directory", () => {
    const result = execSync("git status --porcelain web-app", {
      cwd: repoRoot,
      encoding: "utf8",
    });

    const unstagedChanges = result
      .split("\n")
      .filter((line) => line.trim())
      .filter((line) => !line.startsWith("??"))
      .filter((line) => !line.includes(".next"))
      .filter((line) => !line.includes("tsconfig.tsbuildinfo"));

    if (unstagedChanges.length > 0) {
      throw new Error(
        `Found unstaged changes that would block git pull:\n${unstagedChanges.join("\n")}\n\n` +
          `Run: git add . && git commit -m "..." or git restore .`
      );
    }
  });

  it("should be able to git pull without conflicts", () => {
    execSync("git fetch origin", { cwd: repoRoot });

    const behind = execSync(
      "git rev-list --count HEAD..origin/$(git branch --show-current)",
      { cwd: repoRoot, encoding: "utf8" }
    ).trim();

    if (parseInt(behind) > 0) {
      const statusOutput = execSync("git status --porcelain", {
        cwd: repoRoot,
        encoding: "utf8",
      });

      const hasUncommittedChanges = statusOutput
        .split("\n")
        .some((line) => line.trim() && !line.startsWith("??"));

      if (hasUncommittedChanges) {
        throw new Error(
          `Branch is behind origin but has uncommitted changes. Cannot pull.\n` +
            `Uncommitted changes would prevent rebase during git pull.`
        );
      }
    }
  });
});
