import { test, expect } from "@playwright/test";

test.describe("URL Detection Feature", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForSelector("textarea", { timeout: 10000 });
  });

  test("should detect and render URLs with http:// prefix as clickable links", async ({
    page,
  }) => {
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Check out http://example.com for more info"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    await chatInput.fill("test http links");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    // Wait for the content to be fully rendered
    const contentDiv = claudeMessage.locator("div.whitespace-pre-wrap").first();
    await expect(contentDiv).toBeVisible();

    // Wait a bit for the link to be rendered
    await page.waitForTimeout(1000);

    const link = claudeMessage.locator("a[href='http://example.com']");
    await expect(link).toBeVisible({ timeout: 5000 });
    await expect(link).toHaveAttribute("href", "http://example.com");
    await expect(link).toHaveAttribute("target", "_blank");
    await expect(link).toHaveAttribute("rel", "noopener noreferrer");
  });

  test("should detect and render URLs with https:// prefix as clickable links", async ({
    page,
  }) => {
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Visit https://secure-site.com for details"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    await chatInput.fill("test https links");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    const link = claudeMessage.locator("a[href='https://secure-site.com']");
    await expect(link).toBeVisible();
    await expect(link).toHaveAttribute("href", "https://secure-site.com");
    await expect(link).toHaveAttribute("target", "_blank");
    await expect(link).toHaveAttribute("rel", "noopener noreferrer");
  });

  test("should detect and render URLs with www. prefix as clickable links", async ({
    page,
  }) => {
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Go to www.example.org for more"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    await chatInput.fill("test www links");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    const link = claudeMessage.locator("a[href='https://www.example.org']");
    await expect(link).toBeVisible();
    await expect(link).toHaveAttribute("href", "https://www.example.org");
    await expect(link).toHaveAttribute("target", "_blank");
    await expect(link).toHaveAttribute("rel", "noopener noreferrer");

    const linkText = await link.textContent();
    expect(linkText).toBe("www.example.org");
  });

  test("should trim trailing punctuation from URLs", async ({ page }) => {
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Visit https://example.com. Also check https://test.org, and https://another.net!"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    await chatInput.fill("test punctuation trimming");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    const link1 = claudeMessage.locator("a[href='https://example.com']");
    await expect(link1).toBeVisible();
    await expect(link1).toHaveAttribute("href", "https://example.com");

    const link2 = claudeMessage.locator("a[href='https://test.org']");
    await expect(link2).toBeVisible();
    await expect(link2).toHaveAttribute("href", "https://test.org");

    const link3 = claudeMessage.locator("a[href='https://another.net']");
    await expect(link3).toBeVisible();
    await expect(link3).toHaveAttribute("href", "https://another.net");

    const messageText = await claudeMessage.textContent();
    expect(messageText).toContain(".");
    expect(messageText).toContain(",");
    expect(messageText).toContain("!");
  });

  test("should detect multiple URLs in the same message", async ({ page }) => {
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Here are three links: http://first.com and https://second.com and www.third.com"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    await chatInput.fill("test multiple urls");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    const link1 = claudeMessage.locator("a[href='http://first.com']");
    await expect(link1).toBeVisible();
    await expect(link1).toHaveAttribute("target", "_blank");
    await expect(link1).toHaveAttribute("rel", "noopener noreferrer");

    const link2 = claudeMessage.locator("a[href='https://second.com']");
    await expect(link2).toBeVisible();
    await expect(link2).toHaveAttribute("target", "_blank");
    await expect(link2).toHaveAttribute("rel", "noopener noreferrer");

    const link3 = claudeMessage.locator("a[href='https://www.third.com']");
    await expect(link3).toBeVisible();
    await expect(link3).toHaveAttribute("target", "_blank");
    await expect(link3).toHaveAttribute("rel", "noopener noreferrer");

    const allLinks = claudeMessage.locator("a");
    await expect(allLinks).toHaveCount(3);
  });

  test("should not affect regular text without URLs", async ({ page }) => {
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"This is plain text without any links. Just normal content here."}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    await chatInput.fill("test plain text");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    const contentDiv = claudeMessage.locator("div.whitespace-pre-wrap").first();
    await expect(contentDiv).toBeVisible();

    const textContent = await contentDiv.textContent();
    expect(textContent).toContain("This is plain text without any links");

    const links = claudeMessage.locator("a");
    await expect(links).toHaveCount(0);
  });

  test("links should open in new tab with security attributes", async ({
    page,
  }) => {
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Click https://example.com"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    await chatInput.fill("test link security");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    const link = claudeMessage.locator("a").first();
    await expect(link).toBeVisible();

    const target = await link.getAttribute("target");
    expect(target).toBe("_blank");

    const rel = await link.getAttribute("rel");
    expect(rel).toBe("noopener noreferrer");

    const href = await link.getAttribute("href");
    expect(href).toBe("https://example.com");
  });

  test("should handle URLs with paths and query parameters", async ({
    page,
  }) => {
    await page.route("**/api/commands", async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "text/event-stream",
        body: 'data: {"type":"init","model":"claude-sonnet-4-5-20250929"}\n\ndata: {"type":"text","content":"Visit https://example.com/path/to/page?query=test&foo=bar for details"}\n\ndata: {"type":"result","duration_ms":500}\n\ndata: [DONE]\n\n',
      });
    });

    const leftPane = page.locator("main > div > div").first();
    const chatInput = leftPane.locator("textarea").first();

    await chatInput.fill("test complex urls");
    await chatInput.press("Enter");
    await expect(chatInput).toHaveValue("", { timeout: 3000 });

    const claudeMessage = leftPane
      .locator("div.bg-gray-800")
      .filter({ has: page.locator("text=Claude") })
      .last();
    await expect(claudeMessage).toBeVisible({ timeout: 20000 });

    const link = claudeMessage.locator(
      "a[href='https://example.com/path/to/page?query=test&foo=bar']",
    );
    await expect(link).toBeVisible();
    await expect(link).toHaveAttribute(
      "href",
      "https://example.com/path/to/page?query=test&foo=bar",
    );
    await expect(link).toHaveAttribute("target", "_blank");
    await expect(link).toHaveAttribute("rel", "noopener noreferrer");
  });
});
