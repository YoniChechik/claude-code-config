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
      <div className="px-md py-md border-b border-border-default">
        <h3 className="font-semibold text-sm mb-1">Files</h3>
        <div className="text-xs text-text-secondary truncate" title={cwd}>
          {cwd}
        </div>
      </div>

      {loading && (
        <div className="px-md py-sm text-sm text-text-secondary">Loading...</div>
      )}
      {error && <div className="px-md py-sm text-sm text-error">{error}</div>}

      <div className="flex-1 overflow-y-auto">
        {entries.map((entry, index) => (
          <div
            key={index}
            className="flex items-center gap-md px-md py-sm hover:bg-surface-elevated cursor-pointer"
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
