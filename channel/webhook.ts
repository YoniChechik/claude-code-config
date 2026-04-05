import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'

const mcp = new Server(
  { name: 'webhook', version: '1.0.0' },
  {
    capabilities: { experimental: { 'claude/channel': {} } },
    instructions:
      'Events from the webhook channel arrive as <channel source="webhook" ...>. ' +
      'They are one-way: read them and act, no reply expected.',
  },
)

await mcp.connect(new StdioServerTransport())

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    req.on('data', (c: Buffer) => chunks.push(c))
    req.on('end', () => resolve(Buffer.concat(chunks).toString()))
    req.on('error', reject)
  })
}

const httpServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
  req.setTimeout(5000, () => {
    res.writeHead(408, { 'Content-Type': 'text/plain' })
    res.end('timeout')
  })

  const path = req.url ?? '/'
  const method = req.method ?? 'GET'

  if (method === 'GET' && path === '/health') {
    res.writeHead(200, { 'Content-Type': 'text/plain' })
    res.end('ok')
    return
  }

  if (method === 'POST') {
    try {
      const body = await readBody(req)
      await mcp.notification({
        method: 'notifications/claude/channel',
        params: {
          content: body,
          meta: { path, method },
        },
      })
      res.writeHead(200, { 'Content-Type': 'text/plain' })
      res.end('ok')
    } catch (err) {
      console.error('POST handler error:', err)
      res.writeHead(500, { 'Content-Type': 'text/plain' })
      res.end('Internal Server Error')
    }
    return
  }

  res.writeHead(405, { 'Content-Type': 'text/plain' })
  res.end('Method Not Allowed')
})

httpServer.on('error', (err: NodeJS.ErrnoException) => {
  if (err.code === 'EADDRINUSE') {
    console.error('ERROR: Port 8788 is already in use. Is another instance running?')
  } else {
    console.error('HTTP server error:', err)
  }
  process.exit(1)
})

httpServer.listen(8788, '127.0.0.1', () => {
  console.error('Webhook channel listening on 127.0.0.1:8788')
})
