import { CDTracker } from "../lib/cd-tracker";

describe("CDTracker", () => {
  let tracker: CDTracker;

  beforeEach(() => {
    tracker = new CDTracker();
  });

  describe("initial state", () => {
    it("should initialize with default values", () => {
      expect(tracker.getWantedCwd()).toBeNull();
      expect(tracker.getLastDurationMs()).toBe(0);
      expect(tracker.getModel()).toBe("claude-sonnet-4-5-20250929");
    });

    it("should provide full state", () => {
      const state = tracker.getState();
      expect(state).toEqual({
        wantedCwd: null,
        lastDurationMs: 0,
        model: "claude-sonnet-4-5-20250929",
      });
    });
  });

  describe("processStructuredOutput", () => {
    it("should extract wanted_cwd from structured output", () => {
      tracker.processStructuredOutput({
        response: "Changed directory",
        wanted_cwd: "/home/user/project",
      });

      expect(tracker.getWantedCwd()).toBe("/home/user/project");
    });

    it("should handle structured output without wanted_cwd", () => {
      tracker.processStructuredOutput({
        response: "Some response",
      });

      expect(tracker.getWantedCwd()).toBeNull();
    });

    it("should update wanted_cwd on subsequent calls", () => {
      tracker.processStructuredOutput({
        response: "First change",
        wanted_cwd: "/home/user/first",
      });

      tracker.processStructuredOutput({
        response: "Second change",
        wanted_cwd: "/home/user/second",
      });

      expect(tracker.getWantedCwd()).toBe("/home/user/second");
    });

    it("should handle empty wanted_cwd", () => {
      tracker.processStructuredOutput({
        response: "Response",
        wanted_cwd: "",
      });

      // Empty string should not set wanted_cwd
      expect(tracker.getWantedCwd()).toBeNull();
    });
  });

  describe("processInitEvent", () => {
    it("should extract model from init event", () => {
      tracker.processInitEvent({
        model: "claude-opus-4-5-20251101",
      });

      expect(tracker.getModel()).toBe("claude-opus-4-5-20251101");
    });

    it("should handle init event without model", () => {
      tracker.processInitEvent({});

      expect(tracker.getModel()).toBe("claude-sonnet-4-5-20250929");
    });

    it("should update model on subsequent calls", () => {
      tracker.processInitEvent({ model: "claude-3-5-sonnet-20241022" });
      tracker.processInitEvent({ model: "claude-opus-4-5-20251101" });

      expect(tracker.getModel()).toBe("claude-opus-4-5-20251101");
    });
  });

  describe("processResultEvent", () => {
    it("should extract duration from result event", () => {
      tracker.processResultEvent({
        duration_ms: 1234,
      });

      expect(tracker.getLastDurationMs()).toBe(1234);
    });

    it("should handle result event without duration", () => {
      tracker.processResultEvent({});

      expect(tracker.getLastDurationMs()).toBe(0);
    });

    it("should handle zero duration", () => {
      tracker.processResultEvent({ duration_ms: 0 });

      expect(tracker.getLastDurationMs()).toBe(0);
    });

    it("should update duration on subsequent calls", () => {
      tracker.processResultEvent({ duration_ms: 1000 });
      tracker.processResultEvent({ duration_ms: 2000 });

      expect(tracker.getLastDurationMs()).toBe(2000);
    });

    it("should handle large durations", () => {
      tracker.processResultEvent({ duration_ms: 999999 });

      expect(tracker.getLastDurationMs()).toBe(999999);
    });
  });

  describe("reset", () => {
    it("should reset all state to defaults", () => {
      tracker.processStructuredOutput({
        response: "Test",
        wanted_cwd: "/test/path",
      });
      tracker.processInitEvent({ model: "claude-opus-4-5-20251101" });
      tracker.processResultEvent({ duration_ms: 5000 });

      tracker.reset();

      expect(tracker.getWantedCwd()).toBeNull();
      expect(tracker.getLastDurationMs()).toBe(0);
      expect(tracker.getModel()).toBe("claude-sonnet-4-5-20250929");
    });

    it("should allow reuse after reset", () => {
      tracker.processStructuredOutput({
        response: "First",
        wanted_cwd: "/first",
      });
      tracker.reset();
      tracker.processStructuredOutput({
        response: "Second",
        wanted_cwd: "/second",
      });

      expect(tracker.getWantedCwd()).toBe("/second");
    });
  });

  describe("integration scenarios", () => {
    it("should handle complete stream processing", () => {
      // Init event
      tracker.processInitEvent({ model: "claude-sonnet-4-5-20250929" });

      // Structured output with cwd change
      tracker.processStructuredOutput({
        response: "Changed to /home/user",
        wanted_cwd: "/home/user",
      });

      // Result event with duration
      tracker.processResultEvent({ duration_ms: 3456 });

      // Verify final state
      expect(tracker.getModel()).toBe("claude-sonnet-4-5-20250929");
      expect(tracker.getWantedCwd()).toBe("/home/user");
      expect(tracker.getLastDurationMs()).toBe(3456);
    });

    it("should handle multiple commands in sequence", () => {
      // First command
      tracker.processInitEvent({ model: "claude-sonnet-4-5-20250929" });
      tracker.processStructuredOutput({
        response: "First response",
        wanted_cwd: "/home/user/first",
      });
      tracker.processResultEvent({ duration_ms: 1000 });

      expect(tracker.getWantedCwd()).toBe("/home/user/first");

      // Second command without cwd change
      tracker.processStructuredOutput({
        response: "Second response",
      });
      tracker.processResultEvent({ duration_ms: 500 });

      // Cwd should remain from first command
      expect(tracker.getWantedCwd()).toBe("/home/user/first");
      expect(tracker.getLastDurationMs()).toBe(500);
    });

    it("should handle events in any order", () => {
      // Process events out of typical order
      tracker.processResultEvent({ duration_ms: 2000 });
      tracker.processStructuredOutput({
        response: "Response",
        wanted_cwd: "/test",
      });
      tracker.processInitEvent({ model: "claude-opus-4-5-20251101" });

      // All should be tracked correctly
      expect(tracker.getLastDurationMs()).toBe(2000);
      expect(tracker.getWantedCwd()).toBe("/test");
      expect(tracker.getModel()).toBe("claude-opus-4-5-20251101");
    });
  });
});
