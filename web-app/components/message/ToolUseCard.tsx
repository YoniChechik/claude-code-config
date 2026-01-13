import type { ContentBlock } from "@/lib/types";

// Tool color mapping (from cc_filter.jq)
const TOOL_COLORS = {
  Task: "bg-purple-100 text-purple-700 border-purple-300",
  Bash: "bg-yellow-100 text-yellow-800 border-yellow-300",
  Read: "bg-green-100 text-green-700 border-green-300",
  Write: "bg-blue-100 text-blue-700 border-blue-300",
  Edit: "bg-blue-100 text-blue-700 border-blue-300",
  Grep: "bg-cyan-100 text-cyan-700 border-cyan-300",
  Glob: "bg-cyan-100 text-cyan-700 border-cyan-300",
  TodoWrite: "bg-purple-100 text-purple-700 border-purple-300",
  default: "bg-gray-100 text-gray-700 border-gray-300",
};

interface ToolUseCardProps {
  tool: Extract<ContentBlock, { type: "tool_use" }>;
}

export default function ToolUseCard({ tool }: ToolUseCardProps) {
  const colorClass = TOOL_COLORS[tool.name as keyof typeof TOOL_COLORS] || TOOL_COLORS.default;

  return (
    <div className={`border-l-4 p-3 rounded my-2 ${colorClass}`}>
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
          <div className="text-gray-600">{tool.input.description}</div>
          <div className="mt-1">$ {tool.input.command}</div>
        </div>
      );

    case "TodoWrite":
      return (
        <div className="space-y-1">
          {(tool.input.todos || []).map((todo: any, idx: number) => (
            <div key={idx} className="flex items-center gap-2">
              <span>{getStatusEmoji(todo.status)}</span>
              <span className={todo.status === "completed" ? "line-through text-gray-500" : ""}>
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
        <div className="text-sm font-mono text-gray-600">
          {tool.input.file_path}
        </div>
      );

    case "Grep":
    case "Glob":
      return (
        <div className="text-sm font-mono text-gray-600">
          {tool.input.pattern}
        </div>
      );

    default:
      return (
        <pre className="text-xs text-gray-600 overflow-x-auto">
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
