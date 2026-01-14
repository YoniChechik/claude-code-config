import {
  parseStreamLine,
  formatDuration,
  generateSessionId,
  stripAnsi,
  isAbsolutePath,
  normalizePath,
} from "../lib/utils";

describe("utils", () => {
  describe("parseStreamLine", () => {
    it("should parse TEXT line", () => {
      const result = parseStreamLine("TEXT:Hello world");
      expect(result).toEqual({ type: "TEXT", text: "Hello world" });
    });

    it("should parse TEXT line with newlines", () => {
      const result = parseStreamLine(
        "TEXT:Line 1@@NEWLINE@@Line 2@@NEWLINE@@Line 3",
      );
      expect(result).toEqual({ type: "TEXT", text: "Line 1\nLine 2\nLine 3" });
    });

    it("should parse LINE line", () => {
      const result = parseStreamLine("LINE:Some content");
      expect(result).toEqual({ type: "LINE", text: "Some content" });
    });

    it("should parse SUB line", () => {
      const result = parseStreamLine("SUB:Subtitle text");
      expect(result).toEqual({ type: "SUB", text: "Subtitle text" });
    });

    it("should parse JSON line", () => {
      const result = parseStreamLine('JSON:{"key":"value","num":42}');
      expect(result).toEqual({
        type: "JSON",
        data: { key: "value", num: 42 },
      });
    });

    it("should return null for invalid JSON", () => {
      const result = parseStreamLine("JSON:{invalid json}");
      expect(result).toBeNull();
    });

    it("should return null for unknown format", () => {
      const result = parseStreamLine("UNKNOWN:content");
      expect(result).toBeNull();
    });

    it("should return null for empty line", () => {
      const result = parseStreamLine("");
      expect(result).toBeNull();
    });
  });

  describe("formatDuration", () => {
    it("should format milliseconds under 1 second", () => {
      expect(formatDuration(0)).toBe("0ms");
      expect(formatDuration(100)).toBe("100ms");
      expect(formatDuration(999)).toBe("999ms");
    });

    it("should format seconds with one decimal", () => {
      expect(formatDuration(1000)).toBe("1.0s");
      expect(formatDuration(1500)).toBe("1.5s");
      expect(formatDuration(5432)).toBe("5.4s");
      expect(formatDuration(60000)).toBe("60.0s");
    });

    it("should handle large durations", () => {
      expect(formatDuration(123456)).toBe("123.5s");
    });
  });

  describe("generateSessionId", () => {
    it("should generate UUID v4 format", () => {
      const id = generateSessionId();
      const uuidRegex =
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
      expect(id).toMatch(uuidRegex);
    });

    it("should generate unique IDs", () => {
      const ids = new Set<string>();
      for (let i = 0; i < 100; i++) {
        ids.add(generateSessionId());
      }
      expect(ids.size).toBe(100);
    });

    it("should have hyphens in correct positions", () => {
      const id = generateSessionId();
      expect(id[8]).toBe("-");
      expect(id[13]).toBe("-");
      expect(id[18]).toBe("-");
      expect(id[23]).toBe("-");
    });

    it("should have 4 at position 14 (version)", () => {
      const id = generateSessionId();
      expect(id[14]).toBe("4");
    });

    it("should have variant bits correct", () => {
      const id = generateSessionId();
      const variantChar = id[19];
      expect(["8", "9", "a", "b"]).toContain(variantChar);
    });
  });

  describe("stripAnsi", () => {
    it("should remove ANSI color codes", () => {
      expect(stripAnsi("\x1b[31mRed text\x1b[0m")).toBe("Red text");
    });

    it("should handle multiple ANSI codes", () => {
      expect(stripAnsi("\x1b[1m\x1b[31mBold red\x1b[0m")).toBe("Bold red");
    });

    it("should handle text without ANSI codes", () => {
      expect(stripAnsi("Plain text")).toBe("Plain text");
    });

    it("should handle empty string", () => {
      expect(stripAnsi("")).toBe("");
    });

    it("should handle complex ANSI sequences", () => {
      expect(stripAnsi("\x1b[38;5;214mOrange text\x1b[0m")).toBe(
        "Orange text",
      );
    });
  });

  describe("isAbsolutePath", () => {
    it("should return true for absolute paths", () => {
      expect(isAbsolutePath("/home/user")).toBe(true);
      expect(isAbsolutePath("/")).toBe(true);
      expect(isAbsolutePath("/tmp/test")).toBe(true);
    });

    it("should return false for relative paths", () => {
      expect(isAbsolutePath("relative/path")).toBe(false);
      expect(isAbsolutePath("./current")).toBe(false);
      expect(isAbsolutePath("../parent")).toBe(false);
      expect(isAbsolutePath("")).toBe(false);
    });
  });

  describe("normalizePath", () => {
    it("should remove trailing slashes", () => {
      expect(normalizePath("/home/user/")).toBe("/home/user");
      expect(normalizePath("/tmp///")).toBe("/tmp");
    });

    it("should preserve root path", () => {
      expect(normalizePath("/")).toBe("/");
      expect(normalizePath("//")).toBe("/");
    });

    it("should handle paths without trailing slashes", () => {
      expect(normalizePath("/home/user")).toBe("/home/user");
    });

    it("should handle empty string as root", () => {
      expect(normalizePath("")).toBe("/");
    });

    it("should handle multiple consecutive slashes", () => {
      expect(normalizePath("/home/user////")).toBe("/home/user");
    });
  });
});
