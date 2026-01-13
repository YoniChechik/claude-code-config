import { test, expect } from "@playwright/test";

test("debug - see what's in the DOM", async ({ page }) => {
  await page.goto("http://localhost:3000/");

  // Wait for chat interface
  await page.waitForSelector("textarea, input[type='text']", {
    timeout: 10000,
  });

  const leftPane = page.locator("main > div > div").first();
  const chatInput = leftPane.locator("textarea, input[type='text']").first();
  const sendButton = leftPane.locator("button:has-text('Send')").first();

  // Type and send
  await chatInput.fill("hi");
  await sendButton.click();

  // Wait for input to clear
  await expect(chatInput).toHaveValue("", { timeout: 3000 });

  // Wait a bit more for streaming
  await page.waitForTimeout(10000);

  // Print all divs
  const allDivs = leftPane.locator("div");
  const divCount = await allDivs.count();
  console.log(`Total divs in left pane: ${divCount}`);

  // Look for text content
  const allText = await leftPane.textContent();
  console.log("Left pane text content:");
  console.log(allText);

  // Look for specific elements
  const claudeLabels = leftPane.locator("text=Claude");
  console.log(`Claude labels found: ${await claudeLabels.count()}`);

  const youLabels = leftPane.locator("text=You");
  console.log(`You labels found: ${await youLabels.count()}`);

  // Look for Claude's response message container
  const claudeMessages = leftPane.locator("div.bg-gray-100");
  console.log(`Claude message containers found: ${await claudeMessages.count()}`);

  // Try to get the last message's content
  const lastMessage = claudeMessages.last();
  const lastMessageText = await lastMessage.textContent();
  console.log("Last message text:");
  console.log(lastMessageText);

  // Check the whitespace-pre-wrap div specifically
  const contentDiv = lastMessage.locator("div.whitespace-pre-wrap");
  const contentDivText = await contentDiv.textContent();
  console.log("Content div text (whitespace-pre-wrap):");
  console.log(contentDivText);
  console.log("Content div text length:", contentDivText?.length);
});
