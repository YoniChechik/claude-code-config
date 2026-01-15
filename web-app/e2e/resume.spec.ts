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
    // Send a message to create a session
    const textarea = page.locator("textarea");
    await textarea.fill("Test message for session listing");
    await textarea.press("Enter");

    // Wait for response to complete
    await page.waitForTimeout(2000);

    // Reload page to get fresh session (button only shows when messagesCount === 0)
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });

    // Open the resume modal
    const resumeButton = page.locator('button[title="Resume a previous session"]');
    await resumeButton.click();

    // Wait for modal to appear
    await page.waitForSelector('[data-testid="session-picker-modal"]', {
      timeout: 5000,
    });

    // Wait for sessions to load (loading state should disappear)
    await page.waitForTimeout(1000);

    // Check if sessions are displayed
    const sessionItems = page.locator('[data-testid="session-item"]');
    const sessionCount = await sessionItems.count();

    // Should have at least one session (the one we just created)
    expect(sessionCount).toBeGreaterThan(0);

    // Verify session items have expected content
    const firstSession = sessionItems.first();
    await expect(firstSession).toBeVisible();

    // Session should have message count displayed
    const messageCountText = await firstSession.textContent();
    expect(messageCountText).toContain("messages");
  });

  test("should resume a session when clicking on it", async ({ page }) => {
    // Create a session with a distinct message
    const distinctMessage = `Test resume ${Date.now()}`;
    const textarea = page.locator("textarea");
    await textarea.fill(distinctMessage);
    await textarea.press("Enter");

    // Wait for response to complete
    await page.waitForTimeout(3000);

    // Reload to get fresh start
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
    expect(sessionCount).toBeGreaterThan(0);

    // Click first session
    const firstSession = sessionItems.first();
    await expect(firstSession).toBeVisible();
    await firstSession.click();

    // Modal should close after selection
    await page.waitForTimeout(1000);
    const modal = page.locator('[data-testid="session-picker-modal"]');
    const isVisible = await modal.isVisible().catch(() => false);
    expect(isVisible).toBe(false);
  });
});
