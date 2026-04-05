import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { writeFileSync, unlinkSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'

const PORT_START = 8788
const PORT_END = 8797
const SESSIONS_DIR = join(homedir(), '.claude', 'sessions')
const PPID = process.ppid
const PORT_FILE = join(SESSIONS_DIR, `${PPID}.port`)

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

function cleanup() {
  try {
    unlinkSync(PORT_FILE)
  } catch {
    // file may already be gone
  }
}

process.on('SIGTERM', () => {
  cleanup()
  process.exit(0)
})

process.on('SIGINT', () => {
  cleanup()
  process.exit(0)
})

process.on('exit', () => {
  cleanup()
})

async function findFreePort(start: number, end: number): Promise<number> {
  for (let port = start; port <= end; port++) {
    try {
      await new Promise<void>((resolve, reject) => {
        httpServer.listen(port, '127.0.0.1', () => resolve())
        httpServer.once('error', reject)
      })
      return port
    } catch (err: unknown) {
      const nodeErr = err as NodeJS.ErrnoException
      if (nodeErr.code === 'EADDRINUSE') {
        continue
      }
      throw err
    }
  }
  throw new Error(`No free port found in range ${start}-${end}`)
}

try {
  const port = await findFreePort(PORT_START, PORT_END)
  mkdirSync(SESSIONS_DIR, { recursive: true })
  writeFileSync(PORT_FILE, String(port))
  console.error(`Webhook channel listening on 127.0.0.1:${port}`)
} catch (err) {
  console.error('Failed to start webhook server:', err)
  process.exit(1)
}
