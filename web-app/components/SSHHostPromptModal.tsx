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
        className="bg-surface-elevated rounded-lg shadow-xl max-w-2xl w-full mx-md p-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="text-xl font-semibold text-text-primary mb-md">
          SSH Hostname Configuration
        </h2>

        <div className="space-y-md text-text-secondary">
          <p>
            <span className="text-text-muted">Your client IP:</span>{" "}
            <span className="font-mono text-text-accent">{clientIp}</span>
          </p>

          <p>
            To open VSCode via SSH, we need your SSH host alias from{" "}
            <code className="bg-surface-tertiary px-xs py-0.5 rounded text-sm">
              ~/.ssh/config
            </code>
          </p>

          <div>
            <p className="font-semibold text-text-primary mb-sm">Steps:</p>
            <ol className="list-decimal list-inside space-y-1 text-sm">
              <li>
                Open{" "}
                <code className="bg-surface-tertiary px-xs py-0.5 rounded">
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
            <p className="text-sm text-text-muted mb-sm">Example SSH config:</p>
            <pre className="bg-surface-primary p-md rounded text-sm font-mono text-text-secondary overflow-x-auto">
              {`Host mixtiles
  HostName 192.168.1.50
  User ubuntu`}
            </pre>
          </div>

          <form onSubmit={handleSubmit}>
            <div className="mb-md">
              <label
                htmlFor="ssh-host"
                className="block text-sm font-medium text-text-secondary mb-sm"
              >
                SSH Host:
              </label>
              <input
                id="ssh-host"
                type="text"
                value={hostname}
                onChange={(e) => setHostname(e.target.value)}
                placeholder="e.g., mixtiles"
                className="w-full px-md py-sm bg-surface-tertiary border border-border-default rounded-md text-text-primary placeholder-text-muted focus:outline-none focus:ring-2 focus:ring-brand-primary"
                autoFocus
              />
            </div>

            <div className="flex justify-end gap-md">
              <button
                type="button"
                onClick={onCancel}
                className="px-md py-sm bg-surface-tertiary text-text-secondary rounded-md hover:bg-surface-elevated transition-colors"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={!hostname.trim()}
                className="px-md py-sm bg-brand-primary text-text-primary rounded-md hover:bg-brand-secondary disabled:bg-surface-tertiary disabled:text-text-muted disabled:cursor-not-allowed transition-colors"
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
