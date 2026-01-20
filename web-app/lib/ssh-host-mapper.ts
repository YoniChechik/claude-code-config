import { promises as fs } from "fs";
import { homedir } from "os";
import { join } from "path";

// Private constants
const _MAPPINGS_FILE = join(homedir(), ".ccweb-ssh-hosts.json");

// Public functions
export async function getHostnameForIP(clientIp: string): Promise<string | null> {
  const mappings = await _readMappings();
  return mappings[clientIp] || null;
}

export async function setHostnameForIP(clientIp: string, hostname: string): Promise<void> {
  const mappings = await _readMappings();
  mappings[clientIp] = hostname;
  await _writeMappings(mappings);
}

// Private functions
async function _readMappings(): Promise<Record<string, string>> {
  try {
    const content = await fs.readFile(_MAPPINGS_FILE, "utf-8");
    return JSON.parse(content);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return {};
    }
    console.error("Error reading SSH host mappings:", error);
    return {};
  }
}

async function _writeMappings(mappings: Record<string, string>): Promise<void> {
  await fs.writeFile(_MAPPINGS_FILE, JSON.stringify(mappings, null, 2), "utf-8");
}
