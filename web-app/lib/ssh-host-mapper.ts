import { promises as fs } from "fs";
import { homedir } from "os";
import { join } from "path";

const MAPPINGS_FILE = join(homedir(), ".ccweb-ssh-hosts.json");

async function readMappings(): Promise<Record<string, string>> {
  try {
    const content = await fs.readFile(MAPPINGS_FILE, "utf-8");
    return JSON.parse(content);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return {};
    }
    console.error("Error reading SSH host mappings:", error);
    return {};
  }
}

async function writeMappings(mappings: Record<string, string>): Promise<void> {
  await fs.writeFile(MAPPINGS_FILE, JSON.stringify(mappings, null, 2), "utf-8");
}

export async function getHostnameForIP(clientIp: string): Promise<string | null> {
  const mappings = await readMappings();
  return mappings[clientIp] || null;
}

export async function setHostnameForIP(clientIp: string, hostname: string): Promise<void> {
  const mappings = await readMappings();
  mappings[clientIp] = hostname;
  await writeMappings(mappings);
}
