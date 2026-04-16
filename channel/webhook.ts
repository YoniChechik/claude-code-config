import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { createServer, IncomingMessage, ServerResponse } from 'node:http'
import { randomUUID } from 'node:crypto'

const sessionToken = randomUUID()
process.stdin.on('end', () => process.exit(0))
process.stdin.on('close', () => process.exit(0))

// --- MCP Server ---
// Created first so it's available when the HTTP handler references it.
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

// --- MCP Tools ---
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
    {
      name: 'get_port',
      description:
        'Returns the HTTP port this webhook session is listening on. Pass this to external scripts so they can curl messages to this session.',
      inputSchema: {
        type: 'object' as const,
        properties: {},
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

  if (request.params.name === 'get_port') {
    return { content: [{ type: 'text', text: `${httpPort}:${sessionToken}` }] }
  }

  throw new Error(`Unknown tool: ${request.params.name}`)
})

// --- HTTP Server ---
// Minimal HTTP server on localhost for receiving webhook messages from external scripts.
let httpPort = 0

const httpServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200)
    res.end('ok:' + sessionToken)
    return
  }

  if (req.method === 'POST' && req.url === '/') {
    const chunks: Buffer[] = []
    let size = 0
    const MAX_BODY = 1024 * 1024 // 1 MB

    for await (const chunk of req) {
      size += (chunk as Buffer).length
      if (size > MAX_BODY) {
        res.writeHead(413)
        res.end('body too large')
        return
      }
      chunks.push(chunk as Buffer)
    }

    const body = Buffer.concat(chunks).toString('utf8')

    await mcp.notification({
      method: 'notifications/claude/channel',
      params: {
        content: body,
        meta: { source: 'http' },
      },
    })

    res.writeHead(200)
    res.end('ok')
    return
  }

  res.writeHead(404)
  res.end('not found')
})

// Listen on an OS-assigned free port on localhost
httpServer.listen(0, '127.0.0.1', () => {
  const addr = httpServer.address()
  if (addr && typeof addr !== 'string') {
    httpPort = addr.port
  }
  console.error(`Webhook HTTP listening on 127.0.0.1:${httpPort}`)
})
