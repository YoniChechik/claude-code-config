import { render, screen, fireEvent, waitFor, act } from "@testing-library/react";
import SessionHeader from "../components/SessionHeader";

// Mock fetch globally
global.fetch = jest.fn();

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
      ok: true,
      json: async () => ({ usage: { percentUsed: 50, resetTime: "2026-01-15T18:00:00Z" } }),
    });
  });

  // Helper to render component and wait for async state updates
  const renderAndWait = async (props: any) => {
    const result = render(<SessionHeader {...props} />);
    // Wait for useEffect fetch to complete
    await waitFor(() => {
      expect(global.fetch).toHaveBeenCalled();
    });
    return result;
  };


  describe("Audio Toggle Button", () => {
    it("should render audio toggle button when onToggleAudioNotifications is provided", async () => {
      const onToggle = jest.fn();
      await renderAndWait({
        ...defaultProps,
        onToggleAudioNotifications: onToggle,
        audioNotificationsEnabled: true,
      });

      const audioButton = screen.getByTitle("Disable audio notifications");
      expect(audioButton).toBeInTheDocument();
      expect(audioButton).toHaveTextContent("🔊");
    });

    it("should show muted icon when audio is disabled", async () => {
      const onToggle = jest.fn();
      await renderAndWait({
        ...defaultProps,
        onToggleAudioNotifications: onToggle,
        audioNotificationsEnabled: false,
      });

      const audioButton = screen.getByTitle("Enable audio notifications");
      expect(audioButton).toHaveTextContent("🔕 Audio Off");
    });

    it("should call onToggleAudioNotifications when clicked", async () => {
      const onToggle = jest.fn();
      await renderAndWait({
        ...defaultProps,
        onToggleAudioNotifications: onToggle,
        audioNotificationsEnabled: true,
      });

      const audioButton = screen.getByTitle("Disable audio notifications");
      fireEvent.click(audioButton);

      expect(onToggle).toHaveBeenCalledTimes(1);
    });
  });

  describe("Button Layout", () => {
    it("should render audio button and close button when all props are provided", async () => {
      const onToggle = jest.fn();
      const onClose = jest.fn();

      await renderAndWait({
        ...defaultProps,
        onToggleAudioNotifications: onToggle,
        audioNotificationsEnabled: true,
        onClose,
      });

      expect(screen.getByTitle("Disable audio notifications")).toBeInTheDocument();
      expect(screen.getByTitle("Close session")).toBeInTheDocument();
    });
  });

  describe("Basic Rendering", () => {
    it("should render current working directory", async () => {
      await renderAndWait(defaultProps);
      expect(screen.getByText("/home/user/project")).toBeInTheDocument();
    });
  });

  describe("SSH Hostname Mapping", () => {
    beforeEach(() => {
      // Mock window.open
      global.open = jest.fn();
    });

    it("should open VSCode directly for non-SSH sessions", async () => {
      await renderAndWait({ ...defaultProps, sessionType: "local" });

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

      await renderAndWait({
        ...defaultProps,
        sessionType: "ssh",
        clientIp: "150.136.38.69",
      });

      const cwdButton = screen.getByText("/home/user/project");
      await act(async () => {
        fireEvent.click(cwdButton);
      });

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

      await renderAndWait({
        ...defaultProps,
        sessionType: "ssh",
        clientIp: "150.136.38.69",
      });

      const cwdButton = screen.getByText("/home/user/project");
      await act(async () => {
        fireEvent.click(cwdButton);
      });

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

      await renderAndWait({
        ...defaultProps,
        sessionType: "ssh",
        clientIp: "150.136.38.69",
      });

      const cwdButton = screen.getByText("/home/user/project");
      await act(async () => {
        fireEvent.click(cwdButton);
      });

      await waitFor(() => {
        expect(screen.getByTestId("ssh-host-modal")).toBeInTheDocument();
      });

      const saveButton = screen.getByTestId("ssh-save-button");
      await act(async () => {
        fireEvent.click(saveButton);
      });

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

      await renderAndWait({
        ...defaultProps,
        sessionType: "ssh",
        clientIp: "150.136.38.69",
      });

      const cwdButton = screen.getByText("/home/user/project");
      await act(async () => {
        fireEvent.click(cwdButton);
      });

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

      await renderAndWait({
        ...defaultProps,
        sessionType: "ssh",
      });

      const cwdButton = screen.getByText("/home/user/project");
      fireEvent.click(cwdButton);

      await waitFor(() => {
        expect(global.alert).toHaveBeenCalledWith(
          "Cannot resolve SSH hostname: client IP not available"
        );
      });
    });

    it.skip("should open VSCode directly if SSH session already has resolvedHostname", async () => {
      await renderAndWait({
        ...defaultProps,
        sessionType: "ssh",
        hostname: "my-server",
        clientIp: "150.136.38.69",
      });

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
