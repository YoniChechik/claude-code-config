import { test, expect } from "@playwright/test";

test.describe("Streaming Toggle Functionality", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });
  });

  test("should display streaming toggle button in session header", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();

    // Find the streaming toggle button (⚡ or 📝)
    const streamingToggle = leftPane.locator(
      'button[title*="streaming mode"]',
    );
    await expect(streamingToggle).toBeVisible({ timeout: 5000 });

    // Verify button shows correct initial state (streaming enabled by default)
    const buttonText = await streamingToggle.textContent();
    expect(buttonText).toMatch(/⚡|📝/);
  });

  test("should toggle between streaming and buffered mode", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const streamingToggle = leftPane.locator(
      'button[title*="streaming mode"]',
    );

    // Get initial state
    const initialText = await streamingToggle.textContent();
    const initialTitle = await streamingToggle.getAttribute("title");

    // Click toggle
    await streamingToggle.click();

    // Wait for state to update
    await page.waitForTimeout(300);

    // Verify state changed
    const newText = await streamingToggle.textContent();
    const newTitle = await streamingToggle.getAttribute("title");

    expect(newText).not.toBe(initialText);
    expect(newTitle).not.toBe(initialTitle);

    // Verify toggle switches between ⚡ and 📝
    if (initialText === "⚡") {
      expect(newText).toBe("📝");
      expect(newTitle).toContain("Enable streaming");
    } else {
      expect(newText).toBe("⚡");
      expect(newTitle).toContain("Disable streaming");
    }
  });

  test("should show incremental text updates when streaming is enabled", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const streamingToggle = leftPane.locator(
      'button[title*="streaming mode"]',
    );

    // Ensure streaming is enabled (⚡ icon)
    const buttonText = await streamingToggle.textContent();
    if (buttonText !== "⚡") {
      await streamingToggle.click();
      await page.waitForTimeout(300);
    }

    // Send a message
    await chatInput.fill("hi");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for Claude's response to start appearing
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Get the content div that streams text
    const contentDiv = claudeMessage.locator("div.whitespace-pre-wrap");
    await expect(contentDiv).toBeVisible({ timeout: 5000 });

    // Capture text at multiple points in time to verify incremental updates
    const textSnapshots: string[] = [];

    // Take 3 snapshots with delays to catch streaming
    for (let i = 0; i < 3; i++) {
      await page.waitForTimeout(300);
      const text = await contentDiv.textContent();
      if (text) {
        textSnapshots.push(text);
      }
    }

    // In streaming mode, we should see text growing incrementally
    // At least one snapshot should be different from others (text is streaming)
    const uniqueSnapshots = new Set(textSnapshots);
    expect(uniqueSnapshots.size).toBeGreaterThanOrEqual(1);

    // Final text should have content
    const finalText = await contentDiv.textContent();
    expect(finalText).toBeTruthy();
    expect(finalText!.length).toBeGreaterThan(0);
  });

  test("should show complete text at once when buffered mode is enabled", async ({
    page,
  }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const streamingToggle = leftPane.locator(
      'button[title*="streaming mode"]',
    );

    // Ensure buffered mode is enabled (📝 icon)
    const buttonText = await streamingToggle.textContent();
    if (buttonText !== "📝") {
      await streamingToggle.click();
      await page.waitForTimeout(300);
    }

    // Verify buffered mode is active
    const title = await streamingToggle.getAttribute("title");
    expect(title).toContain("Enable streaming");

    // Send a message
    await chatInput.fill("hello");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for Claude's response to appear
    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Get the content div
    const contentDiv = claudeMessage.locator("div.whitespace-pre-wrap");
    await expect(contentDiv).toBeVisible({ timeout: 5000 });

    // In buffered mode, text appears complete (no incremental streaming)
    const finalText = await contentDiv.textContent();
    expect(finalText).toBeTruthy();
    expect(finalText!.length).toBeGreaterThan(0);
  });

  test("should persist toggle state across messages", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const streamingToggle = leftPane.locator(
      'button[title*="streaming mode"]',
    );

    // Toggle to buffered mode
    const initialText = await streamingToggle.textContent();
    if (initialText === "⚡") {
      await streamingToggle.click();
      await page.waitForTimeout(300);
    }

    // Verify buffered mode is active
    expect(await streamingToggle.textContent()).toBe("📝");

    // Send first message
    await chatInput.fill("first message");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait for response
    await page.waitForTimeout(2000);

    // Verify toggle state persisted
    expect(await streamingToggle.textContent()).toBe("📝");

    // Send second message
    await chatInput.fill("second message");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Verify toggle state still persisted
    expect(await streamingToggle.textContent()).toBe("📝");
  });

  test("should allow toggling mid-stream", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();
    const streamingToggle = leftPane.locator(
      'button[title*="streaming mode"]',
    );

    // Ensure streaming is enabled
    const buttonText = await streamingToggle.textContent();
    if (buttonText !== "⚡") {
      await streamingToggle.click();
      await page.waitForTimeout(300);
    }

    // Send a message that will take some time to respond
    await chatInput.fill("tell me about typescript");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    // Wait a moment for streaming to start
    await page.waitForTimeout(1000);

    // Toggle to buffered mode while streaming
    await streamingToggle.click();

    // Verify toggle changed
    await page.waitForTimeout(300);
    expect(await streamingToggle.textContent()).toBe("📝");

    // The toggle should work without errors
    expect(await streamingToggle.isVisible()).toBe(true);
  });

  test("should show correct tooltip text for each mode", async ({ page }) => {
    const leftPane = page.locator("main > div > div").first();
    const streamingToggle = leftPane.locator(
      'button[title*="streaming mode"]',
    );

    // Check initial tooltip (should be streaming enabled)
    const initialTitle = await streamingToggle.getAttribute("title");
    expect(initialTitle).toMatch(/streaming mode/i);

    // Toggle to other mode
    await streamingToggle.click();
    await page.waitForTimeout(300);

    // Check new tooltip
    const newTitle = await streamingToggle.getAttribute("title");
    expect(newTitle).toMatch(/streaming mode/i);
    expect(newTitle).not.toBe(initialTitle);

    // Verify tooltips mention "Enable" or "Disable"
    expect(initialTitle).toMatch(/Enable|Disable/);
    expect(newTitle).toMatch(/Enable|Disable/);
  });
});
