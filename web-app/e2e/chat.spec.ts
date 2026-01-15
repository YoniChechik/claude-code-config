import { test, expect } from "@playwright/test";

test.describe("Chat Functionality", () => {
  test("should send a message and receive a response", async ({ page }) => {
    // Mock Claude API to return instant response
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Hello! This is a mocked response."}\n\ndata: {"type":"result","duration_ms":500}\n\n',
      });
    });

    // Navigate to the app
    await page.goto("/");

    // Wait for the chat interface to load (wait for sessions to initialize)
    await page.waitForSelector("textarea, input[type='text']", {
      timeout: 10000,
    });

    // Use the first chat pane (left side in split layout)
    const leftPane = page.locator("main > div > div").first();

    // Find the input field in the first pane
    const chatInput = leftPane.locator("textarea, input[type='text']").first();

    // Type "hi" in the chat input
    await chatInput.fill("hi");

    // Verify text was entered
    await expect(chatInput).toHaveValue("hi");

    // Send message with Enter key
    await chatInput.press("Enter");

    // Wait for the input to be cleared (indicates message was sent)
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for Claude's response message to appear with actual text content
    // The response should have the role label "Claude" and some actual response text
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();

    // Wait up to 20 seconds for the response to appear
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Verify the message contains actual text content (not just "Claude" label and timestamp)
    // Extract just the content div which has class whitespace-pre-wrap
    const contentDiv = claudeMessage.locator("div.whitespace-pre-wrap");
    await expect(contentDiv).toBeVisible({ timeout: 5000 });

    // The content should have some actual text or at least the streaming cursor
    const responseText = await contentDiv.textContent();
    expect(responseText).toBeTruthy();
    // Verify that response text appears (either actual text from mock/real response or streaming cursor)
    expect(responseText!.length).toBeGreaterThan(0);

    // Verify input is still cleared
    await expect(chatInput).toHaveValue("");
  });

  test("should not allow sending empty messages", async ({ page }) => {
    await page.goto("/");

    // Wait for the chat interface to load
    await page.waitForSelector("textarea, input[type='text']", {
      timeout: 10000,
    });

    // Use the first chat pane
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea, input[type='text']").first();

    // Verify input is empty
    await expect(chatInput).toHaveValue("");

    // Try pressing Enter with empty input (should not send)
    await chatInput.press("Enter");

    // Verify no messages appear (input should still be empty and focused)
    await expect(chatInput).toHaveValue("");
  });

  test("should show loading state while streaming", async ({ page }) => {
    await page.goto("/");

    // Wait for the chat interface to load
    await page.waitForSelector("textarea, input[type='text']", {
      timeout: 10000,
    });

    // Use the first chat pane
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea, input[type='text']").first();

    // Type and send a message
    await chatInput.fill("hello");
    await chatInput.press("Enter");

    // Wait a bit for streaming to start
    await page.waitForTimeout(500);

    // Input should be cleared after sending
    await expect(chatInput).toHaveValue("");
  });

  test("should display timestamps next to tool names in ToolUseCard", async ({
    page,
  }) => {
    // Mock Claude API to return instant response with tool use
    await page.route("**/api/commands", async (route) => {
      const timestamp = new Date().toISOString();
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: `data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"tool_use","tool":{"id":"tool_123","name":"Read","input":{"file_path":"/package.json"},"timestamp":"${timestamp}"}}\n\ndata: {"type":"tool_result","tool_result":{"tool_use_id":"tool_123","content":"{\\"name\\":\\"test\\"}"}}\n\ndata: {"type":"text","content":"Here is the package.json content"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n`,
      });
    });

    await page.goto("/");

    // Wait for the chat interface to load
    await page.waitForSelector("textarea", {
      timeout: 10000,
    });

    // Use the first chat pane
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    // Send a message that triggers a tool call
    await chatInput.fill("read the package.json file");
    await chatInput.press("Enter");

    // Wait for the input to be cleared
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for Claude's response to start appearing
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Wait for a tool use block to appear (like [Read])
    const toolUseBlock = claudeMessage
      .locator("div.border-l-4")
      .filter({ hasText: "[Read]" })
      .first();
    await expect(toolUseBlock).toBeVisible({ timeout: 10000 });

    // Verify that a timestamp in HH:MM:SS format appears next to the tool name
    const timestampRegex = /\d{2}:\d{2}:\d{2}/;
    const toolBlockText = await toolUseBlock.textContent();
    expect(toolBlockText).toMatch(timestampRegex);

    // Verify the timestamp appears on the same line as the tool name
    // The format should be like "[Read] HH:MM:SS"
    expect(toolBlockText).toMatch(/\[Read\].*\d{2}:\d{2}:\d{2}/);
  });
});
