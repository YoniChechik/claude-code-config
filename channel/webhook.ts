import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { readFileSync, writeFileSync, renameSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'

const PORT_START = 8788
const PORT_END = 8797
const MAX_BODY_SIZE = 1024 * 1024 // 1MB
const REGISTRY = join(homedir(), '.claude_session_id_to_port')

function findClaudePid(): string {
  // Use direct parent PID as registry key. This is the npx/tsx process,
  // whose parent is Claude — all in the right ancestry chain for the
  // LCA-based lookup in notify.sh. Avoids unreliable `ps eww` on macOS.
  return String(process.ppid)
}

const claudePid = findClaudePid()

function readRegistry(): Record<string, number> {
  try { return JSON.parse(readFileSync(REGISTRY, 'utf8')) }
  catch { return {} }
}
function writeRegistry(reg: Record<string, number>) {
  const tmp = REGISTRY + '.tmp.' + process.pid
  writeFileSync(tmp, JSON.stringify(reg, null, 2))
  renameSync(tmp, REGISTRY)
}

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
    let totalSize = 0
    req.on('data', (c: Buffer) => {
      totalSize += c.length
      if (totalSize > MAX_BODY_SIZE) {
        req.destroy(new Error('Body too large'))
        reject(new Error('Body exceeds 1MB limit'))
        return
      }
      chunks.push(c)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString()))
    req.on('error', reject)
  })
}

const httpServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
  req.setTimeout(5000, () => {
    res.writeHead(408, { 'Content-Type': 'text/plain' })
    res.end('timeout')
    req.destroy()
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

let cleanedUp = false

function cleanup() {
  if (cleanedUp) return
  cleanedUp = true
  const reg = readRegistry()
  delete reg[claudePid]
  writeRegistry(reg)
}

function pruneStaleEntries() {
  const reg = readRegistry()
  let changed = false
  for (const pid of Object.keys(reg)) {
    try {
      process.kill(Number(pid), 0)
    } catch {
      delete reg[pid]
      changed = true
    }
  }
  if (changed) writeRegistry(reg)
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
  pruneStaleEntries()
  const port = await findFreePort(PORT_START, PORT_END)
  const reg = readRegistry()
  reg[claudePid] = port
  writeRegistry(reg)
  console.error(`Webhook channel listening on 127.0.0.1:${port}`)
} catch (err) {
  console.error('Failed to start webhook server:', err)
  process.exit(1)
}
