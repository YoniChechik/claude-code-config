"use client";

import { useState } from "react";

interface UnknownContentBlockProps {
  blockType: string;
  blockData: unknown;
}

/**
 * Fallback component for unknown content block types
 */
export default function UnknownContentBlock({
  blockType,
  blockData,
}: UnknownContentBlockProps) {
  const [isExpanded, setIsExpanded] = useState(false);

  return (
    <div className="bg-yellow-900 border-2 border-yellow-600 rounded-lg p-4 my-2">
      <div className="flex items-center gap-2 mb-2">
        <svg
          className="w-5 h-5 text-yellow-400"
          fill="currentColor"
          viewBox="0 0 20 20"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path
            fillRule="evenodd"
            d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
            clipRule="evenodd"
          />
        </svg>
        <span className="font-semibold text-yellow-200">
          Unknown block type: <code className="font-mono">{blockType}</code>
        </span>
      </div>
      <p className="text-sm text-yellow-300 mb-2">
        This content block type is not recognized. The raw data is shown below.
      </p>
      <button
        onClick={() => setIsExpanded(!isExpanded)}
        className="text-sm text-yellow-400 hover:text-yellow-300 underline mb-2"
      >
        {isExpanded ? "Hide" : "Show"} raw data
      </button>
      {isExpanded && (
        <pre className="bg-gray-900 text-gray-300 p-3 rounded overflow-x-auto text-xs font-mono">
          {JSON.stringify(blockData, null, 2)}
        </pre>
      )}
    </div>
  );
}
