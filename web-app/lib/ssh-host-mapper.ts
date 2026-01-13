import { promises as fs } from "fs";
import { homedir } from "os";
import { join } from "path";

const MAPPINGS_FILE = join(homedir(), ".claude", "ssh-host-mappings.json");

/**
 * Read SSH host mappings from file
 */
async function readMappings(): Promise<Record<string, string>> {
  try {
    const content = await fs.readFile(MAPPINGS_FILE, "utf-8");
    return JSON.parse(content);
  } catch (error) {
    // File doesn't exist or invalid JSON - return empty object
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return {};
    }
    // Log parse errors but return empty object to avoid breaking
    console.error("Error reading SSH host mappings:", error);
    return {};
  }
}

/**
 * Write SSH host mappings to file
 */
async function writeMappings(mappings: Record<string, string>): Promise<void> {
  await fs.writeFile(MAPPINGS_FILE, JSON.stringify(mappings, null, 2), "utf-8");
}

/**
 * Get hostname for a client IP
 */
export async function getHostnameForIP(clientIp: string): Promise<string | null> {
  const mappings = await readMappings();
  return mappings[clientIp] ?? null;
}

/**
 * Save hostname for a client IP
 */
export async function setHostnameForIP(clientIp: string, hostname: string): Promise<void> {
  const mappings = await readMappings();
  mappings[clientIp] = hostname;
  await writeMappings(mappings);
}
