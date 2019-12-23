import  asyncnet, asyncdispatch, streams, private/common, strutils, strtabs

const
  DEFAULT_PORT = Port(9009)

type
  AsyncFCGIServer = ref object
    socket: AsyncSocket
    reuseAddr: bool
    reusePort: bool

  ReadParamState = enum
    READ_NAME_LEN
    READ_VALUE_LEN
    READ_NAME_DATA
    READ_VALUE_DATA



proc newAsyncFCGIServer*(reuseAddr = true, reusePort = false): AsyncFCGIServer =
  ## Creates a new ``AsyncFCGIServer`` instance.
  new result
  result.reuseAddr = reuseAddr
  result.reusePort = reusePort

proc readParams(buffer: ptr array[1024, char], length: int): StringTableRef =
  result = newStringTable(modeCaseInsensitive)

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
      result[name] = value
      inc(pos, valueLen.int)
      state = READ_NAME_LEN

proc response*(server: AsyncFCGIServer, client: AsyncSocket, payload: string) {.async.} =
  let payloadLen = payload.len
  var header = initHeader(FCGI_STDOUT, 1, payloadLen, 0)
  await client.send(addr header, FCGI_HEADER_LENGTH)
  if payloadLen > 0:
    await client.send(payload.cstring, payloadLen)

    header.contentLengthB1 = 0
    header.contentLengthB0 = 0
    await client.send(addr header, FCGI_HEADER_LENGTH)

  var record: EndRequestRecord
  record.header = initHeader(FCGI_END_REQUEST, 1, sizeof(record.body), 0)
  record.body = initEndRequestBody(0, FCGI_REQUEST_COMPLETE)
  await client.send(addr record, sizeof(record))
  client.close()

proc processClient(server: AsyncFCGIServer, client: AsyncSocket, address: string) {.async.} =
  var
    readLen = 0
    buffer: array[1024, char]
    beginRequest: BeginRequestRecord
    header: Header

  readLen = await client.recvInto(addr beginRequest, sizeof(BeginRequestRecord))
  if readLen != sizeof(BeginRequestRecord):
    client.close()

  while not client.isClosed:
    readLen = await client.recvInto(addr header, sizeof(Header))
    if readLen != sizeof(Header):
      client.close()
      break
    echo header
    let dataLen = (header.contentLengthB1.int16 shl 8) + header.contentLengthB0.int8
    if header.kind == FCGI_PARAMS:
      readLen = await client.recvInto(addr buffer, dataLen + header.paddingLength.int8)
      if readLen != dataLen.int16 + header.paddingLength.int8:
        client.close()
      if dataLen != 0:
        echo readParams(addr buffer, dataLen)
    elif header.kind == FCGI_STDIN:
      readLen = await client.recvInto(addr buffer, dataLen + header.paddingLength.int8)
      if readLen != dataLen + header.paddingLength.int8:
        client.close()
      if dataLen != 0:
        echo buffer[0..<dataLen].join()
      else:
        await server.response(client, "\c\L\c\Lhello world")
        break
    else:
      client.close()
      break

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