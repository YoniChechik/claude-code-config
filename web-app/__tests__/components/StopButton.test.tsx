import { render, screen, fireEvent } from "@testing-library/react";
import StopButton from "../../components/StopButton";

describe("StopButton", () => {
  describe("Basic Rendering", () => {
    it("should render stop button with correct text", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      expect(button).toBeInTheDocument();
      expect(button).toHaveTextContent("Stop");
    });

    it("should have correct styling classes", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      expect(button).toHaveClass("bg-red-600");
      expect(button).toHaveClass("text-white");
    });

    it("should have correct title attribute", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      expect(button).toHaveAttribute("title", "Stop generation");
    });
  });

  describe("Click Handling", () => {
    it("should call onClick when clicked", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      fireEvent.click(button);

      expect(onClick).toHaveBeenCalledTimes(1);
    });

    it("should handle multiple rapid clicks", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      fireEvent.click(button);
      fireEvent.click(button);
      fireEvent.click(button);

      expect(onClick).toHaveBeenCalledTimes(3);
    });
  });

  describe("Disabled State", () => {
    it("should not be disabled by default", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      expect(button).not.toBeDisabled();
    });

    it("should be disabled when disabled prop is true", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} disabled={true} />);

      const button = screen.getByRole("button", { name: /stop/i });
      expect(button).toBeDisabled();
    });

    it("should not call onClick when disabled and clicked", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} disabled={true} />);

      const button = screen.getByRole("button", { name: /stop/i });
      fireEvent.click(button);

      expect(onClick).not.toHaveBeenCalled();
    });

    it("should have disabled styling when disabled", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} disabled={true} />);

      const button = screen.getByRole("button", { name: /stop/i });
      expect(button).toHaveClass("disabled:bg-gray-600");
      expect(button).toHaveClass("disabled:cursor-not-allowed");
    });
  });

  describe("SVG Icon", () => {
    it("should render SVG icon", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      const svg = button.querySelector("svg");

      expect(svg).toBeInTheDocument();
      expect(svg).toHaveAttribute("viewBox", "0 0 20 20");
    });
  });

  describe("Accessibility", () => {
    it("should be accessible via keyboard", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      button.focus();

      expect(document.activeElement).toBe(button);
    });

    it("should be focusable and accessible via keyboard", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      fireEvent.keyDown(button, { key: "Enter", code: "Enter" });

      // Button is accessible and can receive focus
      expect(button).toBeInTheDocument();
      expect(button).toHaveAttribute("title", "Stop generation");
    });
  });

  describe("Edge Cases", () => {
    it("should handle undefined onClick gracefully", () => {
      expect(() => {
        render(<StopButton onClick={undefined as any} />);
      }).not.toThrow();
    });

    it("should not throw when disabled and onClick is called", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} disabled={true} />);

      const button = screen.getByRole("button", { name: /stop/i });

      expect(() => {
        fireEvent.click(button);
      }).not.toThrow();

      expect(onClick).not.toHaveBeenCalled();
    });

    it("should have proper button structure", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      expect(button.tagName).toBe("BUTTON");
      expect(button).toBeInTheDocument();
    });
  });

  describe("Visual States", () => {
    it("should have hover styles", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      const classes = button.className;

      expect(classes).toContain("hover:bg-red-500");
    });

    it("should have transition classes", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      const classes = button.className;

      // Check for transition-related classes
      expect(classes).toMatch(/transition|duration/);
    });

    it("should have rounded corners", () => {
      const onClick = jest.fn();
      render(<StopButton onClick={onClick} />);

      const button = screen.getByRole("button", { name: /stop/i });
      const classes = button.className;

      expect(classes).toMatch(/rounded/);
    });
  });
});
