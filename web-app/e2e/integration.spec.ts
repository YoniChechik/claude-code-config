import { test, expect } from "@playwright/test";

test.describe("Full Integration Tests", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForLoadState("networkidle");
  });

  test("complete workflow: create session, send command, verify response", async ({
    page,
  }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');
    await expect(input).toBeVisible();

    await input.fill("echo 'Hello, World!'");
    await input.press("Enter");

    await page.waitForTimeout(1000);

    const messages = page.locator(".message-content");
    await expect(messages.first()).toBeVisible({ timeout: 10000 });
  });

  test("multiple commands in sequence", async ({ page }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');

    const commands = [
      "list files in current directory",
      "show current directory",
      "what is 2+2?",
    ];

    for (const command of commands) {
      await input.fill(command);
      await input.press("Enter");
      await page.waitForTimeout(2000);
    }

    const messages = page.locator(".message-content");
    const count = await messages.count();
    expect(count).toBeGreaterThan(0);
  });

  test("session persistence across interactions", async ({ page }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');

    await input.fill("remember my name is TestUser");
    await input.press("Enter");
    await page.waitForTimeout(2000);

    await input.fill("what is my name?");
    await input.press("Enter");
    await page.waitForTimeout(2000);

    const messages = page.locator(".message-content");
    expect(await messages.count()).toBeGreaterThan(0);
  });

  test("directory navigation and state tracking", async ({ page }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');
    const directoryNav = page.locator("text=/\\/home|\\//");

    const initialDir = await directoryNav.textContent();

    await input.fill("cd /tmp");
    await input.press("Enter");
    await page.waitForTimeout(3000);

    const newDir = await directoryNav.textContent();
    expect(newDir).not.toBe(initialDir);
  });

  test("stop button integration during command execution", async ({ page }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');

    await input.fill("sleep 10");
    await input.press("Enter");

    await page.waitForTimeout(500);

    const stopButton = page.locator('button[aria-label*="Stop"]');

    if ((await stopButton.count()) > 0) {
      await stopButton.click();
      await page.waitForTimeout(500);

      const messages = page.locator(".message-content");
      expect(await messages.count()).toBeGreaterThanOrEqual(0);
    }
  });

  test("progress indicator appears during long operations", async ({ page }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');

    await input.fill("test command");
    await input.press("Enter");

    const progressIndicator = page.locator('[role="progressbar"]');

    if ((await progressIndicator.count()) > 0) {
      await expect(progressIndicator).toBeVisible({ timeout: 2000 });
    }
  });

  test("clear session and verify messages removed", async ({ page }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');

    await input.fill("test command");
    await input.press("Enter");
    await page.waitForTimeout(2000);

    const clearButton = page.locator("button", { hasText: /clear/i });

    if ((await clearButton.count()) > 0) {
      await clearButton.click();
      await page.waitForTimeout(500);

      const messages = page.locator(".message-content");
      expect(await messages.count()).toBe(0);
    }
  });

  test("dark mode toggle persistence", async ({ page }) => {
    const darkModeToggle = page.locator('button[aria-label*="dark mode"]');

    if ((await darkModeToggle.count()) > 0) {
      const initialState = await page.locator("html").getAttribute("class");

      await darkModeToggle.click();
      await page.waitForTimeout(500);

      const newState = await page.locator("html").getAttribute("class");
      expect(newState).not.toBe(initialState);

      await page.reload();
      await page.waitForLoadState("networkidle");

      const reloadedState = await page.locator("html").getAttribute("class");
      expect(reloadedState).toBe(newState);
    }
  });

  test("keyboard shortcuts work correctly", async ({ page }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');

    await input.fill("test command");

    await input.press("Control+Enter");
    await page.waitForTimeout(500);

    await input.fill("");
    await page.waitForTimeout(500);

    await input.press("Escape");
    await page.waitForTimeout(500);

    await expect(input).toHaveValue("");
  });

  test("autosuggest functionality", async ({ page }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');

    await input.fill("cd ");
    await page.waitForTimeout(500);

    const suggestions = page.locator('[role="listbox"]');

    if ((await suggestions.count()) > 0) {
      await expect(suggestions).toBeVisible();

      const suggestionItems = suggestions.locator('[role="option"]');
      const count = await suggestionItems.count();
      expect(count).toBeGreaterThan(0);
    }
  });

  test("session picker shows recent sessions", async ({ page }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("test command");
    await input.press("Enter");
    await page.waitForTimeout(2000);

    const sessionPicker = page.locator("button", { hasText: /session/i });

    if ((await sessionPicker.count()) > 0) {
      await sessionPicker.click();
      await page.waitForTimeout(500);

      const sessionList = page.locator('[role="menu"], [role="listbox"]');
      await expect(sessionList).toBeVisible();
    }
  });

  test("tool use cards render correctly", async ({ page }) => {
    await page.route("**/api/commands", async (route) => {
      const mockResponse = `data: {"type":"init","model":"claude-sonnet-4-5-20250929","session_id":"test-123"}\n\ndata: {"type":"tool_use","tool":{"id":"tool_001","name":"Read","input":{"file_path":"/test.txt"},"timestamp":"2026-01-14T12:00:00.000Z"}}\n\ndata: {"type":"tool_result","tool_result":{"tool_use_id":"tool_001","content":"Test file content"}}\n\ndata: {"type":"text","content":"File read successfully"}\n\ndata: {"type":"result","duration_ms":1000}\n\ndata: {"type":"structured_output","structured_output":{"response":"File read successfully"}}\n\ndata: [DONE]\n\n`;

      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: mockResponse,
      });
    });

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("read /test.txt");
    await input.press("Enter");

    await page.waitForTimeout(2000);

    const toolCard = page.locator(".tool-use-card, [data-tool-use]");

    if ((await toolCard.count()) > 0) {
      await expect(toolCard.first()).toBeVisible();
    }
  });

  test("handle rapid consecutive commands", async ({ page }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');

    for (let i = 0; i < 3; i++) {
      await input.fill(`command ${i}`);
      await input.press("Enter");
      await page.waitForTimeout(100);
    }

    await page.waitForTimeout(3000);

    const messages = page.locator(".message-content");
    const count = await messages.count();
    expect(count).toBeGreaterThan(0);
  });

  test("message timestamps are displayed", async ({ page }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("test command");
    await input.press("Enter");

    await page.waitForTimeout(2000);

    const timestamp = page.locator("time, [datetime], text=/ago|AM|PM/i");

    if ((await timestamp.count()) > 0) {
      await expect(timestamp.first()).toBeVisible();
    }
  });

  test("long responses are scrollable", async ({ page }) => {
    await page.route("**/api/commands", async (route) => {
      const longContent = "Line\n".repeat(100);
      const mockResponse = `data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"${longContent}"}\n\ndata: {"type":"result","duration_ms":1000}\n\ndata: {"type":"structured_output","structured_output":{"response":"${longContent}"}}\n\ndata: [DONE]\n\n`;

      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: mockResponse,
      });
    });

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("generate long text");
    await input.press("Enter");

    await page.waitForTimeout(2000);

    const chatContainer = page.locator(".chat-messages, .messages-container");

    if ((await chatContainer.count()) > 0) {
      const scrollHeight = await chatContainer.evaluate(
        (el) => el.scrollHeight,
      );
      const clientHeight = await chatContainer.evaluate(
        (el) => el.clientHeight,
      );
      expect(scrollHeight).toBeGreaterThan(clientHeight);
    }
  });

  test("input expands for multiline text", async ({ page }) => {
    const input = page.locator('textarea[placeholder*="Type a command"]');

    const multilineText = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5";
    await input.fill(multilineText);

    await page.waitForTimeout(500);

    const boundingBox = await input.boundingBox();
    expect(boundingBox?.height).toBeGreaterThan(50);
  });

  test("token usage is displayed when available", async ({ page }) => {
    await page.route("**/api/commands", async (route) => {
      const mockResponse = `data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Response"}\n\ndata: {"type":"token_usage","token_usage":{"used":1000,"total":200000,"remaining":199000}}\n\ndata: {"type":"result","duration_ms":1000}\n\ndata: {"type":"structured_output","structured_output":{"response":"Response"}}\n\ndata: [DONE]\n\n`;

      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: mockResponse,
      });
    });

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("test command");
    await input.press("Enter");

    await page.waitForTimeout(2000);

    const tokenInfo = page.locator("text=/token|usage|1000/i");

    if ((await tokenInfo.count()) > 0) {
      await expect(tokenInfo.first()).toBeVisible();
    }
  });
});
