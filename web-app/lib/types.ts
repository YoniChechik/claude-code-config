// Session types
export interface Session {
  id: string;
  cwd: string;
  previousCwd?: string; // Track previous directory for symlink creation
  model: string;
  lastDurationMs: number;
  messages: Message[];
  createdAt: Date;
  claudeSessionId?: string;
}

// Message types
export interface Message {
  role: "user" | "assistant";
  content: string;
  timestamp: Date;
  type?: "text" | "thinking" | "tool" | "error";
  isAutoContinueMessage?: boolean; // Mark internal system messages
}

// Streaming event types (matches cc_filter.jq output)
export type StreamEvent =
  | { type: "TEXT"; text: string }
  | { type: "LINE"; text: string }
  | { type: "SUB"; text: string }
  | { type: "JSON"; data: StructuredOutput }
  | { type: "ERROR"; error: string };

// Structured output from StructuredOutput tool
export interface StructuredOutput {
  wanted_cwd?: string; // Changed from cwd - indicates desired directory
  response: string;
}

// API request/response types
export interface CreateSessionRequest {
  cwd: string;
}

export interface CreateSessionResponse {
  session: Session;
}

export interface SendCommandRequest {
  sessionId: string;
  prompt: string;
}

export interface SendCommandResponse {
  // Streaming response via Server-Sent Events
}

export interface GetModelsResponse {
  models: string[];
  default: string;
}

// Autosuggest types
export interface SlashCommand {
  name: string;
  source: "builtin" | "user" | "project";
}

export interface AutosuggestState {
  active: boolean;
  matches: SlashCommand[];
  selectedIndex: number;
}

// Directory navigation types
export interface DirectoryEntry {
  name: string;
  type: "file" | "directory";
  path: string;
}

// CD tracking state (ported from ccui.sh)
export interface CDTrackingState {
  wantedCwd: string | null; // Renamed from sessionCwd
  lastDurationMs: number;
  model: string;
}
