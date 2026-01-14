import { ClaudeClient } from "../lib/claude-client";

describe("ClaudeClient", () => {
  let client: ClaudeClient;

  beforeEach(() => {
    client = new ClaudeClient();
  });

  describe("constructor", () => {
    it("should create client without API key", () => {
      expect(() => new ClaudeClient()).not.toThrow();
    });

    it("should create client with API key", () => {
      expect(() => new ClaudeClient("test-api-key")).not.toThrow();
    });
  });

  describe("getModels", () => {
    it("should return list of available models", () => {
      const models = client.getModels();
      expect(models).toContain("claude-sonnet-4-5-20250929");
      expect(models).toContain("claude-opus-4-5-20251101");
      expect(models).toContain("claude-3-5-sonnet-20241022");
      expect(models.length).toBeGreaterThan(0);
    });

    it("should return models as array", () => {
      const models = client.getModels();
      expect(Array.isArray(models)).toBe(true);
    });
  });

  describe("getDefaultModel", () => {
    it("should return default model", () => {
      const model = client.getDefaultModel();
      expect(model).toBe("claude-sonnet-4-5-20250929");
    });

    it("should return a non-empty string", () => {
      const model = client.getDefaultModel();
      expect(typeof model).toBe("string");
      expect(model.length).toBeGreaterThan(0);
    });

    it("should return a model that exists in getModels", () => {
      const models = client.getModels();
      const defaultModel = client.getDefaultModel();
      expect(models).toContain(defaultModel);
    });
  });

  // Note: streamCommand tests are omitted here because they require
  // complex process mocking. The streaming functionality is tested
  // through E2E tests instead.
});
