"use client";

import { useState } from "react";
import SessionPicker from "@/components/SessionPicker";

export default function TestSessionPickerPage() {
  const [isOpen, setIsOpen] = useState(false);
  const [selectedSession, setSelectedSession] = useState<string | null>(null);

  const handleSelect = (sessionId: string, filePath: string, cwd: string) => {
    setSelectedSession(`Session: ${sessionId}\nFile: ${filePath}\nCwd: ${cwd}`);
    setIsOpen(false);
  };

  const handleCancel = () => {
    setIsOpen(false);
  };

  return (
    <div className="min-h-screen bg-gray-900 text-white p-8">
      <div className="max-w-4xl mx-auto">
        <h1 className="text-3xl font-bold mb-8">
          Session Picker UI Test - NEW DESIGN
        </h1>

        <div className="bg-gray-800 rounded-lg p-6 mb-6">
          <h2 className="text-xl font-semibold mb-4">What's New?</h2>
          <ul className="space-y-2 text-sm">
            <li className="flex items-start gap-2">
              <span className="text-green-400">✓</span>
              <span>
                <strong>First message as title:</strong> Now shows what the
                session was about instead of just message count
              </span>
            </li>
            <li className="flex items-start gap-2">
              <span className="text-green-400">✓</span>
              <span>
                <strong>Better layout:</strong> Title prominent, metadata
                compact, last message as context
              </span>
            </li>
            <li className="flex items-start gap-2">
              <span className="text-green-400">✓</span>
              <span>
                <strong>Clean command text:</strong> Removes skill command
                wrappers from display
              </span>
            </li>
            <li className="flex items-start gap-2">
              <span className="text-green-400">✓</span>
              <span>
                <strong>One-line titles:</strong> First line only, truncated at
                80 chars
              </span>
            </li>
          </ul>
        </div>

        <div className="bg-gray-800 rounded-lg p-6 mb-6">
          <h2 className="text-xl font-semibold mb-4">Comparison</h2>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <h3 className="text-sm font-bold text-red-400 mb-2">Before:</h3>
              <div className="bg-gray-900 rounded p-3 text-xs">
                <div className="font-mono text-blue-400 mb-1">
                  📁 /home/ubuntu/.claude/_clones/fix-auth
                </div>
                <div className="text-gray-300 mb-1">192 messages</div>
                <div className="text-gray-400 italic">
                  "&lt;system-reminder&gt; The TodoWrite tool..."
                </div>
              </div>
            </div>

            <div>
              <h3 className="text-sm font-bold text-green-400 mb-2">After:</h3>
              <div className="bg-gray-900 rounded p-3 text-xs">
                <div className="font-mono text-blue-400 mb-1">
                  📁 /home/ubuntu/.claude/_clones/fix-auth
                </div>
                <div className="font-semibold text-gray-200 mb-1">
                  Fix authentication bug where JWT tokens expire too soon
                </div>
                <div className="text-gray-400 mb-1">192 messages • 2h ago</div>
                <div className="text-gray-500 italic text-[10px]">
                  Last: "The issue is in src/auth/tokens.ts:42..."
                </div>
              </div>
            </div>
          </div>
        </div>

        <div className="flex gap-4">
          <button
            onClick={() => setIsOpen(true)}
            className="px-6 py-3 bg-blue-600 hover:bg-blue-700 rounded-lg font-semibold transition-colors"
          >
            Open Session Picker (NEW DESIGN)
          </button>
        </div>

        {selectedSession && (
          <div className="mt-6 bg-green-900 border border-green-700 rounded-lg p-4">
            <h3 className="font-semibold mb-2">Selected Session:</h3>
            <pre className="text-sm whitespace-pre-wrap">{selectedSession}</pre>
          </div>
        )}

        <div className="mt-8 bg-gray-800 rounded-lg p-6">
          <h2 className="text-xl font-semibold mb-4">Testing Instructions</h2>
          <ol className="space-y-2 text-sm list-decimal list-inside">
            <li>Click "Open Session Picker" button above</li>
            <li>
              Observe the new layout with first message as prominent title
            </li>
            <li>Use arrow keys (↑↓) to navigate between sessions</li>
            <li>Notice how easy it is to identify what each session was about</li>
            <li>Compare to the "Before" example above</li>
            <li>Press Enter to select or Esc to cancel</li>
          </ol>
        </div>

        <div className="mt-6 bg-yellow-900 border border-yellow-700 rounded-lg p-4">
          <h3 className="font-semibold mb-2 text-yellow-200">
            📝 Development Note
          </h3>
          <p className="text-sm text-yellow-100">
            This test page uses the real SessionPicker component with actual
            session data from <code>~/.claude/projects</code>. The improvements
            are fully functional and ready for testing.
          </p>
        </div>
      </div>

      <SessionPicker
        isOpen={isOpen}
        onSelect={handleSelect}
        onCancel={handleCancel}
      />
    </div>
  );
}
