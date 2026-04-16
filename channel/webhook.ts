import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { watch, readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { homedir } from 'node:os'

// External scripts (e.g. CI watcher) write messages here, one per line.
// The MCP server watches the file and relays each line as a channel notification.
const INBOX = join(homedir(), '.claude', 'channel', 'inbox')

const mcp = new Server(
  { name: 'webhook', version: '1.0.0' },
  {
    capabilities: { tools: {}, experimental: { 'claude/channel': {} } },
    instructions:
      'Events from the webhook channel arrive as <channel source="webhook" ...>. ' +
      'They are one-way: read them and act, no reply expected.',
  },
)

await mcp.connect(new StdioServerTransport())

// --- MCP tool: notify ---
// Exposes a "notify" tool so any Claude session with this MCP can send
// a channel notification directly via tool call (no shell/curl needed).

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'notify',
      description: 'Send a message to the webhook channel as a notification.',
      inputSchema: {
        type: 'object' as const,
        properties: {
          message: { type: 'string', description: 'The message to send to the channel' },
        },
        required: ['message'],
      },
    },
  ],
}))

mcp.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name === 'notify') {
    const message = (request.params.arguments as { message: string })?.message ?? ''
    await mcp.notification({
      method: 'notifications/claude/channel',
      params: {
        content: message,
        meta: { source: 'mcp-tool' },
      },
    })
    return { content: [{ type: 'text', text: 'Notification sent.' }] }
  }
  throw new Error(`Unknown tool: ${request.params.name}`)
})

// --- Inbox file watcher ---
// Ensure the inbox file and its parent directory exist.
mkdirSync(dirname(INBOX), { recursive: true })
if (!existsSync(INBOX)) {
  writeFileSync(INBOX, '')
}

// Debounce guard: fs.watch can fire multiple times for a single write.
// We use a flag to skip duplicate reads within a short window.
let inboxProcessing = false

watch(INBOX, async () => {
  if (inboxProcessing) return
  inboxProcessing = true
  // Small delay to let the writer finish flushing
  setTimeout(async () => {
    try {
      if (!existsSync(INBOX)) return
      const content = readFileSync(INBOX, 'utf8')
      if (!content.trim()) return

      const lines = content.split('\n').filter((line) => line.trim() !== '')
      for (const line of lines) {
        await mcp.notification({
          method: 'notifications/claude/channel',
          params: {
            content: line,
            meta: { source: 'inbox' },
          },
        })
      }

      // Truncate the inbox after processing all lines
      writeFileSync(INBOX, '')
    } catch {
      // File may have been deleted or is unreadable — ignore gracefully
    } finally {
      inboxProcessing = false
    }
  }, 50)
})
