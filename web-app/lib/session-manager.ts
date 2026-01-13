import type { Session, Message } from "./types";
import { generateSessionId, normalizePath } from "./utils";
import { CDTracker } from "./cd-tracker";

/**
 * In-memory session manager
 * Stores active sessions with their message history and CD tracking state
 */
class SessionManager {
  private sessions = new Map<string, Session>();
  private cdTrackers = new Map<string, CDTracker>();

  /**
   * Create a new session
   */
  createSession(cwd: string): Session {
    const session: Session = {
      id: generateSessionId(),
      cwd: normalizePath(cwd),
      model: "claude-sonnet-4-5-20250929",
      lastDurationMs: 0,
      messages: [],
      createdAt: new Date(),
    };

    this.sessions.set(session.id, session);
    this.cdTrackers.set(session.id, new CDTracker());

    return session;
  }

  /**
   * Get session by ID
   */
  getSession(id: string): Session | undefined {
    return this.sessions.get(id);
  }

  /**
   * Get all sessions
   */
  getAllSessions(): Session[] {
    return Array.from(this.sessions.values());
  }

  /**
   * Delete session
   */
  deleteSession(id: string): boolean {
    this.cdTrackers.delete(id);
    return this.sessions.delete(id);
  }

  /**
   * Add message to session
   */
  addMessage(sessionId: string, message: Message): void {
    const session = this.sessions.get(sessionId);
    if (session) {
      session.messages.push(message);
    }
  }

  /**
   * Get CD tracker for session
   */
  getCDTracker(sessionId: string): CDTracker | undefined {
    return this.cdTrackers.get(sessionId);
  }

  /**
   * Update session metadata from CD tracker
   * Tracks previousCwd for symlink creation
   */
  updateSessionFromTracker(sessionId: string): void {
    const session = this.sessions.get(sessionId);
    const tracker = this.cdTrackers.get(sessionId);

    if (session && tracker) {
      const wantedCwd = tracker.getWantedCwd();
      if (wantedCwd) {
        session.previousCwd = session.cwd; // Save previous before updating
        session.cwd = wantedCwd;
      }
      session.model = tracker.getModel();
      session.lastDurationMs = tracker.getLastDurationMs();
    }
  }

  /**
   * Set Claude session ID for resuming conversations
   */
  setClaudeSessionId(sessionId: string, claudeSessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (session) {
      session.claudeSessionId = claudeSessionId;
    }
  }
}

// Singleton instance - preserved across hot reloads in development
const globalForSessionManager = globalThis as unknown as {
  sessionManager: SessionManager | undefined;
};

export const sessionManager =
  globalForSessionManager.sessionManager ?? new SessionManager();

if (process.env.NODE_ENV !== 'production') {
  globalForSessionManager.sessionManager = sessionManager;
}
