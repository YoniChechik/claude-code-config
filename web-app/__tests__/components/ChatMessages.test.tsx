import { render, screen } from "@testing-library/react";
import ChatMessages from "../../components/ChatMessages";
import { createMockMessage, createTextBlock } from "../utils/mockData";

describe("ChatMessages - Progress Indicator", () => {
  describe("Streaming Animation", () => {
    it("should show progress indicator animation during streaming", () => {
      const messages = [
        createMockMessage("user", [createTextBlock("hi")]),
      ];
      const streamingBlocks = [createTextBlock("Hello")];

      render(
        <ChatMessages
          messages={messages}
          streamingBlocks={streamingBlocks}
          isStreaming={true}
        />
      );

      const streamingContainer = document.querySelector(".animate-border-spin");
      expect(streamingContainer).toBeInTheDocument();
      expect(streamingContainer).toHaveClass("bg-surface-tertiary");
      expect(streamingContainer).toHaveClass("border-2");
    });

    it("should hide progress indicator when streaming completes", () => {
      const messages = [
        createMockMessage("user", [createTextBlock("hi")]),
        createMockMessage("assistant", [createTextBlock("Hello there!")]),
      ];

      const { rerender } = render(
        <ChatMessages
          messages={messages.slice(0, 1)}
          streamingBlocks={[createTextBlock("Hello")]}
          isStreaming={true}
        />
      );

      let streamingContainer = document.querySelector(".animate-border-spin");
      expect(streamingContainer).toBeInTheDocument();

      // Rerender with completed state
      rerender(
        <ChatMessages
          messages={messages}
          isStreaming={false}
        />
      );

      streamingContainer = document.querySelector(".animate-border-spin");
      expect(streamingContainer).not.toBeInTheDocument();
    });

    it("should show progress indicator for multiple messages sequentially", () => {
      const messages = [
        createMockMessage("user", [createTextBlock("first")]),
      ];

      const { rerender } = render(
        <ChatMessages
          messages={messages}
          streamingBlocks={[createTextBlock("First response")]}
          isStreaming={true}
        />
      );

      let streamingContainer = document.querySelector(".animate-border-spin");
      expect(streamingContainer).toBeInTheDocument();

      // Complete first message
      const completedMessages = [
        ...messages,
        createMockMessage("assistant", [createTextBlock("First response")]),
        createMockMessage("user", [createTextBlock("second")]),
      ];

      rerender(
        <ChatMessages
          messages={completedMessages}
          isStreaming={false}
        />
      );

      streamingContainer = document.querySelector(".animate-border-spin");
      expect(streamingContainer).not.toBeInTheDocument();

      // Start second streaming
      rerender(
        <ChatMessages
          messages={completedMessages}
          streamingBlocks={[createTextBlock("Second response")]}
          isStreaming={true}
        />
      );

      streamingContainer = document.querySelector(".animate-border-spin");
      expect(streamingContainer).toBeInTheDocument();
    });

    it("should maintain message readability during animation", () => {
      const messages = [
        createMockMessage("user", [createTextBlock("test")]),
      ];
      const streamingBlocks = [createTextBlock("Hello from Claude")];

      render(
        <ChatMessages
          messages={messages}
          streamingBlocks={streamingBlocks}
          isStreaming={true}
        />
      );

      expect(screen.getByText("Claude")).toBeInTheDocument();
      expect(screen.getByText("Hello from Claude")).toBeInTheDocument();

      const streamingContainer = document.querySelector(".animate-border-spin");
      expect(streamingContainer).toBeInTheDocument();
    });
  });

  describe("Basic Message Display", () => {
    it("should display user messages", () => {
      const messages = [
        createMockMessage("user", [createTextBlock("Hello")]),
      ];

      render(<ChatMessages messages={messages} />);

      expect(screen.getByText("You")).toBeInTheDocument();
      expect(screen.getByText("Hello")).toBeInTheDocument();
    });

    it("should display assistant messages", () => {
      const messages = [
        createMockMessage("assistant", [createTextBlock("Hi there!")]),
      ];

      render(<ChatMessages messages={messages} />);

      expect(screen.getByText("Claude")).toBeInTheDocument();
      expect(screen.getByText("Hi there!")).toBeInTheDocument();
    });

    it("should display multiple messages in order", () => {
      const messages = [
        createMockMessage("user", [createTextBlock("First message")]),
        createMockMessage("assistant", [createTextBlock("Second message")]),
        createMockMessage("user", [createTextBlock("Third message")]),
      ];

      render(<ChatMessages messages={messages} />);

      expect(screen.getByText("First message")).toBeInTheDocument();
      expect(screen.getByText("Second message")).toBeInTheDocument();
      expect(screen.getByText("Third message")).toBeInTheDocument();

      const allMessages = screen.getAllByText(/You|Claude/);
      expect(allMessages.length).toBeGreaterThanOrEqual(3);
    });

    it("should show empty state when no messages", () => {
      render(<ChatMessages messages={[]} />);

      expect(screen.getByText("Write something special...")).toBeInTheDocument();
    });

    it("should not show empty state when streaming", () => {
      render(
        <ChatMessages
          messages={[]}
          streamingBlocks={[createTextBlock("Hello")]}
          isStreaming={true}
        />
      );

      expect(screen.queryByText("Write something special...")).not.toBeInTheDocument();
    });
  });

  describe("Streaming Content Display", () => {
    it("should display streaming text with cursor", () => {
      const messages = [
        createMockMessage("user", [createTextBlock("test")]),
      ];
      const streamingBlocks = [createTextBlock("Streaming...")];

      render(
        <ChatMessages
          messages={messages}
          streamingBlocks={streamingBlocks}
          isStreaming={true}
        />
      );

      expect(screen.getByText("Streaming...")).toBeInTheDocument();

      const cursor = document.querySelector(".animate-pulse");
      expect(cursor).toBeInTheDocument();
      expect(cursor).toHaveClass("bg-brand-primary");
    });

    it("should not show cursor when not streaming", () => {
      const messages = [
        createMockMessage("assistant", [createTextBlock("Complete message")]),
      ];

      render(
        <ChatMessages
          messages={messages}
          isStreaming={false}
        />
      );

      const cursor = document.querySelector(".animate-pulse");
      expect(cursor).not.toBeInTheDocument();
    });
  });
});
