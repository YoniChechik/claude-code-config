import type { Session, Message } from "./types";
import { generateSessionId, normalizePath } from "./utils";
import { CDTracker } from "./cd-tracker";
import { execSync } from "child_process";

class SessionManager {
  private sessions = new Map<string, Session>();
  private cdTrackers = new Map<string, CDTracker>();

  createSession(cwd: string, clientHostname?: string): Session {
    const { sessionType, hostname, distroName, clientIp } =
      this._detectSessionType(clientHostname);

    const session: Session = {
      id: generateSessionId(),
      cwd: normalizePath(cwd),
      model: "claude-sonnet-4-5-20250929",
      lastDurationMs: 0,
      messages: [],
      createdAt: new Date(),
      sessionType,
      hostname,
      distroName,
      clientIp,
    };

    this.sessions.set(session.id, session);
    this.cdTrackers.set(session.id, new CDTracker());

    return session;
  }

  private _detectSessionType(clientHostname?: string): {
    sessionType: "ssh" | "wsl" | "local";
    hostname?: string;
    distroName?: string;
    clientIp?: string;
  } {
    if (process.env.SSH_CONNECTION) {
      const parts = process.env.SSH_CONNECTION.split(" ");
      const clientIp = parts[0];
      const hostname =
        clientHostname ||
        process.env.CCWEB_SSH_HOST ||
        execSync("hostname").toString().trim();
      return { sessionType: "ssh", hostname, clientIp };
    }

    if (process.env.WSL_DISTRO_NAME) {
      return {
        sessionType: "wsl",
        distroName: process.env.WSL_DISTRO_NAME,
      };
    }

    return { sessionType: "local" };
  }

  resumeSession(sessionId: string, cwd: string, messages: Message[]): Session {
    const { sessionType, hostname, distroName, clientIp } =
      this._detectSessionType();

    const session: Session = {
      id: sessionId,
      cwd: normalizePath(cwd),
      model: "claude-sonnet-4-5-20250929",
      lastDurationMs: 0,
      messages,
      createdAt: new Date(),
      isResumed: true,
      sessionType,
      hostname,
      distroName,
      clientIp,
    };

    this.sessions.set(session.id, session);
    this.cdTrackers.set(session.id, new CDTracker());

    return session;
  }

  getSession(id: string): Session {
    return this.sessions.get(id)!;
  }

  getAllSessions(): Session[] {
    return Array.from(this.sessions.values());
  }

  deleteSession(id: string): boolean {
    this.cdTrackers.delete(id);
    return this.sessions.delete(id);
  }

  clearMessages(id: string): void {
    const session = this.sessions.get(id)!;
    session.messages = [];
  }

  addMessage(sessionId: string, message: Message): void {
    const session = this.sessions.get(sessionId)!;
    session.messages.push(message);
  }

  getCDTracker(sessionId: string): CDTracker {
    return this.cdTrackers.get(sessionId)!;
  }

  updateSessionFromTracker(sessionId: string): void {
    const session = this.sessions.get(sessionId)!;
    const tracker = this.cdTrackers.get(sessionId)!;

    const wantedCwd = tracker.getWantedCwd();
    if (wantedCwd) {
      session.previousCwd = session.cwd;
      session.cwd = wantedCwd;
    }
    session.model = tracker.getModel();
    session.lastDurationMs = tracker.getLastDurationMs();
  }

  setClaudeSessionId(sessionId: string, claudeSessionId: string): void {
    const session = this.sessions.get(sessionId)!;
    session.claudeSessionId = claudeSessionId;
  }
}

const globalForSessionManager = globalThis as unknown as {
  sessionManager: SessionManager | undefined;
};

export const sessionManager =
  globalForSessionManager.sessionManager ?? new SessionManager();

if (process.env.NODE_ENV !== "production") {
  globalForSessionManager.sessionManager = sessionManager;
}
