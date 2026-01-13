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
    <div className="flex">
      {shouldCollapse && (
        <button
          onClick={() => setIsExpanded(!isExpanded)}
          className="flex-shrink-0 w-2 bg-blue-600 hover:bg-blue-500 cursor-pointer transition-colors rounded-l"
          title={isExpanded ? 'Collapse' : `Expand ${lines.length - 3} more lines`}
        />
      )}
      <div className={`text-gray-300 bg-gray-800 px-3 py-2 font-mono text-sm whitespace-pre-wrap flex-1 ${shouldCollapse ? 'rounded-r' : 'rounded'}`}>
        {displayContent}
      </div>
    </div>
  );
}

export default function ContentBlockRenderer({ block, isNested: _isNested = false }: ContentBlockRendererProps) {
  switch (block.type) {
    case "text": {
      // Filter out internal system messages
      const trimmedText = block.text.trim();
      if (trimmedText === "Structured output provided successfully" ||
          trimmedText === "No response requested") {
        return null;
      }
      return <span>{block.text}</span>;
    }

    case "thinking":
      return (
        <div className="text-gray-400 italic bg-gray-800 px-3 py-2 rounded-lg">
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
