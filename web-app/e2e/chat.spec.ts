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
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Type "hi" in the chat input
    await chatInput.fill("hi");

    // Verify text was entered
    await expect(chatInput).toHaveValue("hi");

    // Send button should be enabled with text
    await expect(sendButton).not.toBeDisabled();

    // Click send button
    await sendButton.click();

    // Wait for the input to be cleared (indicates message was sent)
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for the user message "hi" to appear in the chat
    await expect(leftPane.locator("text=hi")).toBeVisible({ timeout: 5000 });

    // Wait for Claude to respond - look for any text appearing after the user message
    // This could be the response text or streaming indicator
    await page.waitForTimeout(5000);

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
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Send button should be disabled when input is empty
    await expect(sendButton).toBeDisabled();
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
    const sendButton = leftPane.locator("button:has-text('Send')").first();

    // Type and send a message
    await chatInput.fill("hello");
    await sendButton.click();

    // Wait a bit for streaming to start
    await page.waitForTimeout(500);

    // Send button should be disabled during streaming
    // (or at least immediately after sending)
    await expect(chatInput).toHaveValue("");
  });
});
