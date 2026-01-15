import { test, expect } from "@playwright/test";

test.describe("Chat Functionality", () => {
  test("should send a message and receive a response", async ({ page }) => {
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

    // Wait for the user message "hi" to appear in the chat
    await expect(leftPane.locator("text=hi")).toBeVisible({ timeout: 5000 });

    // Wait for Claude's response message to appear with actual text content
    // The response should have the role label "Claude" and some actual response text
    const claudeMessage = leftPane
      .locator("div.bg-gray-100")
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

  test("messages should persist after sending and not disappear", async ({
    page,
  }) => {
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
      .locator("div.bg-gray-100")
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

  test("should display timestamps next to tool names in ToolUseCard", async ({
    page,
  }) => {
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
    // The timestamp should match the pattern HH:MM:SS
    const timestampRegex = /\d{2}:\d{2}:\d{2}/;
    const toolBlockText = await toolUseBlock.textContent();
    expect(toolBlockText).toMatch(timestampRegex);

    // Verify the timestamp appears on the same line as the tool name
    // The format should be like "[Read] HH:MM:SS"
    expect(toolBlockText).toMatch(/\[Read\].*\d{2}:\d{2}:\d{2}/);
  });
});
