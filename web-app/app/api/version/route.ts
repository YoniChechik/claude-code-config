import { NextResponse } from "next/server";
import { execSync } from "child_process";

const BUILD_TIMESTAMP = new Date().toISOString();
const BUILD_COMMIT = process.env.BUILD_COMMIT || "unknown";

export async function GET() {
  let version = "unknown";
  try {
    version = execSync("claude -V", {
      encoding: "utf-8",
    }).trim().split(" ")[0];
  } catch (error) {
    console.error("Failed to get claude version:", error);
  }

  let currentCommit = "unknown";
  let isOutdated = false;

  try {
    currentCommit = execSync("git rev-parse HEAD", {
      encoding: "utf-8",
      cwd: process.cwd(),
    }).trim();

    isOutdated = BUILD_COMMIT !== "unknown" && BUILD_COMMIT !== currentCommit;
  } catch (error) {
    console.error("Failed to get git commit:", error);
  }

  return NextResponse.json({
    version,
    buildTimestamp: BUILD_TIMESTAMP,
    buildCommit: BUILD_COMMIT,
    currentCommit,
    isOutdated,
  });
}
