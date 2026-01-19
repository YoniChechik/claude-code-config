import { useState } from "react";
import type { ContentBlock } from "@/lib/types";
import ToolUseCard from "./ToolUseCard";
import RainbowText from "../RainbowText";
import UnknownContentBlock from "./UnknownContentBlock";

interface ContentBlockRendererProps {
  block: ContentBlock;
  isNested?: boolean;
}

export default function ContentBlockRenderer({
  block,
  isNested: _isNested = false,
}: ContentBlockRendererProps) {
  // All 4 known content block types are handled below
  // Any unknown types will fall through to the UnknownContentBlock fallback
  switch (block.type) {
    case "text": {
      const trimmedText = block.text.trim();
      if (
        trimmedText === "Structured output provided successfully" ||
        trimmedText === "No response requested"
      ) {
        return null;
      }
      return <RainbowText text={block.text} />;
    }

    case "thinking":
      return (
        <div className="text-text-secondary italic bg-surface-tertiary px-md py-sm rounded-lg">
          💭 {block.thinking}
        </div>
      );

    case "tool_use":
      return <ToolUseCard tool={block} />;

    case "tool_result":
      return <_ToolResultBlock content={block.content} />;

    default: {
      const unknownBlock = block as ContentBlock & { type: string };
      console.warn("Unknown content block type:", unknownBlock.type, unknownBlock);
      return <UnknownContentBlock blockType={unknownBlock.type} blockData={unknownBlock} />;
    }
  }
}

function _ToolResultBlock({ content }: { content: string | ContentBlock[] }) {
  const [isExpanded, setIsExpanded] = useState(false);

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
          className="flex-shrink-0 w-2 bg-blue-600 hover:bg-blue-500 cursor-pointer transition-colors rounded-l"
          title={
            isExpanded ? "Collapse" : `Expand ${lines.length - 3} more lines`
          }
        />
      )}
      <div
        className={`text-gray-300 bg-gray-800 px-3 py-2 font-mono text-sm whitespace-pre-wrap flex-1 ${shouldCollapse ? "rounded-r" : "rounded"}`}
      >
        {displayContent}
      </div>
    </div>
  );
}
