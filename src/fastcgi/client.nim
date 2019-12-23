import net, streams, private/common


type
  FCGIClient = ref object of RootObj
    host: string
    port: Port
    socket: Socket
    isKeepalive: bool
    paramBuffer: StringStream


proc newFCGICLient*(host: string, port: int, isKeepalive = false): FCGIClient =
  ## Create new FastCGI Client instance
  new(result)
  result.host = host
  result.port = port.Port
  result.isKeepalive = isKeepalive
  result.paramBuffer = newStringStream()

proc connect*(client: FCGIClient) =
  ## Connect to FastCGI server, must called before `sendRequest`
  client.socket = newSocket()
  client.socket.connect(client.host, client.port)
proc close*(client: FCGIClient) = client.socket.close()

proc setParam*(client: FCGIClient, name: string, value = "") =
  ## Set param by name-value pair
  let
    nameLen = name.len
    valueLen = value.len

  if nameLen == 0:
    return

  if nameLen < 128:
    client.paramBuffer.write(nameLen.char)
  else:
    client.paramBuffer.write(chr((nameLen shr 24) or 0x80))
    client.paramBuffer.write(chr((nameLen shr 16) and 0xff))
    client.paramBuffer.write(chr((nameLen shr 8) and 0xff))
    client.paramBuffer.write(chr(nameLen and 0xff))

  if valueLen < 128:
    client.paramBuffer.write(valueLen.char)
  else:
    client.paramBuffer.write(chr((valueLen shr 24) or 0x80))
    client.paramBuffer.write(chr((valueLen shr 16) and 0xff))
    client.paramBuffer.write(chr((valueLen shr 8) and 0xff))
    client.paramBuffer.write(chr(valueLen and 0xff))

  client.paramBuffer.write(name)
  if valueLen > 0:
    client.paramBuffer.write(value)

proc setParams*(client: FCGIClient, params: openarray[tuple[name:  string, value: string]]) =
  ## Set multiple param pairs at once
  for param in params:
    client.setParam(param.name, param.value)

proc clearParams*(client: FCGIClient) =
  ## Clear all params
  client.paramBuffer = newStringStream()

proc sendBeginRequest(client: FCGIClient) =
  var record: BeginRequestRecord
  record.header = initHeader(FCGI_BEGIN_REQUEST, 0, sizeof(BeginRequestBody), 0)
  record.body = initBeginRequestBody(FCGI_RESPONDER, client.isKeepalive)
  if client.socket.send(addr record, sizeof(record)) != sizeof(record):
    raise newException(IOError, "unable to send begin request")

proc sendParams(client: FCGIClient) =
  client.paramBuffer.setPosition(0)
  let data = client.paramBuffer.readAll()

  var header = initHeader(FCGI_PARAMS, 0, data.len, 0)
  if client.socket.send(addr header, FCGI_HEADER_LENGTH) != FCGI_HEADER_LENGTH:
    raise newException(IOError, "unable to send param header")

  if client.socket.send(data.cstring, data.len) != data.len:
    raise newException(IOError, "unable to send param equest")

  header = initHeader(FCGI_PARAMS, 0, 0, 0)
  if client.socket.send(addr header, FCGI_HEADER_LENGTH) != FCGI_HEADER_LENGTH:
    raise newException(IOError, "unable to send param end")

proc readResponse(client: FCGIClient): TaintedString =
  var
    header: Header
    padding: array[8, char]

  while true:
    let len = client.socket.recv(addr header, FCGI_HEADER_LENGTH)
    if len != FCGI_HEADER_LENGTH:
      raise newException(IOError, "unable to read response header")

    case header.kind
    of FCGI_STDOUT, FCGI_STDERR:
      let contentLength = (header.contentLengthB1.int shl 8) + header.contentLengthB0.int
      if contentLength > 0:
        result = newString(contentLength)
        if client.socket.recv(result.cstring, contentLength) != contentLength:
          raise newException(IOError, "unable to read response body")
        if header.paddingLength > 0'u8 and header.paddingLength <= 8'u8:
          if client.socket.recv(addr padding, header.paddingLength.int) != header.paddingLength.int:
            raise newException(IOError, "unable to read response padding")
    of FCGI_END_REQUEST:
      var body: EndRequestBody
      if client.socket.recv(addr body, sizeof(body)) != sizeof(body):
        raise newException(IOError, "unable to read end request body")
      break
    else:
      discard

proc sendRequest*(client: FCGIClient, payload = ""): TaintedString =
  client.sendBeginRequest()
  client.sendParams()

  let payloadLen = payload.len
  var header = initHeader(FCGI_STDIN, 0, payloadLen, 0)
  if client.socket.send(addr header, FCGI_HEADER_LENGTH) != FCGI_HEADER_LENGTH:
    raise newException(IOError, "unable to send payload header")
  if payloadLen > 0:
    if client.socket.send(payload.cstring, payloadLen) != payloadLen:
      raise newException(IOError, "unable to send payload")
    header.contentLengthB1 = 0
    header.contentLengthB0 = 0
    if client.socket.send(addr header, FCGI_HEADER_LENGTH) != FCGI_HEADER_LENGTH:
      raise newException(IOError, "unable to send end params")

  result = client.readResponse()