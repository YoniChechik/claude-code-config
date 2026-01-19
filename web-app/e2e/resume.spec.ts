import { test, expect } from "@playwright/test";

test.describe("Resume button", () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to the app
    await page.goto("/");

    // Wait for the chat input to be ready
    await page.waitForSelector("textarea", { timeout: 10000 });
  });

  test("should open SessionPicker modal when resume button is clicked", async ({
    page,
  }) => {
    // Wait for page to be ready
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Find the resume button (📂 icon) in the session header
    const resumeButton = page.locator('button[title="Resume a previous session"]');

    // Verify button is visible
    await expect(resumeButton).toBeVisible();

    // Click the resume button
    await resumeButton.click();

    // Wait for the modal to appear
    await page.waitForSelector('[data-testid="session-picker-modal"]', {
      timeout: 5000,
    });

    // Verify modal is visible
    const modal = page.locator('[data-testid="session-picker-modal"]');
    await expect(modal).toBeVisible();

    // Verify header text
    const header = page.locator('[data-testid="session-picker-header"]');
    await expect(header).toHaveText("Resume Session");
  });

  test("should close modal when cancel is clicked from resume button flow", async ({
    page,
  }) => {
    // Wait for page to be ready
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Find and click the resume button
    const resumeButton = page.locator('button[title="Resume a previous session"]');
    await resumeButton.click();

    // Wait for modal to appear
    await page.waitForSelector('[data-testid="session-picker-modal"]', {
      timeout: 5000,
    });

    // Verify modal is visible
    const modal = page.locator('[data-testid="session-picker-modal"]');
    await expect(modal).toBeVisible();

    // Click Cancel button
    const cancelButton = page.locator('[data-testid="cancel-button"]');
    await cancelButton.click();

    // Modal should close
    await page.waitForTimeout(300);

    // Modal should not be visible
    const isVisible = await modal.isVisible().catch(() => false);
    expect(isVisible).toBe(false);
  });

  test("should list saved sessions in the modal", async ({ page }) => {
    // Mock the sessions/recent API to return test sessions
    await page.route("**/api/sessions/recent**", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          sessions: [
            {
              id: "test-session-1",
              cwd: "/home/test",
              createdAt: new Date().toISOString(),
              lastActivityAt: new Date().toISOString(),
              messageCount: 5,
              firstMessagePreview: "Test message for session listing",
              lastMessagePreview: "Last test message",
              filePath: "/path/to/session.jsonl",
            },
            {
              id: "test-session-2",
              cwd: "/home/test2",
              createdAt: new Date(Date.now() - 3600000).toISOString(),
              lastActivityAt: new Date(Date.now() - 3600000).toISOString(),
              messageCount: 3,
              firstMessagePreview: "Another test session",
              lastMessagePreview: "Another last message",
              filePath: "/path/to/session2.jsonl",
            },
          ],
        }),
      });
    });

    // Navigate to the app
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Open the resume modal
    const resumeButton = page.locator('button[title="Resume a previous session"]');
    await resumeButton.click();

    // Wait for modal to appear
    await page.waitForSelector('[data-testid="session-picker-modal"]', {
      timeout: 5000,
    });

    // Wait for sessions to load
    await page.waitForTimeout(1000);

    // Check if sessions are displayed
    const sessionItems = page.locator('[data-testid="session-item"]');
    const sessionCount = await sessionItems.count();

    // Should have the 2 mocked sessions
    expect(sessionCount).toBe(2);

    // Verify session items have expected content
    const firstSession = sessionItems.first();
    await expect(firstSession).toBeVisible();

    // Session should have message count displayed
    const messageCountText = await firstSession.textContent();
    expect(messageCountText).toContain("messages");
  });

  test("should resume a session when clicking on it", async ({ page }) => {
    const testSessionId = "test-resume-session-123";
    const testFilePath = "/test/path/session.jsonl";
    const testCwd = "/home/test";
    const testMessages = [
      {
        role: "user",
        content: [{ type: "text", text: "Hello from previous session" }],
        timestamp: new Date().toISOString(),
      },
      {
        role: "assistant",
        content: [{ type: "text", text: "Hi! This is a resumed message." }],
        timestamp: new Date().toISOString(),
      },
    ];

    // Mock the sessions/recent API
    await page.route("**/api/sessions/recent**", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          sessions: [
            {
              id: testSessionId,
              cwd: testCwd,
              createdAt: new Date().toISOString(),
              lastActivityAt: new Date().toISOString(),
              messageCount: 5,
              firstMessagePreview: "Test resume session",
              lastMessagePreview: "Last message",
              filePath: testFilePath,
            },
          ],
        }),
      });
    });

    // Mock the session resume API
    await page.route("**/api/sessions/resume", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          session: {
            id: testSessionId,
            cwd: testCwd,
            messages: testMessages,
            windowId: "test-window",
            model: "claude-sonnet-4-5-20250929",
            lastDurationMs: 0,
            createdAt: new Date().toISOString(),
            isResumed: true,
            audioNotificationsEnabled: true,
            includePartialMessages: true,
          },
        }),
      });
    });

    // Mock the session GET API to return the resumed session
    await page.route(`**/api/sessions/${testSessionId}`, async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          session: {
            id: testSessionId,
            cwd: testCwd,
            messages: testMessages,
            windowId: "test-window",
            model: "claude-sonnet-4-5-20250929",
            lastDurationMs: 0,
            createdAt: new Date().toISOString(),
            isResumed: true,
            audioNotificationsEnabled: true,
            includePartialMessages: true,
          },
        }),
      });
    });

    // Navigate to the app
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Open resume modal
    const resumeButton = page.locator('button[title="Resume a previous session"]');
    await expect(resumeButton).toBeVisible();
    await resumeButton.click();

    // Wait for modal and sessions to load
    await page.waitForSelector('[data-testid="session-picker-modal"]', {
      timeout: 5000,
    });
    await page.waitForTimeout(1000);

    // Verify we have sessions
    const sessionItems = page.locator('[data-testid="session-item"]');
    const sessionCount = await sessionItems.count();
    expect(sessionCount).toBe(1);

    // Click first session
    const firstSession = sessionItems.first();
    await expect(firstSession).toBeVisible();
    await firstSession.click();

    // Modal should close after selection
    await page.waitForTimeout(1000);
    const modal = page.locator('[data-testid="session-picker-modal"]');
    const isVisible = await modal.isVisible().catch(() => false);
    expect(isVisible).toBe(false);

    // Verify the session messages are actually loaded and displayed
    await page.waitForTimeout(1000);

    // Check for user message
    const userMessage = page.locator('text="Hello from previous session"');
    await expect(userMessage).toBeVisible({ timeout: 5000 });

    // Check for assistant message
    const assistantMessage = page.locator('text="Hi! This is a resumed message."');
    await expect(assistantMessage).toBeVisible({ timeout: 5000 });

    // Verify cwd is updated in the header
    const cwdButton = page.locator(`button:has-text("${testCwd}")`);
    await expect(cwdButton).toBeVisible({ timeout: 5000 });
  });
});
