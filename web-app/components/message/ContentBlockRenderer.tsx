import type { ContentBlock } from "@/lib/types";
import ToolUseCard from "./ToolUseCard";

interface ContentBlockRendererProps {
  block: ContentBlock;
}

export default function ContentBlockRenderer({ block }: ContentBlockRendererProps) {
  switch (block.type) {
    case "text":
      return <span>{block.text}</span>;

    case "thinking":
      return (
        <div className="text-gray-500 italic bg-gray-50 px-3 py-2 rounded-lg my-2">
          💭 {block.thinking}
        </div>
      );

    case "tool_use":
      return <ToolUseCard tool={block} />;

    case "tool_result":
      return (
        <div className="text-gray-600 bg-gray-100 px-3 py-2 rounded font-mono text-sm my-2">
          {block.content}
        </div>
      );

    default:
      return null;
  }
}
