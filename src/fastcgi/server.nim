#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Basic usage
## ===========
##
## This example will create an FastCGI server on port 9000. The server will
## respond to all requests with a ``200 OK`` response code and "Hello World"
## as the response body.
##
## .. code-block::nim
##    import fastcgi/server, asyncdispatch
##
##    proc cb(req: Request) {.async.} =
##      var headers = newHttpHeaders()
##      headers.add("status", "200 OK")
##      headers.add("content-type", "text/plain; charset=utf-8")
##    await req.respond("Hello World", headers)
##
##    let server = newAsyncFCGIServer()
##    waitFor server.serve(Port(9000), cb)

import  asyncnet, asyncdispatch, httpcore, strutils, strformat, tables, os
import private/common
export httpcore

type
  RequestHandler* = ref object of RootObj

  AsyncFCGIServer* = ref object
    socket*: AsyncSocket
    reuseAddr*: bool
    reusePort*: bool
    allowedIps*: seq[string]
    handlers: Table[string, RequestHandler]

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

# method process*(e: RequestHandler, req: Request): Future[void] {.base.} =
#   raise newException(CatchableError, "Method without implementation override")

proc newAsyncFCGIServer*(reuseAddr = true, reusePort = false): AsyncFCGIServer =
  ## Creates a new ``AsyncFCGIServer`` instance.
  new result
  result.reuseAddr = reuseAddr
  result.reusePort = reusePort
  result.handlers = initTable[string, RequestHandler]()

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
      echo &"{name} = {value}"
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

# proc addHandler*(server: AsyncFCGIServer, path: string, handler: RequestHandler) =
#   server.handlers[path] = handler

# proc processRequest(server: AsyncFCGIServer, req: Request) {.async.} =
#   if server.handlers.hasKey(req.reqUri):
#     await server.handlers[req.reqUri].process(req)
#   else:
#     var headers = newHttpHeaders()
#     headers.add("status", "404 not found")
#     headers.add("content-type", "text/plain")
#     await req.respond("404 Not Found", headers, appStatus=404)

proc processClient(
  server: AsyncFCGIServer,
  client: AsyncSocket,
  address: string,
  callback: proc (request: Request): Future[void] {.closure, gcsafe.}) {.async.} =
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

    length = (header.contentLengthB1.int shl 8) + header.contentLengthB0.int
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
    of FCGI_STDIN:
      readLen = await client.recvInto(addr buffer, payloadLen)
      if readLen != payloadLen: return
      if length != 0:
        # req.body.setLen(length)
        # copyMem(req.body.cstring, addr buffer, length)
        var bodyPart: string
        bodyPart.setLen(length)
        copyMem(bodyPart.cstring, addr buffer, length)
        req.body.add(bodyPart)
      else:
        # await server.processRequest(req)
        await callback(req)
    else:
      return
  #else:
  #  await server.response(client, "\c\LNot Implemented")

proc checkRemoteAddrs(server: AsyncFCGIServer, client: AsyncSocket): bool =
  if server.allowedIps.len > 0:
    let (remote, _) = client.getPeerAddr()
    return remote in server.allowedIps
  return true

proc serve*(
  server: AsyncFCGIServer,
  port = DEFAULT_PORT,
  callback: proc (request: Request): Future[void] {.closure, gcsafe.},
  address = "") {.async.} =
  ## Starts the process of listening for incoming TCP connections
  server.socket = newAsyncSocket()
  if server.reuseAddr:
    server.socket.setSockOpt(OptReuseAddr, true)
  if server.reusePort:
    server.socket.setSockOpt(OptReusePort, true)
  server.socket.bindAddr(port, address)
  server.socket.listen()

  while true:
    var (address, client) = await server.socket.acceptAddr()

    if server.checkRemoteAddrs(client):
      asyncCheck processClient(server, client, address, callback)
    else:
      client.close()

proc close*(server: AsyncFCGIServer) =
  ## Terminates the async http server instance.
  server.socket.close()

when isMainModule:
  let server = newAsyncFCGIServer()
  proc cb(req: Request) {.async.} =
    var headers = newHttpHeaders()
    headers.add("status", "200 OK")
    headers.add("content-type", "text/plain; charset=utf-8")
  waitFor server.serve(Port(9000), cb)
