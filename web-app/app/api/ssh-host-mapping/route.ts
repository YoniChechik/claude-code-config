import { NextRequest, NextResponse } from "next/server";
import { getHostnameForIP, setHostnameForIP } from "@/lib/ssh-host-mapper";

// Public functions
export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);
  const clientIp = searchParams.get("clientIp");

  if (!clientIp) {
    return NextResponse.json(
      { error: "clientIp query parameter is required" },
      { status: 400 }
    );
  }

  // Basic IP validation
  if (!_isValidIP(clientIp)) {
    return NextResponse.json(
      { error: "Invalid IP address format" },
      { status: 400 }
    );
  }

  try {
    const hostname = await getHostnameForIP(clientIp);
    return NextResponse.json({ hostname });
  } catch (error) {
    console.error("Error fetching hostname mapping:", error);
    return NextResponse.json(
      { error: "Failed to fetch hostname mapping" },
      { status: 500 }
    );
  }
}

export async function POST(request: NextRequest) {
  let body: { clientIp?: string; hostname?: string };

  try {
    body = await request.json();
  } catch {
    return NextResponse.json(
      { error: "Invalid JSON body" },
      { status: 400 }
    );
  }

  const { clientIp, hostname } = body;

  if (!clientIp || !hostname) {
    return NextResponse.json(
      { error: "clientIp and hostname are required" },
      { status: 400 }
    );
  }

  // Basic IP validation
  if (!_isValidIP(clientIp)) {
    return NextResponse.json(
      { error: "Invalid IP address format" },
      { status: 400 }
    );
  }

  // Validate hostname
  const trimmedHostname = hostname.trim();
  if (!trimmedHostname) {
    return NextResponse.json(
      { error: "hostname cannot be empty" },
      { status: 400 }
    );
  }

  // Basic hostname validation (alphanumeric, dash, underscore, dot)
  if (!/^[a-zA-Z0-9\-_.]+$/.test(trimmedHostname)) {
    return NextResponse.json(
      { error: "hostname contains invalid characters" },
      { status: 400 }
    );
  }

  try {
    await setHostnameForIP(clientIp, trimmedHostname);
    return NextResponse.json({ success: true });
  } catch (error) {
    console.error("Error saving hostname mapping:", error);
    return NextResponse.json(
      { error: "Failed to save hostname mapping" },
      { status: 500 }
    );
  }
}

// Private functions
function __isValidIP(ip: string): boolean {
  const ipv4Pattern = /^(\d{1,3}\.){3}\d{1,3}$/;
  const ipv6Pattern = /^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$/;
  return ipv4Pattern.test(ip) || ipv6Pattern.test(ip);
}
