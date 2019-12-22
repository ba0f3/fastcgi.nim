import  asyncnet, asyncdispatch, streams, private/common

const
  DEFAULT_PORT = Port(9009)

type
  AsyncFCGIServer = ref object
    socket: AsyncSocket
    reuseAddr: bool
    reusePort: bool

proc newAsyncFCGIServer*(reuseAddr = true, reusePort = false): AsyncFCGIServer =
  ## Creates a new ``AsyncFCGIServer`` instance.
  new result
  result.reuseAddr = reuseAddr
  result.reusePort = reusePort

proc readParams(buffer: array[1024, char], length: int) =
  var pos = 0
  while pos < length:
    var
      nameSize = 1
      valueSize = 1
      nameLen = buffer[pos].int
      valueLen: int
    if nameLen == 0x80:
      nameSize = 4
      nameLen = int((buffer[0].uint8 shl 24) + (buffer[1].uint8 shl 16) + (buffer[2].uint8 shl 8) + buffer[3].uint8)

    valueLen = buffer[pos + nameSize].int

    if valueLen == 0x80:
      valueLen = int((buffer[pos + nameSize].uint8 shl 24) + (buffer[pos + nameSize + 1].uint8 shl 16) + (buffer[pos + nameSize + 2].uint8 shl 8) + buffer[pos + nameSize + 3].uint8)
      valueSize = 4

    echo "name ", buffer[pos+nameSize+valueSize..<pos+nameSize+valueSize+nameLen]
    echo "value ", buffer[pos+nameSize+valueSize+nameLen..<pos+nameSize+valueSize+nameLen+valueLen]
    inc(pos, nameSize + valueSize + nameLen + valueLen)

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
    let dataLen = (header.contentLengthB1 shl 8) + header.contentLengthB0
    echo "dataLen ", dataLen
    if header.kind == FCGI_PARAMS:
      readLen = await client.recvInto(addr buffer, dataLen.int)
      if readLen != dataLen.int:
        client.close()
        break
      if dataLen != 0:
        readParams(buffer, dataLen.int)
    elif header.kind == FCGI_STDIN:
      readLen = await client.recvInto(addr buffer, dataLen.int)
      if readLen != dataLen.int:
        client.close()
        break
      if dataLen != 0:
        echo buffer[0..<dataLen]
      else:
        await client.send "hello world"
    else:
      client.close()
      break
    if header.paddingLength > 0.uint8:
      discard await client.recvInto(addr buffer, header.paddingLength.int)

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
  waitFor server.serve()