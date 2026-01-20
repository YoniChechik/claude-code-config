import { test, expect } from "@playwright/test";

// This test validates the complete end-to-end flow with actual Claude API calls:
// UI → API → Claude CLI → streaming response → UI rendering
// Unlike other tests, this does NOT use any mocks - it sends a real prompt
// to Claude and verifies we receive an actual streaming response.
test.describe("Real Claude Response", () => {
  test("should send a real prompt and receive actual Claude response", async ({
    page,
  }) => {
    // Navigate to the app
    await page.goto("/", { waitUntil: "networkidle" });

    // Wait for the chat interface to load (wait for sessions to initialize)
    // This can take time as it needs to create a session
    await page.waitForSelector("textarea", {
      timeout: 30000,
    });

    // Use the first chat pane (left side in split layout)
    const leftPane = page.locator("main > div > div").first();

    // Find the textarea input in the first pane
    const chatInput = leftPane.locator("textarea").first();

    // Type "hi" in the chat input and press Enter to submit
    await chatInput.fill("hi");
    await expect(chatInput).toHaveValue("hi");
    await chatInput.press("Enter");

    // Wait for the input to be cleared (indicates message was sent)
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for the user message "hi" to appear in the chat
    await expect(leftPane.locator("text=hi")).toBeVisible({ timeout: 5000 });

    // Wait for Claude's response to appear
    // The response appears in a message box with bg-gray-800 containing "Claude" label
    // Strategy: Wait for a message that contains both "Claude" text AND some content beyond just the label
    await expect(async () => {
      // Find all Claude message containers
      const claudeMessages = leftPane.locator("div.bg-gray-800").filter({
        has: page.locator("text=Claude"),
      });

      const count = await claudeMessages.count();
      expect(count).toBeGreaterThan(0);

      // Get the last Claude message (most recent response)
      const lastMessage = claudeMessages.last();
      const messageText = await lastMessage.textContent();

      // Verify it has content beyond just "Claude" and timestamp
      // A real response should have actual text content
      expect(messageText).toBeTruthy();
      // Remove "Claude" label and timestamp (time format like "12:34:56")
      const contentWithoutLabel = messageText!.replace(/Claude/g, "").replace(/\d{2}:\d{2}:\d{2}/g, "").trim();
      expect(contentWithoutLabel.length).toBeGreaterThan(0);
    }).toPass({ timeout: 30000 }); // 30 seconds for real API call

    // Final verification: Get the actual response text
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    const responseText = await claudeMessage.textContent();
    const contentOnly = responseText!.replace(/Claude/g, "").replace(/\d{2}:\d{2}:\d{2}/g, "").trim();

    // Verify we got actual content from Claude
    expect(contentOnly.length).toBeGreaterThan(0);

    // Verify the message persists (doesn't disappear)
    await page.waitForTimeout(2000);
    await expect(claudeMessage).toBeVisible();

    // Verify input is ready for next message
    await expect(chatInput).toHaveValue("");
  });
});
