import { useState } from "react";
import type { ContentBlock } from "@/lib/types";

// Tool color mapping (from cc_filter.jq)
const TOOL_COLORS = {
  Task: "bg-tool-task-dark/40 text-tool-task-light border-tool-task",
  Bash: "bg-tool-bash-dark/40 text-tool-bash-light border-tool-bash",
  Read: "bg-tool-read-dark/40 text-tool-read-light border-tool-read",
  Write: "bg-tool-write-dark/40 text-tool-write-light border-tool-write",
  Edit: "bg-tool-write-dark/40 text-tool-write-light border-tool-write",
  Grep: "bg-tool-grep-dark/40 text-tool-grep-light border-tool-grep",
  Glob: "bg-tool-grep-dark/40 text-tool-grep-light border-tool-grep",
  Skill: "bg-tool-skill-dark/40 text-tool-skill-light border-tool-skill",
  default: "bg-surface-tertiary text-text-secondary border-border-default",
};

interface ToolUseCardProps {
  tool: Extract<ContentBlock, { type: "tool_use" }>;
}

export default function ToolUseCard({ tool }: ToolUseCardProps) {
  const [isExpanded, setIsExpanded] = useState(false);
  const colorClass =
    TOOL_COLORS[tool.name as keyof typeof TOOL_COLORS] || TOOL_COLORS.default;
  const isPending = !tool.result;

  return (
    <div className={`border-l-4 px-lg py-md rounded ${colorClass}`}>
      <div className="flex items-center gap-md mb-1">
        <span className="font-semibold">[{tool.name}]</span>
        {tool.timestamp && (
          <span className="text-xs opacity-70">
            {tool.timestamp.toLocaleTimeString("en-US", {
              hour12: false,
              hour: "2-digit",
              minute: "2-digit",
              second: "2-digit",
            })}
          </span>
        )}
        {isPending && (
          <span className="text-xs opacity-70 animate-pulse">⏳ Running...</span>
        )}
      </div>
      {renderToolDetails(tool)}

      {/* Tool result (appears when result arrives) */}
      {tool.result && (
        <div className="mt-2 animate-fade-in">
          {renderToolResult(tool.result, isExpanded, setIsExpanded, tool.name)}
        </div>
      )}
    </div>
  );
}

function renderToolDetails(tool: Extract<ContentBlock, { type: "tool_use" }>) {
  const input = tool.input as Record<string, unknown>;

  switch (tool.name) {
    case "Bash": {
      const description = input.description ? String(input.description) : null;
      const command = input.command ? String(input.command) : null;
      return (
        <div className="font-mono text-sm">
          {description && (
            <div className="text-text-secondary">{description}</div>
          )}
          {command && (
            <div className="mt-1">$ {command}</div>
          )}
        </div>
      );
    }

    case "Task": {
      const agentType = input.subagent_type ? String(input.subagent_type) : "(unnamed)";
      const desc = input.description ? String(input.description) : "";
      return (
        <div className="text-sm">
          <span className="font-medium">{agentType}</span>
          {desc && (
            <>
              :{" "}
              {desc}
            </>
          )}
        </div>
      );
    }

    case "Read":
    case "Write":
    case "Edit": {
      const description = input.description ? String(input.description) : null;
      const filePath = input.file_path ? String(input.file_path) : "";
      return (
        <div className="font-mono text-sm">
          {description && (
            <div className="text-text-secondary">{description}</div>
          )}
          {filePath && <div className="mt-1">{filePath}</div>}
        </div>
      );
    }

    case "Grep":
    case "Glob": {
      const description = input.description ? String(input.description) : null;
      const pattern = input.pattern ? String(input.pattern) : "";
      return (
        <div className="font-mono text-sm">
          {description && (
            <div className="text-text-secondary">{description}</div>
          )}
          {pattern && <div className="mt-1">{pattern}</div>}
        </div>
      );
    }

    case "Skill": {
      const description = input.description ? String(input.description) : null;
      const skillName = input.skill ? String(input.skill) : "unknown";
      const args = input.args ? String(input.args) : "";
      return (
        <div className="font-mono text-sm">
          {description && (
            <div className="text-text-secondary">{description}</div>
          )}
          <div className="mt-1">
            /{skillName}
            {args && ` ${args}`}
          </div>
        </div>
      );
    }

    default:
      return (
        <pre className="text-xs text-text-secondary overflow-x-auto">
          {JSON.stringify(input, null, 2)}
        </pre>
      );
  }
}

function renderToolResult(
  content: string | ContentBlock[],
  isExpanded: boolean,
  setIsExpanded: (expanded: boolean) => void,
  _toolName?: string
) {
  if (Array.isArray(content)) {
    return null;
  }

  const contentStr =
    typeof content === "string" ? content : JSON.stringify(content, null, 2);

  const trimmedContent = contentStr.trim();

  if (
    trimmedContent === "Structured output provided successfully" ||
    trimmedContent === "No response requested"
  ) {
    return null;
  }

  const lines = contentStr.split("\n");
  const shouldCollapse = lines.length > 3;
  const displayContent =
    shouldCollapse && !isExpanded ? lines.slice(0, 3).join("\n") : contentStr;

  return (
    <div className="flex">
      {shouldCollapse && (
        <button
          onClick={() => setIsExpanded(!isExpanded)}
          className="flex-shrink-0 w-2 bg-brand-primary hover:bg-brand-secondary cursor-pointer transition-colors rounded-l"
          title={
            isExpanded ? "Collapse" : `Expand ${lines.length - 3} more lines`
          }
        />
      )}
      <div
        className={`text-text-secondary bg-surface-tertiary px-md py-sm font-mono text-sm whitespace-pre-wrap flex-1 ${shouldCollapse ? "rounded-r" : "rounded"}`}
      >
        {displayContent}
      </div>
    </div>
  );
}
