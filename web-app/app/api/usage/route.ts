import { NextRequest } from "next/server";
import * as fs from "fs/promises";
import * as path from "path";
import { readdir } from "fs/promises";

interface UsageData {
  totalTokensUsed: number;
  totalBudget: number;
  remaining: number;
  percentUsed: number;
  resetTime: string; // ISO timestamp for 6 PM EST today/tomorrow
}

/**
 * GET /api/usage - Calculate account-wide token usage from local session files
 */
export async function GET(_request: NextRequest) {
  try {
    const projectsDir = path.join(process.env.HOME!, ".claude", "projects");

    // Get all project directories
    const projectDirs = await readdir(projectsDir, { withFileTypes: true });

    let totalTokensUsed = 0;
    const today = new Date().toISOString().split("T")[0]; // YYYY-MM-DD

    // Iterate through each project directory
    for (const dir of projectDirs) {
      if (!dir.isDirectory()) continue;

      const projectPath = path.join(projectsDir, dir.name);
      const files = await readdir(projectPath);

      // Process all .jsonl session files
      for (const file of files) {
        if (!file.endsWith(".jsonl")) continue;

        const filePath = path.join(projectPath, file);
        const content = await fs.readFile(filePath, "utf-8");
        const lines = content.trim().split("\n");

        for (const line of lines) {
          try {
            const event = JSON.parse(line);

            // Check if this is from today
            if (event.timestamp) {
              const eventDate = new Date(event.timestamp)
                .toISOString()
                .split("T")[0];
              if (eventDate !== today) continue;
            }

            // Look for user messages with system_reminder containing token usage
            if (event.type === "user" && event.message?.content) {
              for (const block of event.message.content) {
                if (block.type === "text" && block.text) {
                  const match = block.text.match(
                    /Token usage: (\d+)\/(\d+); (\d+) remaining/,
                  );
                  if (match) {
                    const used = parseInt(match[1]);
                    // Take the maximum usage seen (represents cumulative usage for that session)
                    if (used > totalTokensUsed) {
                      totalTokensUsed = used;
                    }
                  }
                }
              }
            }
          } catch {
            // Skip malformed lines
          }
        }
      }
    }

    // Calculate reset time (6 PM EST today or tomorrow)
    const now = new Date();
    const est = new Date(
      now.toLocaleString("en-US", { timeZone: "America/New_York" }),
    );
    const resetTime = new Date(est);
    resetTime.setHours(18, 0, 0, 0); // 6 PM EST

    if (est.getHours() >= 18) {
      // Already past 6 PM, next reset is tomorrow
      resetTime.setDate(resetTime.getDate() + 1);
    }

    // Assume 200k budget for Max5 plan (from credentials: rateLimitTier: default_claude_max_5x)
    const totalBudget = 200000;
    const remaining = totalBudget - totalTokensUsed;
    const percentUsed = (totalTokensUsed / totalBudget) * 100;

    const usageData: UsageData = {
      totalTokensUsed,
      totalBudget,
      remaining,
      percentUsed,
      resetTime: resetTime.toISOString(),
    };

    return Response.json({ usage: usageData });
  } catch (error) {
    console.error("Failed to calculate usage:", error);
    return Response.json(
      { error: error instanceof Error ? error.message : String(error) },
      { status: 500 },
    );
  }
}
