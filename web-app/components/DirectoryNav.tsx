"use client";

import { useState, useEffect } from "react";

interface DirectoryNavProps {
  cwd: string;
  onNavigate: (path: string) => void;
}

interface DirEntry {
  name: string;
  type: "file" | "directory";
  path: string;
}

/**
 * Basic directory navigation component
 */
export default function DirectoryNav({ cwd, onNavigate }: DirectoryNavProps) {
  const [entries, setEntries] = useState<DirEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    loadDirectory(cwd);
  }, [cwd]);

  const loadDirectory = async (path: string) => {
    setLoading(true);
    setError(null);

    try {
      // In a real implementation, this would call an API endpoint
      // For now, we'll just show placeholder data
      // TODO: Implement actual directory listing API
      setEntries([
        {
          name: "..",
          type: "directory",
          path: path.split("/").slice(0, -1).join("/") || "/",
        },
      ]);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load directory");
    } finally {
      setLoading(false);
    }
  };

  const handleClick = (entry: DirEntry) => {
    if (entry.type === "directory") {
      onNavigate(entry.path);
    }
  };

  return (
    <div className="flex flex-col h-full">
      <div className="px-4 py-3 border-b border-gray-300">
        <h3 className="font-semibold text-sm mb-1">Files</h3>
        <div className="text-xs text-gray-600 truncate" title={cwd}>
          {cwd}
        </div>
      </div>

      {loading && (
        <div className="px-4 py-2 text-sm text-gray-600">Loading...</div>
      )}
      {error && <div className="px-4 py-2 text-sm text-red-600">{error}</div>}

      <div className="flex-1 overflow-y-auto">
        {entries.map((entry, index) => (
          <div
            key={index}
            className="flex items-center gap-2 px-4 py-2 hover:bg-gray-200 cursor-pointer"
            onClick={() => handleClick(entry)}
          >
            <span className="text-lg">
              {entry.type === "directory" ? "📁" : "📄"}
            </span>
            <span className="text-sm truncate">{entry.name}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
