"use client";

import { useState } from "react";

interface ErrorModalProps {
  error: Error;
  errorInfo?: React.ErrorInfo | null;
  isOpen: boolean;
  onDismiss: () => void;
}

export default function ErrorModal({
  error,
  errorInfo,
  isOpen,
  onDismiss,
}: ErrorModalProps) {
  const [showStack, setShowStack] = useState(false);
  const [showComponentStack, setShowComponentStack] = useState(false);
  const [copied, setCopied] = useState(false);

  if (!isOpen) return null;

  const handleReload = () => {
    window.location.reload();
  };

  const handleCopyError = async () => {
    const errorText = `Error Name: ${error.name || "Error"}
Error Message: ${error.message || "An unknown error occurred"}

Stack Trace:
${error.stack || "No stack trace available"}

Component Stack:
${errorInfo?.componentStack || "No component stack available"}`;

    await navigator.clipboard.writeText(errorText);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div
      className="fixed inset-0 bg-black/70 flex items-center justify-center z-50"
      onClick={onDismiss}
    >
      <div
        className="bg-gray-800 rounded-lg shadow-xl max-w-2xl w-full mx-4 p-6 max-h-[90vh] overflow-y-auto"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="text-xl font-semibold text-red-400 mb-4">
          Application Error
        </h2>

        <div className="space-y-4">
          <div>
            <p className="text-white text-lg font-semibold mb-2">
              {error.message || "An unknown error occurred"}
            </p>
            <p className="text-gray-400 text-sm">
              {error.name || "Error"}
            </p>
          </div>

          {error.stack && (
            <div>
              <button
                onClick={() => setShowStack(!showStack)}
                className="text-sm text-blue-400 hover:text-blue-300 mb-2"
              >
                {showStack ? "▼" : "▶"} Stack Trace
              </button>
              {showStack && (
                <pre className="bg-gray-900 p-3 rounded text-xs font-mono text-gray-300 overflow-x-auto max-h-60 overflow-y-auto">
                  {error.stack}
                </pre>
              )}
            </div>
          )}

          {errorInfo?.componentStack && (
            <div>
              <button
                onClick={() => setShowComponentStack(!showComponentStack)}
                className="text-sm text-blue-400 hover:text-blue-300 mb-2"
              >
                {showComponentStack ? "▼" : "▶"} Component Stack
              </button>
              {showComponentStack && (
                <pre className="bg-gray-900 p-3 rounded text-xs font-mono text-gray-300 overflow-x-auto max-h-60 overflow-y-auto">
                  {errorInfo.componentStack}
                </pre>
              )}
            </div>
          )}

          <div className="flex justify-end gap-3 pt-4">
            <button
              type="button"
              onClick={handleCopyError}
              className="px-4 py-2 bg-gray-700 text-gray-300 rounded-md hover:bg-gray-600 transition-colors"
            >
              {copied ? "Copied!" : "Copy Error"}
            </button>
            <button
              type="button"
              onClick={onDismiss}
              className="px-4 py-2 bg-gray-700 text-gray-300 rounded-md hover:bg-gray-600 transition-colors"
            >
              Dismiss
            </button>
            <button
              type="button"
              onClick={handleReload}
              className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors"
            >
              Reload Page
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
