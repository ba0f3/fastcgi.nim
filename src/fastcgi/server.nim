import  asyncnet, asyncdispatch, httpcore, private/common, strutils, strformat

const
  DEFAULT_PORT = Port(9009)

type
  AsyncFCGIServer* = ref object
    socket: AsyncSocket
    reuseAddr: bool
    reusePort: bool

  ReadParamState = enum
    READ_NAME_LEN
    READ_VALUE_LEN
    READ_NAME_DATA
    READ_VALUE_DATA

  Request* = object
    keepAlive*: uint8
    id*: uint16
    dataLen*: uint16
    client*: AsyncSocket
    headers*: HttpHeaders




proc newAsyncFCGIServer*(reuseAddr = true, reusePort = false): AsyncFCGIServer =
  ## Creates a new ``AsyncFCGIServer`` instance.
  new result
  result.reuseAddr = reuseAddr
  result.reusePort = reusePort

proc getParams(buffer: ptr array[FCGI_MAX_LENGTH + 8, char], length: int): HttpHeaders =
  result = newHttpHeaders()

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
        nameLen = nameLen shl 24 + buffer[pos + 1].uint8
        nameLen = nameLen shl 16 + buffer[pos + 2].uint8
        nameLen = nameLen shl 8 + buffer[pos + 3].uint8
        inc(pos, 4)
      else:
        inc(pos, 1)
      state = READ_VALUE_LEN
    of READ_VALUE_LEN:
      valueLen = buffer[pos].uint32
      if valueLen == 0x80:
        valueLen = valueLen shl 24 + buffer[pos + 1].uint8
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
      result.add(name, value)
      inc(pos, valueLen.int)
      state = READ_NAME_LEN

proc sendEnd*(req: Request, appStatus: int32 = 0, status = FCGI_REQUEST_COMPLETE) {.async.} =
  var record: EndRequestRecord
  record.header = initHeader(FCGI_END_REQUEST, req.id, sizeof(EndRequestBody), 0)
  record.body = initEndRequestBody(appStatus, status)
  await req.client.send(addr record, sizeof(record))

proc respond*(req: Request, content: string, headers: HttpHeaders = nil, appStatus: int32 = 0) {.async.} =
  var payload = ""
  if headers != nil:
    for name, value in headers.pairs:
      payload.add(fmt"{name}: {value}\c\L")
  if content.len > 0:
    payload.add(fmt"\c\L{content}")

  var header = initHeader(FCGI_STDOUT, req.id, payload.len, 0)
  await req.client.send(addr header, FCGI_HEADER_LENGTH)
  if payload.len > 0:
    await req.client.send(payload.cstring, payload.len)
    header.contentLengthB1 = 0
    header.contentLengthB0 = 0
    await req.client.send(addr header, FCGI_HEADER_LENGTH)

  await req.sendEnd(0)

  if req.keepAlive == 0:
    req.client.close()

proc processClient(server: AsyncFCGIServer, client: AsyncSocket, address: string) {.async.} =
  var
    req: Request
    readLen = 0
    header: Header
    buffer: array[FCGI_MAX_LENGTH + 8, char]
    length: int
    dataLen: int
    payloadLen: int

  while not client.isClosed:
    readLen = await client.recvInto(addr header, sizeof(Header))
    if readLen != sizeof(Header) or header.version.ord < FCGI_VERSION_1:
      return
    echo header

    length = (header.contentLengthB1.int16 shl 8) or header.contentLengthB0.int8
    payloadLen = length + header.paddingLength.int8

    if payloadLen > FCGI_MAX_LENGTH:
      return

    req.client = client
    req.id = (header.requestIdB1.uint16 shl 8) + header.requestIdB0

    case header.kind
    of FCGI_BEGIN_REQUEST:
      readLen = await client.recvInto(addr buffer, payloadLen)
      let begin = cast[ptr BeginRequestBody](addr buffer)
      req.keepAlive = begin.flags and FGCI_KEEP_CONNECTION

    of FCGI_PARAMS:
      readLen = await client.recvInto(addr buffer, payloadLen)
      if readLen != payloadLen:
        return

      if length != 0:
        req.headers = getParams(addr buffer, length)

    of FCGI_STDIN:
      readLen = await client.recvInto(addr buffer, payloadLen)
      if readLen != payloadLen:
        client.close()
      if length != 0:
        dataLen = length
        echo buffer[0..<length].join()
      else:
        await req.respond("hello world")
        break
    else:
      return
  #else:
  #  await server.response(client, "\c\LNot Implemented")

proc serve*(server: AsyncFCGIServer, port = DEFAULT_PORT, address = "") {.async.} =
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
    asyncCheck processClient(server, client, address)

proc close*(server: AsyncFCGIServer) =
  ## Terminates the async http server instance.
  server.socket.close()

when isMainModule:
  let server = newAsyncFCGIServer()
  waitFor server.serve(Port(9000))