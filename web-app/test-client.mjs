import { spawn } from "child_process";

const args = [
  "-p",
  "hi",
  "--output-format",
  "stream-json",
  "--json-schema",
  JSON.stringify({
    type: "object",
    properties: {
      cwd: { type: "string" },
      response: { type: "string" },
    },
    required: ["cwd", "response"],
  }),
  "--verbose",
];

console.log("Running claude with args:", args);

const claude = spawn("claude", args, {
  stdio: ["pipe", "pipe", "pipe"],
});

claude.stdin.end();

let outputBuffer = "";
let errorBuffer = "";

claude.stdout.on("data", (chunk) => {
  outputBuffer += chunk.toString();
  const lines = outputBuffer.split("\n");
  outputBuffer = lines.pop() || "";

  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const event = JSON.parse(line);
      if (event.type === "assistant") {
        console.log("ASSISTANT MESSAGE:");
        console.log(JSON.stringify(event.message.content, null, 2));
      }
      if (event.type === "result") {
        console.log("RESULT:", event.structured_output);
      }
    } catch (e) {
      // console.error("Parse error:", e.message);
    }
  }
});

claude.stderr.on("data", (chunk) => {
  errorBuffer += chunk.toString();
  console.error("STDERR:", chunk.toString());
});

claude.on("close", (code) => {
  console.log("Exit code:", code);
  if (errorBuffer) {
    console.error("Full error:", errorBuffer);
  }
});

claude.on("error", (err) => {
  console.error("Process error:", err);
});

setTimeout(() => {
  console.log("Timeout - killing process");
  claude.kill();
  process.exit(1);
}, 15000);
