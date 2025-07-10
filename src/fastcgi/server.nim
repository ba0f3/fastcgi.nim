import  asyncnet, asyncdispatch, httpcore, strutils, strformat, os
from std/nativesockets import AF_UNIX, SOCK_STREAM, Protocol
import private/common
export httpcore

type

  RequestHandler* = ref object of RootObj
    reqUri: string

  StreamHandler* = ref object of RequestHandler

  AsyncFCGIServer* = ref object
    socket*: AsyncSocket
    reuseAddr*: bool
    reusePort*: bool
    allowedIps*: seq[string]
    handlers: seq[RequestHandler]

  ReadParamState* = enum
    READ_NAME_LEN
    READ_VALUE_LEN
    READ_NAME_DATA
    READ_VALUE_DATA
    READ_FINISH

  Request* = object
    id*: uint16
    keepAlive*: uint8
    reqMethod*: HttpMethod
    reqUri*: string
    client*: AsyncSocket
    headers*: HttpHeaders
    body*: string

const
  DEFAULT_PORT = Port(9009)
  FCGI_WEB_SERVER_ADDRS = "FCGI_WEB_SERVER_ADDRS"

method process*(e: RequestHandler, req: Request): Future[void] {.base, locks: "unknown".} =
  raise newException(CatchableError, "Method without implementation override")

method beginRequest*(e: StreamHandler, req: Request): Future[void] {.base, locks: "unknown".} =
  raise newException(CatchableError, "Method without implementation override")

method onData*(e: StreamHandler, data: string): Future[void] {.base, locks: "unknown".} =
  raise newException(CatchableError, "Method without implementation override")

method endRequest*(e: StreamHandler): Future[void] {.base, locks: "unknown".} =
  raise newException(CatchableError, "Method without implementation override")

proc newAsyncFCGIServer*(reuseAddr = true, reusePort = false): AsyncFCGIServer =
  ## Creates a new ``AsyncFCGIServer`` instance.
  new result
  result.reuseAddr = reuseAddr
  result.reusePort = reusePort

  let fwsa = getEnv(FCGI_WEB_SERVER_ADDRS, "")
  if fwsa.len > 0:
    for add in fwsa.split(','):
      result.allowedIps.add(add.strip())

proc initRequest(): Request =
  result.keepAlive = 0
  result.headers = newHttpHeaders()

proc getParams(req: var Request, buffer: ptr array[FCGI_MAX_LENGTH + 8, char], length: int) =
  var
    pos = 0
    nameLen: uint32
    valueLen: uint32
    state: ReadParamState
    name: string
    value: string

  while pos < length:
    case state
    of READ_NAME_LEN:
      nameLen = buffer[pos].uint32
      if nameLen == 0x80:
        nameLen = (nameLen and 0x7f) shl 24 + buffer[pos + 1].uint8
        nameLen = nameLen shl 16 + buffer[pos + 2].uint8
        nameLen = nameLen shl 8 + buffer[pos + 3].uint8
        inc(pos, 4)
      else:
        inc(pos, 1)
      state = READ_VALUE_LEN
    of READ_VALUE_LEN:
      valueLen = buffer[pos].uint32
      if valueLen == 0x80:
        valueLen = (valueLen and 0x7f) shl 24 + buffer[pos + 1].uint8
        valueLen = valueLen shl 16 + buffer[pos + 2].uint8
        valueLen = valueLen shl 8 + buffer[pos + 3].uint8
        inc(pos, 4)
      else:
        inc(pos, 1)
      state = READ_NAME_DATA
    of READ_NAME_DATA:
      name = newString(nameLen)
      copyMem(name.cstring, addr buffer[pos], nameLen)
      inc(pos, nameLen.int)
      state = READ_VALUE_DATA
    of READ_VALUE_DATA:
      value = newString(valueLen)
      copyMem(value.cstring, addr buffer[pos], valueLen)
      inc(pos, valueLen.int)
      state = READ_FINISH
    of READ_FINISH:
      state = READ_NAME_LEN
      case name
      of "REQUEST_METHOD":
        case value
        of "GET": req.reqMethod = HttpGet
        of "POST": req.reqMethod = HttpPost
        of "HEAD": req.reqMethod = HttpHead
        of "PUT": req.reqMethod = HttpPut
        of "DELETE": req.reqMethod = HttpDelete
        of "PATCH": req.reqMethod = HttpPatch
        of "OPTIONS": req.reqMethod = HttpOptions
        of "CONNECT": req.reqMethod = HttpConnect
        of "TRACE": req.reqMethod = HttpTrace
        else:
          raise newException(IOError, "400 bad request")
      of "REQUEST_URI":
        req.reqUri = value
      else:
        discard
      req.headers.add(name, value)

proc sendEnd*(req: Request, appStatus: int32 = 0, status = FCGI_REQUEST_COMPLETE) {.async.} =
  var record: EndRequestRecord
  record.header = initHeader(FCGI_END_REQUEST, req.id, sizeof(EndRequestBody), 0)
  record.body = initEndRequestBody(appStatus, status)
  await req.client.send(addr record, sizeof(record))

proc respond*(req: Request, content = "", headers: HttpHeaders = nil, appStatus: int32 = 0) {.async.} =
  var payload = ""
  if headers != nil:
    for name, value in headers.pairs:
      payload.add(&"{name}: {value}\c\L")
  else:
    payload.add("content-type: text/plain\c\L")
  if content.len > 0:
    payload.add(&"\c\L{content}")

  var header = initHeader(FCGI_STDOUT, req.id, payload.len, 0)
  await req.client.send(addr header, FCGI_HEADER_LENGTH)
  if payload.len > 0:
    await req.client.send(payload.cstring, payload.len)
    header.contentLengthB1 = 0
    header.contentLengthB0 = 0
    await req.client.send(addr header, FCGI_HEADER_LENGTH)

  await req.sendEnd()

  if req.keepAlive == 0:
    req.client.close()

proc close*(req: Request) =
  try:
    req.client.close()
  except:
    discard

proc addHandler*(server: AsyncFCGIServer, reqUri: string, handler: RequestHandler) =
  handler.reqUri = reqUri
  server.handlers.add(handler)

proc findHandler(server: AsyncFCGIServer, reqUri: string): RequestHandler =
  result = nil
  for handler in server.handlers:
    if handler.reqUri[^1] == '*' and reqUri.startsWith(handler.reqUri[0..^2]):
      result = handler
    elif reqUri == handler.reqUri:
      result = handler

proc processClient(server: AsyncFCGIServer, client: AsyncSocket) {.async.} =
  var
    req = initRequest()
    readLen = 0
    header: Header
    buffer: array[FCGI_MAX_LENGTH + 8, char]
    length: int
    payloadLen: int

  while not client.isClosed:
    readLen = await client.recvInto(addr header, sizeof(Header))
    if readLen != sizeof(Header) or header.version.ord < FCGI_VERSION_1:
      return

    length = (header.contentLengthB1.int shl 8) or header.contentLengthB0.int
    payloadLen = length + header.paddingLength.int

    if payloadLen > FCGI_MAX_LENGTH:
      return

    req.client = client
    req.id = (header.requestIdB1.uint16 shl 8) + header.requestIdB0

    case header.kind
    of FCGI_GET_VALUES:
      echo "get value"
    of FCGI_BEGIN_REQUEST:
      readLen = await client.recvInto(addr buffer, payloadLen)
      let begin = cast[ptr BeginRequestBody](addr buffer)
      req.keepAlive = begin.flags and FGCI_KEEP_CONNECTION
    of FCGI_PARAMS:
      readLen = await client.recvInto(addr buffer, payloadLen)
      if readLen != payloadLen: return
      if length != 0:
        req.getParams(addr buffer, length)
        let handler = server.findHandler(req.reqUri)
        if handler of StreamHandler:
          await StreamHandler(handler).beginRequest(req)
    of FCGI_STDIN:
      readLen = await client.recvInto(addr buffer, payloadLen)
      if readLen != payloadLen: return
      let handler = server.findHandler(req.reqUri)
      if length != 0:
        var chunk = newString(length)
        copyMem(chunk.cstring, addr buffer, length)
        if handler of StreamHandler:
          await StreamHandler(handler).onData(chunk)
        else:
          req.body.add(chunk)
      else:
        if handler of StreamHandler:
          await StreamHandler(handler).endRequest()
        elif handler != nil:
            await handler.process(req)
        else:
          let headers = newHttpHeaders([
            ("status", "404 not found"),
            ("content-type", "text/plain")
          ])
          await req.respond("404 Not Found", headers, appStatus=404)
    else:
      return
  #else:
  #  await server.response(client, "\c\LNot Implemented")

proc checkRemoteAddrs(server: AsyncFCGIServer, client: AsyncSocket): bool =
  if server.allowedIps.len > 0:
    let (remote, _) = client.getPeerAddr()
    return remote in server.allowedIps
  return true

proc serve(server: AsyncFCGIServer; sock: AsyncSocket) {.async.} =
  assert server.socket == AsyncSocket.default
  server.socket = sock
  while true:
    var client = await server.socket.accept()

    if server.checkRemoteAddrs(client):
      asyncCheck processClient(server, client)
    else:
      client.close()

proc serve*(server: AsyncFCGIServer, port = DEFAULT_PORT, address = ""): Future[void] =
  ## Starts the process of listening for incoming TCP connections
  var socket = newAsyncSocket()
  if server.reuseAddr:
    socket.setSockOpt(OptReuseAddr, true)
  if server.reusePort:
    socket.setSockOpt(OptReusePort, true)
  socket.bindAddr(port, address)
  socket.listen()
  serve(server, socket)

proc serveUnix*(server: AsyncFCGIServer; path: string): Future[void] =
  ## Starts the process of listening for incoming UNIX connections.
  var socket = newAsyncSocket(
      domain = AF_UNIX,
      sockType = SOCK_STREAM,
      protocol = IPPROTO_IP,
    )
  bindUnix(socket, path)
  socket.listen()
  serve(server, socket)

proc close*(server: AsyncFCGIServer) =
  ## Terminates the async http server instance.
  server.socket.close()

when isMainModule:
  let server = newAsyncFCGIServer()
  waitFor server.serve(Port(9000))
