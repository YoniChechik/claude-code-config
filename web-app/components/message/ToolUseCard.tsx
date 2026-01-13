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
  const colorClass = TOOL_COLORS[tool.name as keyof typeof TOOL_COLORS] || TOOL_COLORS.default;

  return (
    <div className={`border-l-4 p-3 rounded ${colorClass}`}>
      <div className="font-semibold mb-1">[{tool.name}]</div>
      {renderToolDetails(tool)}
    </div>
  );
}

function renderToolDetails(tool: Extract<ContentBlock, { type: "tool_use" }>) {
  switch (tool.name) {
    case "Bash":
      return (
        <div className="font-mono text-sm">
          <div className="text-gray-400">{tool.input.description}</div>
          <div className="mt-1">$ {tool.input.command}</div>
        </div>
      );

    case "TodoWrite":
      return (
        <div className="space-y-1">
          {(tool.input.todos || []).map((todo: any, idx: number) => (
            <div key={idx} className="flex items-center gap-2">
              <span>{getStatusEmoji(todo.status)}</span>
              <span className={todo.status === "completed" ? "line-through text-gray-500" : "text-gray-300"}>
                {todo.content}
              </span>
            </div>
          ))}
        </div>
      );

    case "Task":
      return (
        <div className="text-sm">
          <span className="font-medium">{tool.input.subagent_type}</span>: {tool.input.description}
        </div>
      );

    case "Read":
    case "Write":
    case "Edit":
      return (
        <div className="text-sm font-mono text-gray-400">
          {tool.input.file_path}
        </div>
      );

    case "Grep":
    case "Glob":
      return (
        <div className="text-sm font-mono text-gray-400">
          {tool.input.pattern}
        </div>
      );

    default:
      return (
        <pre className="text-xs text-gray-400 overflow-x-auto">
          {JSON.stringify(tool.input, null, 2)}
        </pre>
      );
  }
}

function getStatusEmoji(status: string): string {
  switch (status) {
    case "pending": return "⏳";
    case "in_progress": return "🔄";
    case "completed": return "✅";
    default: return "📝";
  }
}
