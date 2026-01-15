import { test, expect } from "@playwright/test";

test.describe("Error Handling", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });
  });

  test("should handle API errors gracefully when creating session", async ({
    page,
  }) => {
    await page.route("**/api/sessions", async (route) => {
      await route.fulfill({
        status: 500,
        contentType: "application/json",
        body: JSON.stringify({ error: "Internal Server Error" }),
      });
    });

    await page.reload();
    await page.waitForTimeout(2000);

    const errorModal = page.locator('[role="dialog"]');
    await expect(errorModal).toBeVisible({ timeout: 5000 });
  });

  test("should handle network timeout when sending command", async ({
    page,
  }) => {
    await page.route("**/api/commands", async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 10000));
      await route.abort("timedout");
    });

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("test command");
    await input.press("Enter");

    const errorIndicator = page.locator("text=/error|failed/i");
    await expect(errorIndicator).toBeVisible({ timeout: 15000 });
  });

  test("should handle malformed JSON responses", async ({ page }) => {
    await page.route("**/api/sessions", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: "not valid json {",
      });
    });

    await page.reload();
    await page.waitForTimeout(2000);

    const errorModal = page.locator('[role="dialog"]');
    await expect(errorModal).toBeVisible({ timeout: 5000 });
  });

  test("should recover from failed session creation", async ({ page }) => {
    let callCount = 0;

    await page.route("**/api/sessions", async (route) => {
      callCount++;
      if (callCount === 1) {
        await route.fulfill({
          status: 500,
          contentType: "application/json",
          body: JSON.stringify({ error: "Server error" }),
        });
      } else {
        await route.continue();
      }
    });

    await page.reload();
    await page.waitForTimeout(2000);

    await page.reload();
    await page.waitForTimeout(2000);

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await expect(input).toBeVisible();
  });

  test("should handle session not found error", async ({ page }) => {
    await page.route("**/api/sessions/*", async (route) => {
      if (route.request().method() === "GET") {
        await route.fulfill({
          status: 404,
          contentType: "application/json",
          body: JSON.stringify({ error: "Session not found" }),
        });
      } else {
        await route.continue();
      }
    });

    const errorModal = page.locator('[role="dialog"]');
    await expect(errorModal).toBeVisible({ timeout: 5000 });
  });

  test("should show error when command stream fails", async ({ page }) => {
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"error","error":"Command execution failed"}\n\n',
      });
    });

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("test command");
    await input.press("Enter");

    const errorText = page.locator("text=/error|failed/i");
    await expect(errorText).toBeVisible({ timeout: 5000 });
  });

  test("should handle broken SSE stream", async ({ page }) => {
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"text","content":"Starting..."}\n\nINVALID_DATA\n\n',
      });
    });

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("test command");
    await input.press("Enter");

    const messages = page.locator(".message-content");
    await expect(messages).toHaveCount(1, { timeout: 5000 });
  });

  test("should handle invalid session ID in commands", async ({ page }) => {
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 404,
        contentType: "application/json",
        body: JSON.stringify({ error: "Session not found" }),
      });
    });

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("test command");
    await input.press("Enter");

    const errorIndicator = page.locator("text=/error|not found/i");
    await expect(errorIndicator).toBeVisible({ timeout: 5000 });
  });

  test("should display error modal with details", async ({ page }) => {
    await page.route("**/api/sessions", async (route) => {
      await route.fulfill({
        status: 500,
        contentType: "application/json",
        body: JSON.stringify({
          error: "Database connection failed",
          details: "Unable to connect to session storage",
        }),
      });
    });

    await page.reload();
    await page.waitForTimeout(2000);

    const errorModal = page.locator('[role="dialog"]');
    await expect(errorModal).toBeVisible();

    const errorDetails = errorModal.locator(
      "text=/Database connection failed/i",
    );
    await expect(errorDetails).toBeVisible();
  });

  test("should allow dismissing error modal", async ({ page }) => {
    await page.route("**/api/sessions", async (route) => {
      await route.fulfill({
        status: 500,
        contentType: "application/json",
        body: JSON.stringify({ error: "Test error" }),
      });
    });

    await page.reload();
    await page.waitForTimeout(2000);

    const errorModal = page.locator('[role="dialog"]');
    await expect(errorModal).toBeVisible();

    const closeButton = errorModal.locator("button", {
      hasText: /close|dismiss|ok/i,
    });

    if ((await closeButton.count()) > 0) {
      await closeButton.click();
      await expect(errorModal).not.toBeVisible();
    }
  });
});

test.describe("Network Failures", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });
  });

  test("should handle complete network failure", async ({ page }) => {
    await page.route("**/*", async (route) => {
      await route.abort("failed");
    });

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("test command");
    await input.press("Enter");

    const errorIndicator = page.locator("text=/error|failed|network/i");
    await expect(errorIndicator).toBeVisible({ timeout: 10000 });
  });

  test("should handle intermittent network failures", async ({ page }) => {
    let requestCount = 0;

    await page.route("**/api/commands", async (route) => {
      requestCount++;
      if (requestCount % 2 === 0) {
        await route.abort("failed");
      } else {
        await route.continue();
      }
    });

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("test command");
    await input.press("Enter");

    await page.waitForTimeout(2000);
  });

  test("should handle slow network responses", async ({ page }) => {
    await page.route("**/api/commands", async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 5000));
      await route.continue();
    });

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("test command");
    await input.press("Enter");

    await page.waitForTimeout(1000);

    const progressIndicator = page.locator('[role="progressbar"]');
    await expect(progressIndicator).toBeVisible();
  });

  test("should handle connection reset", async ({ page }) => {
    await page.route("**/api/commands", async (route) => {
      await route.abort("connectionreset");
    });

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("test command");
    await input.press("Enter");

    const errorIndicator = page.locator("text=/error|failed/i");
    await expect(errorIndicator).toBeVisible({ timeout: 5000 });
  });

  test("should handle DNS resolution failure", async ({ page }) => {
    await page.route("**/api/commands", async (route) => {
      await route.abort("namenotresolved");
    });

    const input = page.locator('textarea[placeholder*="Type a command"]');
    await input.fill("test command");
    await input.press("Enter");

    const errorIndicator = page.locator("text=/error|failed/i");
    await expect(errorIndicator).toBeVisible({ timeout: 5000 });
  });
});
