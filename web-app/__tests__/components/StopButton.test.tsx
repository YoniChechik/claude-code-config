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
});
