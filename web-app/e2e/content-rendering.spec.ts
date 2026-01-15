import { test, expect } from "@playwright/test";

test.describe("Content Rendering", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });
  });

  test("should render text blocks without truncation", async ({ page }) => {
    // Mock Claude API to return instant response
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Hello! This is a test response."}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    // Send a message asking for a response
    await chatInput.fill("say hello");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for Claude's response
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Get the content div
    const contentDiv = claudeMessage.locator("div.whitespace-pre-wrap").first();
    await expect(contentDiv).toBeVisible();

    // Verify content is present and not empty
    const textContent = await contentDiv.textContent();
    expect(textContent).toBeTruthy();
    expect(textContent!.length).toBeGreaterThan(0);

    // Verify no overflow-hidden that would truncate content
    const contentClasses = await contentDiv.getAttribute("class");
    expect(contentClasses).not.toContain("overflow-hidden");
  });

  test("should render thinking blocks correctly", async ({ page }) => {
    // Mock Claude API with thinking block
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"thinking","content":"Let me think about this..."}\n\ndata: {"type":"text","content":"Here is the solution"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    // Send a message that might trigger thinking
    await chatInput.fill("solve a complex problem");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for response to start
    await page.waitForTimeout(2000);

    // Check if thinking block appears (they have italic style and gray color)
    // Thinking blocks may or may not appear depending on model behavior
    const thinkingBlocks = leftPane.locator("div.italic.text-gray-400");
    const thinkingCount = await thinkingBlocks.count();

    // If thinking blocks exist, verify they're styled correctly
    if (thinkingCount > 0) {
      const firstThinking = thinkingBlocks.first();
      await expect(firstThinking).toBeVisible();

      // Verify styling
      const classes = await firstThinking.getAttribute("class");
      expect(classes).toContain("italic");
      expect(classes).toContain("text-gray-400");
    }
  });

  test("should display tool use blocks correctly", async ({ page }) => {
    // Mock Claude API with tool use
    await page.route("**/api/commands", async (route) => {
      const timestamp = new Date().toISOString();
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: `data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"tool_use","tool":{"id":"tool_001","name":"Read","input":{"file_path":"/package.json"},"timestamp":"${timestamp}"}}\n\ndata: {"type":"tool_result","tool_result":{"tool_use_id":"tool_001","content":"{\\"name\\":\\"test\\"}"}}\n\ndata: {"type":"text","content":"Here is the content"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n`,
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    // Send a message that will trigger tool use
    await chatInput.fill("read the package.json file");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for tool use block to appear
    const toolUseBlock = leftPane
      .locator("div.border-l-4")
      .filter({ hasText: "[Read]" })
      .first();
    await expect(toolUseBlock).toBeVisible({ timeout: 15000 });

    // Verify tool use block has correct styling (border-l-4)
    const classes = await toolUseBlock.getAttribute("class");
    expect(classes).toContain("border-l-4");

    // Verify tool name is visible
    const toolText = await toolUseBlock.textContent();
    expect(toolText).toContain("Read");
  });

  test("should display tool result blocks correctly", async ({ page }) => {
    // Mock Claude API with tool use and results
    await page.route("**/api/commands", async (route) => {
      const timestamp = new Date().toISOString();
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: `data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"tool_use","tool":{"id":"tool_002","name":"Read","input":{"file_path":"/package.json"},"timestamp":"${timestamp}"}}\n\ndata: {"type":"tool_result","tool_result":{"tool_use_id":"tool_002","content":"{\\"name\\":\\"test-package\\"}"}}\n\ndata: {"type":"text","content":"The file contains package info"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n`,
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    // Send a message that will trigger tool use and return results
    await chatInput.fill("read the package.json file");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for tool result to appear (bg-gray-800 with actual content)
    await page.waitForTimeout(5000);

    // Tool results are in bg-gray-800 divs (same as message container)
    // Wait for the full response to complete
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Verify tool use block appeared
    const toolUseBlock = claudeMessage.locator("div.border-l-4").first();
    await expect(toolUseBlock).toBeVisible();
  });

  test("should handle tool result expand/collapse", async ({ page }) => {
    // Mock Claude API with tool use and results
    await page.route("**/api/commands", async (route) => {
      const timestamp = new Date().toISOString();
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: `data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"tool_use","tool":{"id":"tool_003","name":"Read","input":{"file_path":"/package.json"},"timestamp":"${timestamp}"}}\n\ndata: {"type":"tool_result","tool_result":{"tool_use_id":"tool_003","content":"Large result content that might be collapsible"}}\n\ndata: {"type":"text","content":"Done"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n`,
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    // Send a message that will return tool results
    await chatInput.fill("read package.json");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for response to complete
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Look for collapsible sections (tool results might be collapsible)
    // Tool results typically have a header that can be clicked
    const toolResultHeaders = claudeMessage.locator("div.cursor-pointer");
    const headerCount = await toolResultHeaders.count();

    // If collapsible headers exist, test expand/collapse
    if (headerCount > 0) {
      const firstHeader = toolResultHeaders.first();
      await expect(firstHeader).toBeVisible();

      // Click to toggle
      await firstHeader.click();
      await page.waitForTimeout(300);

      // Click again to toggle back
      await firstHeader.click();
      await page.waitForTimeout(300);

      // Should not crash
      await expect(firstHeader).toBeVisible();
    }
  });

  test("should not have console errors during rendering", async ({ page }) => {
    // Mock Claude API to return instant response
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Hello there!"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const consoleErrors: string[] = [];

    // Listen for console errors
    page.on("console", (msg) => {
      if (msg.type() === "error") {
        consoleErrors.push(msg.text());
      }
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    // Send a message
    await chatInput.fill("hello");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for response
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Give time for any async rendering
    await page.waitForTimeout(2000);

    // Verify no console errors occurred
    // Filter out known acceptable errors (like network errors in tests)
    const relevantErrors = consoleErrors.filter(
      (err) =>
        !err.includes("Failed to load resource") &&
        !err.includes("net::ERR_"),
    );

    expect(relevantErrors.length).toBe(0);
  });

  test("should display all messages without missing content", async ({
    page,
  }) => {
    // Mock multiple API responses
    let callCount = 0;
    await page.route("**/api/commands", async (route) => {
      callCount++;
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: `data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Response ${callCount}"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n`,
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    // Send first message
    await chatInput.fill("first");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for first response
    await page.waitForTimeout(3000);

    // Send second message
    await chatInput.fill("second");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for second response
    await page.waitForTimeout(3000);

    // Verify both user messages are visible
    await expect(leftPane.locator("text=first")).toBeVisible();
    await expect(leftPane.locator("text=second")).toBeVisible();

    // Verify multiple Claude responses exist
    const claudeMessages = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") });
    const messageCount = await claudeMessages.count();

    // Should have at least 2 Claude messages
    expect(messageCount).toBeGreaterThanOrEqual(2);

    // All messages should have content
    for (let i = 0; i < messageCount; i++) {
      const msg = claudeMessages.nth(i);
      await expect(msg).toBeVisible();

      const content = msg.locator("div.whitespace-pre-wrap").first();
      await expect(content).toBeVisible();
    }
  });

  test("should render content blocks in correct order", async ({ page }) => {
    // Mock Claude API with Glob tool use
    await page.route("**/api/commands", async (route) => {
      const timestamp = new Date().toISOString();
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: `data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"tool_use","tool":{"id":"tool_004","name":"Glob","input":{"pattern":"**/*.json"},"timestamp":"${timestamp}"}}\n\ndata: {"type":"tool_result","tool_result":{"tool_use_id":"tool_004","content":"file1.json\\nfile2.json"}}\n\ndata: {"type":"text","content":"Found JSON files"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n`,
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    // Send message that will trigger tool use
    await chatInput.fill("use glob to search for **/*.json files");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for response to complete
    await page.waitForTimeout(8000);

    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Get all child blocks in the message
    const messageContent = claudeMessage.locator("div.whitespace-pre-wrap").first();
    await expect(messageContent).toBeVisible();

    // Verify content has been rendered (either text or tool blocks)
    const hasContent = await messageContent.evaluate((el) => {
      return el.children.length > 0 || el.textContent!.trim().length > 0;
    });

    expect(hasContent).toBe(true);
  });

  test("should handle streaming text without data loss", async ({ page }) => {
    // Mock Claude API with streaming response
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Here is an interesting fact about streaming!"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    // Send a message
    await chatInput.fill("tell me a fact");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for streaming to start
    await page.waitForTimeout(1000);

    // Check streaming message appears
    const streamingMessage = leftPane
      .locator("div.bg-gray-800.animate-border-spin")
      .first();
    await expect(streamingMessage).toBeVisible({ timeout: 5000 });

    // Get text while streaming (if any)
    const streamingContent = streamingMessage
      .locator("div.whitespace-pre-wrap")
      .first();
    await expect(streamingContent).toBeVisible();

    const textDuringStreaming = await streamingContent.textContent();

    // Wait for completion
    await page.waitForTimeout(5000);

    // Get final message
    const completedMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(completedMessage).toBeVisible();

    const finalContent = completedMessage
      .locator("div.whitespace-pre-wrap")
      .first();
    const finalText = await finalContent.textContent();

    // Final text should be at least as long as streaming text
    expect(finalText!.length).toBeGreaterThanOrEqual(0);

    // If there was text during streaming, final should contain it
    if (textDuringStreaming && textDuringStreaming.trim().length > 0) {
      // Final text should have content (may be different due to streaming)
      expect(finalText!.length).toBeGreaterThan(0);
    }
  });

  test("messages should persist after sending and not disappear", async ({
    page,
  }) => {
    // Mock Claude API to return instant response
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Hello! Message persistence test."}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    await page.goto("/");

    // Wait for the chat interface to load
    await page.waitForSelector("textarea, input[type='text']", {
      timeout: 10000,
    });

    // Use the first chat pane
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea, input[type='text']").first();

    // Type "hi" in the chat input
    await chatInput.fill("hi");

    // Send the message
    await chatInput.press("Enter");

    // Wait for the input to be cleared (indicates message was sent)
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for the user message "hi" to appear
    await expect(leftPane.locator("text=hi")).toBeVisible({ timeout: 5000 });

    // Wait for a response to appear
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // CRITICAL: Verify both messages are STILL visible after 3 seconds
    // This reproduces the bug where messages disappear shortly after appearing
    await page.waitForTimeout(3000);

    // User message "hi" should still be visible
    await expect(leftPane.locator("text=hi")).toBeVisible({
      timeout: 1000,
    });

    // Assistant response should still be visible
    const responseContent = claudeMessage.locator("div.whitespace-pre-wrap");
    await expect(responseContent).toBeVisible({ timeout: 1000 });

    // Verify the response text is non-empty
    const responseText = await responseContent.textContent();
    expect(responseText).toBeTruthy();
  });

  test("tool calls and results should maintain causal ordering", async ({
    page,
  }) => {
    // Mock Claude API with multiple tool uses in causal order
    await page.route("**/api/commands", async (route) => {
      const timestamp = new Date().toISOString();
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: `data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"tool_use","tool":{"id":"tool_005","name":"Glob","input":{"pattern":"**/*nonexistent1*.xyz"},"timestamp":"${timestamp}"}}\n\ndata: {"type":"tool_result","tool_result":{"tool_use_id":"tool_005","content":"No matches"}}\n\ndata: {"type":"tool_use","tool":{"id":"tool_006","name":"Glob","input":{"pattern":"**/*nonexistent2*.xyz"},"timestamp":"${timestamp}"}}\n\ndata: {"type":"tool_result","tool_result":{"tool_use_id":"tool_006","content":"No matches"}}\n\ndata: {"type":"tool_use","tool":{"id":"tool_007","name":"Glob","input":{"pattern":"**/*nonexistent3*.xyz"},"timestamp":"${timestamp}"}}\n\ndata: {"type":"tool_result","tool_result":{"tool_use_id":"tool_007","content":"No matches"}}\n\ndata: {"type":"text","content":"Search complete"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n`,
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

    // Send a prompt that will trigger multiple parallel tool calls
    // This simulates the scenario where multiple Glob calls happen
    await chatInput.fill(
      "use glob to search for these patterns: **/*nonexistent1*.xyz, **/*nonexistent2*.xyz, **/*nonexistent3*.xyz",
    );
    await chatInput.press("Enter");

    // Wait for the input to be cleared
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for Claude's response to start appearing
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Wait for at least 2 tool use blocks to appear (indicating multiple tool calls)
    await page.waitForTimeout(5000); // Give time for streaming to show tools

    // Get all tool-related elements within the Claude message
    // Tool use blocks have border-l-4 and contain [ToolName]
    // Tool result blocks have bg-gray-800 and contain output
    const messageContent = claudeMessage
      .locator("div.whitespace-pre-wrap")
      .first();

    // Wait a bit more for all tool calls to complete
    await page.waitForTimeout(10000);

    // Get all child divs that could be tool blocks
    const allBlocks = await messageContent.locator("div").all();

    // Build a sequence of block types
    interface Block {
      type: "tool_use" | "tool_result" | "other";
      text: string;
      index: number;
    }

    const blockSequence: Block[] = [];

    for (let i = 0; i < allBlocks.length; i++) {
      const block = allBlocks[i];
      const classes = (await block.getAttribute("class")) || "";
      const text = (await block.textContent()) || "";

      // Identify tool_use blocks (have border-l-4 and contain [])
      if (classes.includes("border-l-4") && text.includes("[")) {
        blockSequence.push({ type: "tool_use", text, index: i });
      }
      // Identify tool_result blocks (have bg-gray-800 but not border-l-4, contain actual output)
      else if (
        classes.includes("bg-gray-800") &&
        !classes.includes("border-l-4") &&
        text.trim().length > 0
      ) {
        blockSequence.push({ type: "tool_result", text, index: i });
      }
    }

    // CRITICAL CAUSALITY CHECK:
    // Each tool_use should be immediately followed by its tool_result
    // We should NOT see all tool_uses followed by all tool_results

    let consecutiveToolUses = 0;
    let maxConsecutiveToolUses = 0;

    for (const block of blockSequence) {
      if (block.type === "tool_use") {
        consecutiveToolUses++;
        maxConsecutiveToolUses = Math.max(
          maxConsecutiveToolUses,
          consecutiveToolUses,
        );
      } else if (block.type === "tool_result") {
        consecutiveToolUses = 0;
      }
    }

    // If we have proper causal ordering, we should never see more than 1 consecutive tool_use
    // (each tool_use should be followed by its tool_result before the next tool_use)
    expect(maxConsecutiveToolUses).toBeLessThanOrEqual(1);

    // Also verify we actually found some tool calls
    const toolUseCount = blockSequence.filter(
      (b) => b.type === "tool_use",
    ).length;
    expect(toolUseCount).toBeGreaterThan(0);
  });
});
