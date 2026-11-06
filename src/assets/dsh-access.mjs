// Based on spark by Massimo Angelini - https://github.com/massimo92/spark
import { spawn } from 'node:child_process'
import { lstatSync, readFileSync, unlinkSync } from 'node:fs'
import http from 'node:http'
import https from 'node:https'

const [socketPath, launchLog, port, publicUrl, cert, users, ...dshCommand] = process.argv.slice(2)
const { host, origin } = new URL(publicUrl)
const allowedUsers = new Set(users.split(',').filter(Boolean))
const backend = { hostname: '127.0.0.1', port, ca: readFileSync(cert), servername: 'localhost' }
const hopHeaders = ['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'proxy-connection', 'te', 'trailer', 'transfer-encoding', 'upgrade']
let launchPath
let session
let refreshing

function forwardedHeaders(headers) {
  const hop = new Set([...hopHeaders, ...(headers.connection ?? '').toLowerCase().split(/\s*,\s*/)])
  return Object.fromEntries(Object.entries(headers).filter(([name]) =>
    !hop.has(name) && !name.startsWith('tailscale-') && !name.startsWith('x-forwarded-') &&
    !['forwarded', 'authorization', 'cookie', 'set-cookie'].includes(name)))
}

function startSession() {
  if (!launchPath) {
    const prefix = `dsh web: ${origin}/?token=`
    const token = readFileSync(launchLog, 'utf8').split('\n')
      .find(line => line.startsWith(prefix))?.slice(prefix.length).trim().split(/\s+/)[0]
    if (!/^[A-Za-z0-9_.~-]+$/.test(token ?? '')) throw new Error('Invalid DSH launch URL')
    launchPath = `/?token=${token}`
  }
  return new Promise((resolve, reject) => {
    const request = https.get({ ...backend, path: launchPath, headers: { host } }, response => {
      response.resume()
      const [cookie] = response.headers['set-cookie'] ?? []
      const match = cookie?.match(/^([A-Za-z0-9._~-]+=[A-Za-z0-9._~%=-]+);/)
      const maxAge = Number(cookie?.match(/;\s*Max-Age=(\d+)/i)?.[1])
      if (response.statusCode !== 303 || !match || !maxAge || !/;\s*Secure(?:;|$)/i.test(cookie)) {
        reject(new Error('DSH did not issue a secure session'))
        return
      }
      resolve({ cookie: match[1], expires: Date.now() + Math.min(maxAge / 2, 3600) * 1000 })
    })
    request.setTimeout(4000, () => request.destroy())
    request.on('error', reject)
  })
}

async function upstreamHeaders(request) {
  if (!session || session.expires <= Date.now()) {
    refreshing ??= Promise.resolve().then(startSession).finally(() => { refreshing = undefined })
    session = await refreshing
  }
  return { ...forwardedHeaders(request.headers), host, cookie: session.cookie }
}

function authorized(request, upgrade = false) {
  const headers = request.headers
  // The socket is private to tailscaled and the Spark account. Serve clears
  // caller-supplied identity headers and supplies the actual tailnet identity.
  if (!allowedUsers.has(headers['tailscale-user-login']) || headers['tailscale-funnel-request'] ||
      headers['x-forwarded-host'] !== host || headers['x-forwarded-proto'] !== 'https' ||
      !request.url.startsWith('/') || request.url.startsWith('//')) return false
  const url = URL.parse(request.url, origin)
  if (!url || url.origin !== origin || url.searchParams.has('token')) return false
  if (upgrade || !['GET', 'HEAD'].includes(request.method) || headers.origin) {
    return headers.origin === origin
  }
  return headers['sec-fetch-site'] !== 'cross-site' ||
    (headers['sec-fetch-mode'] === 'navigate' && url.pathname === '/')
}

function unavailable(response) {
  if (response.headersSent) response.destroy()
  else response.writeHead(502, { 'cache-control': 'no-store' }).end('DSH is starting or unavailable')
}

const server = http.createServer(async (request, response) => {
  if (!authorized(request)) {
    response.writeHead(403, { 'cache-control': 'no-store', 'x-spark-dsh-access': 'denied' })
    response.end('DSH requires an authorized Tailscale user')
    return
  }
  try {
    const headers = await upstreamHeaders(request)
    if (response.destroyed) return
    const upstream = https.request({ ...backend, method: request.method, path: request.url, headers }, result => {
      if (result.statusCode === 401 && session?.cookie === headers.cookie) session = undefined
      response.writeHead(result.statusCode, {
        ...forwardedHeaders(result.headers),
        'cache-control': 'no-store',
        'x-frame-options': 'DENY',
      })
      result.on('error', () => response.destroy())
      result.pipe(response)
    })
    response.on('close', () => upstream.destroy())
    upstream.on('error', () => unavailable(response))
    request.pipe(upstream)
  } catch {
    unavailable(response)
  }
})

server.on('upgrade', async (request, client, clientHead) => {
  const close = status => {
    if (!client.destroyed) client.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`)
  }
  client.on('error', () => client.destroy())
  if (!authorized(request, true) || request.headers.upgrade?.toLowerCase() !== 'websocket') {
    close('403 Forbidden')
    return
  }
  try {
    const headers = await upstreamHeaders(request)
    if (client.destroyed) return
    const upstream = https.request({
      ...backend, path: request.url, headers: { ...headers, connection: 'Upgrade', upgrade: 'websocket' },
    })
    client.on('close', () => upstream.destroy())
    upstream.on('error', () => close('502 Bad Gateway'))
    upstream.on('response', response => {
      if (response.statusCode === 401 && session?.cookie === headers.cookie) session = undefined
      response.resume()
      close('502 Bad Gateway')
    })
    upstream.on('upgrade', (response, socket, head) => {
      const headers = { ...forwardedHeaders(response.headers), connection: 'Upgrade', upgrade: 'websocket' }
      client.write('HTTP/1.1 101 Switching Protocols\r\n' +
        Object.entries(headers).map(([name, value]) => `${name}: ${value}\r\n`).join('') + '\r\n')
      if (head.length) client.write(head)
      if (clientHead.length) socket.write(clientHead)
      socket.on('error', () => client.destroy())
      socket.on('close', () => client.destroy())
      client.on('close', () => socket.destroy())
      socket.pipe(client).pipe(socket)
    })
    upstream.end()
  } catch {
    close('502 Bad Gateway')
  }
})

process.umask(0o077)
if (lstatSync(socketPath, { throwIfNoEntry: false })?.isSocket()) unlinkSync(socketPath)
const child = spawn(process.execPath, dshCommand, { stdio: 'inherit' })
server.on('error', error => {
  console.error('Spark DSH access proxy:', error.code ?? error.name)
  child.kill()
})
child.on('error', () => process.exit(1))
child.on('exit', code => process.exit(code ?? 1))
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    server.close()
    child.kill(signal)
  })
}
server.listen(socketPath)
