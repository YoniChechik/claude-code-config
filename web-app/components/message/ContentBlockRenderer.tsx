import { useState } from "react";
import type { ContentBlock } from "@/lib/types";
import ToolUseCard from "./ToolUseCard";

interface ContentBlockRendererProps {
  block: ContentBlock;
  isNested?: boolean;
}

function ToolResultBlock({ content }: { content: string | ContentBlock[] }) {
  const [isExpanded, setIsExpanded] = useState(false);

  // If content is an array, it's handled by agent grouping - don't display it here
  if (Array.isArray(content)) {
    return null;
  }

  // Convert content to string if it's not already
  const contentStr = typeof content === 'string' ? content : JSON.stringify(content, null, 2);

  // Filter out internal system messages
  const trimmedContent = contentStr.trim();
  if (trimmedContent === "Structured output provided successfully" ||
      trimmedContent === "No response requested") {
    return null;
  }

  const lines = contentStr.split('\n');
  const shouldCollapse = lines.length > 3;
  const displayContent = shouldCollapse && !isExpanded
    ? lines.slice(0, 3).join('\n')
    : contentStr;

  return (
    <div className="text-gray-300 bg-gray-800 px-3 py-2 rounded font-mono text-sm my-2 whitespace-pre-wrap">
      {displayContent}
      {shouldCollapse && (
        <div className="mt-2 pt-2 border-t border-gray-700">
          <button
            onClick={() => setIsExpanded(!isExpanded)}
            className="text-blue-400 hover:text-blue-300 text-xs font-semibold"
          >
            {isExpanded ? '▲ Show less' : `▼ Show ${lines.length - 3} more lines`}
          </button>
        </div>
      )}
    </div>
  );
}

export default function ContentBlockRenderer({ block, isNested = false }: ContentBlockRendererProps) {
  switch (block.type) {
    case "text":
      // Filter out internal system messages
      const trimmedText = block.text.trim();
      if (trimmedText === "Structured output provided successfully" ||
          trimmedText === "No response requested") {
        return null;
      }
      return <span>{block.text}</span>;

    case "thinking":
      return (
        <div className="text-gray-400 italic bg-gray-800 px-3 py-2 rounded-lg my-2">
          💭 {block.thinking}
        </div>
      );

    case "tool_use":
      return <ToolUseCard tool={block} />;

    case "tool_result":
      return <ToolResultBlock content={block.content} />;

    default:
      return null;
  }
}
