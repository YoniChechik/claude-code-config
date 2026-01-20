import { test, expect } from "@playwright/test";

test.describe("Production Build - Working Server", () => {
  test("should serve production build without build errors", async ({ page }) => {
    const response = await page.goto("/");

    expect(response?.status()).toBe(200);

    const title = await page.title();
    expect(title).not.toContain("500");
    expect(title).not.toContain("Application error");

    const pageContent = await page.content();
    expect(pageContent).not.toContain("Internal Server Error");
    expect(pageContent).toContain("ccweb");
  });

  test("should load JavaScript without errors", async ({ page }) => {
    const consoleErrors: string[] = [];
    page.on("console", (msg) => {
      if (msg.type() === "error") {
        consoleErrors.push(msg.text());
      }
    });

    const response = await page.goto("/");
    expect(response?.status()).toBe(200);

    await page.waitForTimeout(2000);

    const criticalErrors = consoleErrors.filter((err) =>
      err.includes("Failed to fetch") ||
      err.includes("NetworkError") ||
      err.includes("TypeError") ||
      err.includes("SyntaxError")
    );

    expect(criticalErrors.length).toBe(0);
  });

  test("should render application UI elements", async ({ page }) => {
    await page.goto("/");

    const mainElement = page.locator("main");
    await expect(mainElement).toBeVisible({ timeout: 5000 });

    const hasInitializingText = await page.getByText(/Initializing sessions/i).isVisible().catch(() => false);
    const hasErrorAlert = await page.locator('[role="alert"]').isVisible().catch(() => false);

    expect(hasInitializingText || hasErrorAlert).toBe(true);
  });

  test("should load Next.js chunks successfully", async ({ page }) => {
    const failedRequests: string[] = [];

    page.on("requestfailed", (request) => {
      failedRequests.push(`${request.url()}: ${request.failure()?.errorText}`);
    });

    await page.goto("/");

    await page.waitForLoadState("networkidle", { timeout: 10000 });

    const criticalFailed = failedRequests.filter((req) =>
      req.includes("/_next/static/chunks/")
    );

    expect(criticalFailed.length).toBe(0);
  });

  test("should have correct production build configuration", async ({ page }) => {
    const response = await page.goto("/");

    expect(response?.status()).toBe(200);

    const pageContent = await page.content();

    expect(pageContent).toContain("/_next/static/chunks/");

    expect(pageContent).not.toContain("webpack-hmr");
    expect(pageContent).not.toContain("webpack-internal://");
  });
});
