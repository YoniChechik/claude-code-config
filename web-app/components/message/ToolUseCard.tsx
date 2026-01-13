import type { ContentBlock } from "@/lib/types";

// Tool color mapping (from cc_filter.jq)
const TOOL_COLORS = {
  Task: "bg-purple-900/40 text-purple-300 border-purple-700",
  Bash: "bg-yellow-900/40 text-yellow-300 border-yellow-700",
  Read: "bg-green-900/40 text-green-300 border-green-700",
  Write: "bg-blue-900/40 text-blue-300 border-blue-700",
  Edit: "bg-blue-900/40 text-blue-300 border-blue-700",
  Grep: "bg-cyan-900/40 text-cyan-300 border-cyan-700",
  Glob: "bg-cyan-900/40 text-cyan-300 border-cyan-700",
  TodoWrite: "bg-purple-900/40 text-purple-300 border-purple-700",
  default: "bg-gray-800 text-gray-300 border-gray-700",
};

interface ToolUseCardProps {
  tool: Extract<ContentBlock, { type: "tool_use" }>;
}

export default function ToolUseCard({ tool }: ToolUseCardProps) {
  const colorClass =
    TOOL_COLORS[tool.name as keyof typeof TOOL_COLORS] || TOOL_COLORS.default;

  return (
    <div className={`border-l-4 p-3 pl-6 rounded ${colorClass}`}>
      <div className="flex items-center gap-2 mb-1">
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
      </div>
      {renderToolDetails(tool)}
    </div>
  );
}

function renderToolDetails(tool: Extract<ContentBlock, { type: "tool_use" }>) {
  const input = tool.input as Record<string, unknown>;

  switch (tool.name) {
    case "Bash":
      return (
        <div className="font-mono text-sm">
          <div className="text-gray-400">{String(input.description)}</div>
          <div className="mt-1">$ {String(input.command)}</div>
        </div>
      );

    case "TodoWrite": {
      interface TodoItem {
        status: string;
        content: string;
      }
      const todos = (input.todos as TodoItem[]) || [];
      return (
        <div className="space-y-1">
          {todos.map((todo: TodoItem, idx: number) => (
            <div key={idx} className="flex items-center gap-2">
              <span>{getStatusEmoji(todo.status)}</span>
              <span
                className={
                  todo.status === "completed"
                    ? "line-through text-gray-500"
                    : "text-gray-300"
                }
              >
                {todo.content}
              </span>
            </div>
          ))}
        </div>
      );
    }

    case "Task":
      return (
        <div className="text-sm">
          <span className="font-medium">{String(input.subagent_type)}</span>:{" "}
          {String(input.description)}
        </div>
      );

    case "Read":
    case "Write":
    case "Edit":
      return (
        <div className="text-sm font-mono text-gray-400">
          {String(input.file_path)}
        </div>
      );

    case "Grep":
    case "Glob":
      return (
        <div className="text-sm font-mono text-gray-400">
          {String(input.pattern)}
        </div>
      );

    default:
      return (
        <pre className="text-xs text-gray-400 overflow-x-auto">
          {JSON.stringify(input, null, 2)}
        </pre>
      );
  }
}

function getStatusEmoji(status: string): string {
  switch (status) {
    case "pending":
      return "⏳";
    case "in_progress":
      return "🔄";
    case "completed":
      return "✅";
    default:
      return "📝";
  }
}
