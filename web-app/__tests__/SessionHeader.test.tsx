import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import SessionHeader from "../components/SessionHeader";

// Mock fetch globally
global.fetch = jest.fn();

// Mock SessionPicker component
jest.mock("../components/SessionPicker", () => {
  return function MockSessionPicker({
    isOpen,
    onSelect,
    onCancel,
  }: {
    isOpen: boolean;
    onSelect: (sessionId: string, filePath: string, cwd: string) => void;
    onCancel: () => void;
  }) {
    if (!isOpen) return null;
    return (
      <div data-testid="session-picker-modal">
        <button
          data-testid="mock-select-session"
          onClick={() => onSelect("session-1", "/path/to/file", "/test/cwd")}
        >
          Select Session
        </button>
        <button data-testid="mock-cancel-session" onClick={onCancel}>
          Cancel
        </button>
      </div>
    );
  };
});

// Mock SSHHostPromptModal component
jest.mock("../components/SSHHostPromptModal", () => {
  return function MockSSHHostPromptModal({
    isOpen,
    clientIp,
    onSave,
    onCancel,
  }: {
    isOpen: boolean;
    clientIp: string;
    onSave: (hostname: string) => void;
    onCancel: () => void;
  }) {
    if (!isOpen) return null;
    return (
      <div data-testid="ssh-host-modal">
        <div data-testid="ssh-client-ip">{clientIp}</div>
        <input
          data-testid="ssh-hostname-input"
          placeholder="Enter hostname"
          onChange={(e) => {}}
        />
        <button
          data-testid="ssh-save-button"
          onClick={() => onSave("test-hostname")}
        >
          Save
        </button>
        <button data-testid="ssh-cancel-button" onClick={onCancel}>
          Cancel
        </button>
      </div>
    );
  };
});

describe("SessionHeader", () => {
  const defaultProps = {
    cwd: "/home/user/project",
    model: "claude-3-opus-20240229",
    lastDurationMs: 1500,
  };

  beforeEach(() => {
    jest.clearAllMocks();
    (global.fetch as jest.Mock).mockResolvedValue({
      json: async () => ({ usage: { percentUsed: 50, resetTime: "2026-01-15T18:00:00Z" } }),
    });
  });

  describe("Resume Button", () => {
    it("should not render resume button when onResumeSession is not provided", () => {
      render(<SessionHeader {...defaultProps} />);
      const resumeButton = screen.queryByTitle("Resume a previous session");
      expect(resumeButton).not.toBeInTheDocument();
    });

    it("should render resume button when onResumeSession is provided", () => {
      const onResumeSession = jest.fn();
      render(<SessionHeader {...defaultProps} onResumeSession={onResumeSession} />);
      const resumeButton = screen.getByTitle("Resume a previous session");
      expect(resumeButton).toBeInTheDocument();
      expect(resumeButton).toHaveTextContent("📂");
    });

    it("should open SessionPicker modal when resume button is clicked", () => {
      const onResumeSession = jest.fn();
      render(<SessionHeader {...defaultProps} onResumeSession={onResumeSession} />);

      const resumeButton = screen.getByTitle("Resume a previous session");
      fireEvent.click(resumeButton);

      const modal = screen.getByTestId("session-picker-modal");
      expect(modal).toBeInTheDocument();
    });

    it("should close modal when cancel is clicked", () => {
      const onResumeSession = jest.fn();
      render(<SessionHeader {...defaultProps} onResumeSession={onResumeSession} />);

      // Open modal
      const resumeButton = screen.getByTitle("Resume a previous session");
      fireEvent.click(resumeButton);
      expect(screen.getByTestId("session-picker-modal")).toBeInTheDocument();

      // Cancel
      const cancelButton = screen.getByTestId("mock-cancel-session");
      fireEvent.click(cancelButton);

      expect(screen.queryByTestId("session-picker-modal")).not.toBeInTheDocument();
    });

    it("should call onResumeSession with correct params when session is selected", () => {
      const onResumeSession = jest.fn();
      render(<SessionHeader {...defaultProps} onResumeSession={onResumeSession} />);

      // Open modal
      const resumeButton = screen.getByTitle("Resume a previous session");
      fireEvent.click(resumeButton);

      // Select session
      const selectButton = screen.getByTestId("mock-select-session");
      fireEvent.click(selectButton);

      expect(onResumeSession).toHaveBeenCalledWith(
        "session-1",
        "/path/to/file",
        "/test/cwd"
      );
    });

    it("should close modal after session is selected", () => {
      const onResumeSession = jest.fn();
      render(<SessionHeader {...defaultProps} onResumeSession={onResumeSession} />);

      // Open modal
      const resumeButton = screen.getByTitle("Resume a previous session");
      fireEvent.click(resumeButton);
      expect(screen.getByTestId("session-picker-modal")).toBeInTheDocument();

      // Select session
      const selectButton = screen.getByTestId("mock-select-session");
      fireEvent.click(selectButton);

      expect(screen.queryByTestId("session-picker-modal")).not.toBeInTheDocument();
    });
  });

  describe("Audio Toggle Button", () => {
    it("should render audio toggle button when onToggleAudioNotifications is provided", () => {
      const onToggle = jest.fn();
      render(
        <SessionHeader
          {...defaultProps}
          onToggleAudioNotifications={onToggle}
          audioNotificationsEnabled={true}
        />
      );

      const audioButton = screen.getByTitle("Disable audio notifications");
      expect(audioButton).toBeInTheDocument();
      expect(audioButton).toHaveTextContent("🔊");
    });

    it("should show muted icon when audio is disabled", () => {
      const onToggle = jest.fn();
      render(
        <SessionHeader
          {...defaultProps}
          onToggleAudioNotifications={onToggle}
          audioNotificationsEnabled={false}
        />
      );

      const audioButton = screen.getByTitle("Enable audio notifications");
      expect(audioButton).toHaveTextContent("🔇");
    });

    it("should call onToggleAudioNotifications when clicked", () => {
      const onToggle = jest.fn();
      render(
        <SessionHeader
          {...defaultProps}
          onToggleAudioNotifications={onToggle}
          audioNotificationsEnabled={true}
        />
      );

      const audioButton = screen.getByTitle("Disable audio notifications");
      fireEvent.click(audioButton);

      expect(onToggle).toHaveBeenCalledTimes(1);
    });
  });

  describe("Button Layout", () => {
    it("should render resume button next to audio button", () => {
      const onResumeSession = jest.fn();
      const onToggle = jest.fn();

      render(
        <SessionHeader
          {...defaultProps}
          onResumeSession={onResumeSession}
          onToggleAudioNotifications={onToggle}
          audioNotificationsEnabled={true}
        />
      );

      const resumeButton = screen.getByTitle("Resume a previous session");
      const audioButton = screen.getByTitle("Disable audio notifications");

      expect(resumeButton).toBeInTheDocument();
      expect(audioButton).toBeInTheDocument();
    });

    it("should render all buttons when all props are provided", () => {
      const onResumeSession = jest.fn();
      const onToggle = jest.fn();
      const onClose = jest.fn();

      render(
        <SessionHeader
          {...defaultProps}
          onResumeSession={onResumeSession}
          onToggleAudioNotifications={onToggle}
          audioNotificationsEnabled={true}
          onClose={onClose}
        />
      );

      expect(screen.getByTitle("Resume a previous session")).toBeInTheDocument();
      expect(screen.getByTitle("Disable audio notifications")).toBeInTheDocument();
      expect(screen.getByTitle("Close session")).toBeInTheDocument();
    });
  });

  describe("Basic Rendering", () => {
    it("should render current working directory", () => {
      render(<SessionHeader {...defaultProps} />);
      expect(screen.getByText("/home/user/project")).toBeInTheDocument();
    });

    it("should render duration and model", () => {
      render(<SessionHeader {...defaultProps} />);
      expect(screen.getByText("1.5s")).toBeInTheDocument();
      expect(screen.getByText("claude-3-opus-20240229")).toBeInTheDocument();
    });

    it("should render token usage when provided", () => {
      const tokenUsage = { used: 50000, total: 100000, remaining: 50000 };
      render(<SessionHeader {...defaultProps} tokenUsage={tokenUsage} />);

      expect(screen.getByText(/50,000/)).toBeInTheDocument();
      expect(screen.getByText(/100,000/)).toBeInTheDocument();
    });
  });

  describe("SSH Hostname Mapping", () => {
    beforeEach(() => {
      // Mock window.open
      global.open = jest.fn();
    });

    it("should open VSCode directly for non-SSH sessions", async () => {
      render(<SessionHeader {...defaultProps} sessionType="local" />);

      const cwdButton = screen.getByText("/home/user/project");
      fireEvent.click(cwdButton);

      await waitFor(() => {
        expect(global.open).toHaveBeenCalledWith(
          "vscode://file/home/user/project?windowId=_blank",
          "_blank"
        );
      });
    });

    it("should show modal for SSH session without resolved hostname", async () => {
      (global.fetch as jest.Mock).mockImplementation((url) => {
        if (url.includes("/api/ssh-host-mapping")) {
          return Promise.resolve({
            ok: true,
            json: async () => ({ hostname: null }),
          });
        }
        return Promise.resolve({
          ok: true,
          json: async () => ({ usage: { percentUsed: 50, resetTime: "2026-01-15T18:00:00Z" } }),
        });
      });

      render(
        <SessionHeader
          {...defaultProps}
          sessionType="ssh"
          clientIp="150.136.38.69"
        />
      );

      const cwdButton = screen.getByText("/home/user/project");
      fireEvent.click(cwdButton);

      await waitFor(() => {
        expect(screen.getByTestId("ssh-host-modal")).toBeInTheDocument();
      });
    });

    it("should open VSCode with resolved hostname for SSH session", async () => {
      (global.fetch as jest.Mock).mockImplementation((url) => {
        if (url.includes("/api/ssh-host-mapping")) {
          return Promise.resolve({
            ok: true,
            json: async () => ({ hostname: "my-server" }),
          });
        }
        return Promise.resolve({
          ok: true,
          json: async () => ({ usage: { percentUsed: 50, resetTime: "2026-01-15T18:00:00Z" } }),
        });
      });

      render(
        <SessionHeader
          {...defaultProps}
          sessionType="ssh"
          clientIp="150.136.38.69"
        />
      );

      const cwdButton = screen.getByText("/home/user/project");
      fireEvent.click(cwdButton);

      await waitFor(() => {
        expect(global.open).toHaveBeenCalledWith(
          "vscode://vscode-remote/ssh-remote+my-server/home/user/project?windowId=_blank",
          "_blank"
        );
      });
    });

    it("should save hostname and open VSCode when user submits modal", async () => {
      (global.fetch as jest.Mock).mockImplementation((url, options) => {
        if (url.includes("/api/ssh-host-mapping") && options?.method === "POST") {
          return Promise.resolve({
            ok: true,
            json: async () => ({ success: true }),
          });
        }
        if (url.includes("/api/ssh-host-mapping")) {
          return Promise.resolve({
            ok: true,
            json: async () => ({ hostname: null }),
          });
        }
        return Promise.resolve({
          ok: true,
          json: async () => ({ usage: { percentUsed: 50, resetTime: "2026-01-15T18:00:00Z" } }),
        });
      });

      render(
        <SessionHeader
          {...defaultProps}
          sessionType="ssh"
          clientIp="150.136.38.69"
        />
      );

      const cwdButton = screen.getByText("/home/user/project");
      fireEvent.click(cwdButton);

      await waitFor(() => {
        expect(screen.getByTestId("ssh-host-modal")).toBeInTheDocument();
      });

      const saveButton = screen.getByTestId("ssh-save-button");
      fireEvent.click(saveButton);

      await waitFor(() => {
        expect(global.open).toHaveBeenCalledWith(
          "vscode://vscode-remote/ssh-remote+test-hostname/home/user/project?windowId=_blank",
          "_blank"
        );
      });
    });

    it("should close modal when cancel is clicked", async () => {
      (global.fetch as jest.Mock).mockImplementation((url) => {
        if (url.includes("/api/ssh-host-mapping")) {
          return Promise.resolve({
            ok: true,
            json: async () => ({ hostname: null }),
          });
        }
        return Promise.resolve({
          ok: true,
          json: async () => ({ usage: { percentUsed: 50, resetTime: "2026-01-15T18:00:00Z" } }),
        });
      });

      render(
        <SessionHeader
          {...defaultProps}
          sessionType="ssh"
          clientIp="150.136.38.69"
        />
      );

      const cwdButton = screen.getByText("/home/user/project");
      fireEvent.click(cwdButton);

      await waitFor(() => {
        expect(screen.getByTestId("ssh-host-modal")).toBeInTheDocument();
      });

      const cancelButton = screen.getByTestId("ssh-cancel-button");
      fireEvent.click(cancelButton);

      await waitFor(() => {
        expect(screen.queryByTestId("ssh-host-modal")).not.toBeInTheDocument();
      });
    });

    it("should show error alert when SSH session has no clientIp", async () => {
      global.alert = jest.fn();

      render(
        <SessionHeader
          {...defaultProps}
          sessionType="ssh"
        />
      );

      const cwdButton = screen.getByText("/home/user/project");
      fireEvent.click(cwdButton);

      await waitFor(() => {
        expect(global.alert).toHaveBeenCalledWith(
          "Cannot resolve SSH hostname: client IP not available"
        );
      });
    });

    it("should open VSCode directly if SSH session already has resolvedHostname", async () => {
      render(
        <SessionHeader
          {...defaultProps}
          sessionType="ssh"
          hostname="my-server"
          clientIp="150.136.38.69"
        />
      );

      const cwdButton = screen.getByText("/home/user/project");
      fireEvent.click(cwdButton);

      await waitFor(() => {
        expect(global.open).toHaveBeenCalledWith(
          "vscode://vscode-remote/ssh-remote+my-server/home/user/project?windowId=_blank",
          "_blank"
        );
      });

      // Fetch should not be called since hostname is already resolved
      expect(global.fetch).not.toHaveBeenCalledWith(
        expect.stringContaining("/api/ssh-host-mapping")
      );
    });
  });
});
