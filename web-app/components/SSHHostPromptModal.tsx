"use client";

import { useState, useEffect, FormEvent } from "react";

interface SSHHostPromptModalProps {
  isOpen: boolean;
  clientIp: string;
  onSave: (hostname: string) => void;
  onCancel: () => void;
}

export default function SSHHostPromptModal({
  isOpen,
  clientIp,
  onSave,
  onCancel,
}: SSHHostPromptModalProps) {
  const [hostname, setHostname] = useState("");

  // Reset hostname when modal opens
  useEffect(() => {
    if (isOpen) {
      setHostname("");
    }
  }, [isOpen]);

  if (!isOpen) return null;

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    const trimmed = hostname.trim();
    if (trimmed) {
      onSave(trimmed);
    }
  };

  return (
    <div
      className="fixed inset-0 bg-black/70 flex items-center justify-center z-50"
      onClick={onCancel}
    >
      <div
        className="bg-gray-800 rounded-lg shadow-xl max-w-2xl w-full mx-4 p-6"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="text-xl font-semibold text-white mb-4">
          SSH Hostname Configuration
        </h2>

        <div className="space-y-4 text-gray-300">
          <p>
            <span className="text-gray-400">Your client IP:</span>{" "}
            <span className="font-mono text-blue-400">{clientIp}</span>
          </p>

          <p>
            To open VSCode via SSH, we need your SSH host alias from{" "}
            <code className="bg-gray-700 px-1 py-0.5 rounded text-sm">
              ~/.ssh/config
            </code>
          </p>

          <div>
            <p className="font-semibold text-white mb-2">Steps:</p>
            <ol className="list-decimal list-inside space-y-1 text-sm">
              <li>
                Open{" "}
                <code className="bg-gray-700 px-1 py-0.5 rounded">
                  ~/.ssh/config
                </code>{" "}
                on your local machine (not this server)
              </li>
              <li>
                Find the Host entry you used to connect (e.g., Host mixtiles)
              </li>
              <li>Enter that hostname below</li>
            </ol>
          </div>

          <div>
            <p className="text-sm text-gray-400 mb-2">Example SSH config:</p>
            <pre className="bg-gray-900 p-3 rounded text-sm font-mono text-gray-300 overflow-x-auto">
              {`Host mixtiles
  HostName 192.168.1.50
  User ubuntu`}
            </pre>
          </div>

          <form onSubmit={handleSubmit}>
            <div className="mb-4">
              <label
                htmlFor="ssh-host"
                className="block text-sm font-medium text-gray-300 mb-2"
              >
                SSH Host:
              </label>
              <input
                id="ssh-host"
                type="text"
                value={hostname}
                onChange={(e) => setHostname(e.target.value)}
                placeholder="e.g., mixtiles"
                className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-md text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500"
                autoFocus
              />
            </div>

            <div className="flex justify-end gap-3">
              <button
                type="button"
                onClick={onCancel}
                className="px-4 py-2 bg-gray-700 text-gray-300 rounded-md hover:bg-gray-600 transition-colors"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={!hostname.trim()}
                className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:bg-gray-600 disabled:text-gray-400 disabled:cursor-not-allowed transition-colors"
              >
                Save & Open
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
  );
}
