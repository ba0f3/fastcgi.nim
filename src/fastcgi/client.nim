#import fastcgipkg/submodule
import net, posix, os, strutils

const
  PARAMS_BUFF_MAX_LEN = 5120
  FCGI_MAX_LENGTH* = 0xffff
  FCGI_HEADER_LENGTH = 8
  FCGI_VERSION_1 = 1

  FGCI_KEEP_CONNECTION = 1
  FCGI_RESPONDER* = 1
  FCGI_AUTHORIZER* = 2
  FCGI_FILTER* = 3

  FCGI_MAX_CONNS* = "FCGI_MAX_CONNS"
  FCGI_MAX_REQS* = "FCGI_MAX_REQS"
  FCGI_MPXS_CONNS* = "FCGI_MPXS_CONNS"

type
  HeaderKind* = enum
    FCGI_BEGIN_REQUEST = 1
    FCGI_ABORT_REQUEST
    FCGI_END_REQUEST
    FCGI_PARAMS
    FCGI_STDIN
    FCGI_STDOUT
    FCGI_STDERR
    FCGI_DATA
    FCGI_GET_VALUES
    FCGI_GET_VALUES_RESULT
    FCGI_MAX

  Header = object
    version: uint8
    kind: HeaderKind
    requestIdB1: uint8
    requestIdB0: uint8
    contentLengthB1: uint8
    contentLengthB0: uint8
    paddingLength: uint8
    reserved: uint8

  BeginRequestBody = object
    roleB1: uint8
    roleB0: uint8
    flags: uint8
    reserved: array[5, uint8]

  BeginRequestRecord = object
    header: Header
    body: BeginRequestBody

  EndRequestBody = object
    appStatusB3: uint8
    appStatusB2: uint8
    appStatusB1: uint8
    appStatusB0: uint8
    protocolStatus: uint8
    reserved: array[3, char]

  EndRequestRecord = object
    header: Header
    body: EndRequestBody

  UnknownTypeBody = object
    kind: uint8
    reserved: array[7, uint8]

  UnknownTypeRecord = object
    header: Header
    body: UnknownTypeBody

var paramBuffer: array[PARAMS_BUFF_MAX_LEN, char]

proc connect*(host: string, port: int): Socket =
  result = newSocket()
  result.connect(host, port.Port)

proc initHeader*(kind: HeaderKind, reqId, contentLength, paddingLenth: int): Header =
  result.version = FCGI_VERSION_1
  result.kind = kind
  result.requestIdB1 = uint8((reqId shr 8) and 0xff)
  result.requestIdB0 = uint8(reqId and 0xff)
  result.contentLengthB1 = uint8((contentLength shr 8) and 0xff)
  result.contentLengthB0 = uint8(contentLength and 0xff)
  result.paddingLength = paddingLenth.uint8
  result.reserved = 0

proc initBeginRequestBody*(role: int, keepalive: bool): BeginRequestBody =
  result.roleB1 = uint8((role shr 8) and 0xff)
  result.roleB0 = uint8(role and 0xff)
  result.flags = if keepalive: FGCI_KEEP_CONNECTION else: 0

proc sendBeginRequest*(s: Socket) =
  var record: BeginRequestRecord
  record.header = initHeader(FCGI_BEGIN_REQUEST, 0, sizeof(record.body), 0)
  record.body = initBeginRequestBody(FCGI_RESPONDER, false)
  if s.send(addr record, sizeof(record)) != sizeof(record):
    raise newException(IOError, "unable to send begin request")

proc sendParam*(s: Socket, name, value = "") =
  let
    nameLen = name.len
    valueLen = value.len

  var header: Header

  if nameLen == 0:
    header = initHeader(FCGI_PARAMS, 0, 0, 0)
    if s.send(addr header, FCGI_HEADER_LENGTH) != FCGI_HEADER_LENGTH:
      raise newException(IOError, "unable to send end params request")
    return

  zeroMem(addr paramBuffer, PARAMS_BUFF_MAX_LEN)
  var length = 0
  if nameLen < 128:
    paramBuffer[0] = nameLen.char
    length = 1
  else:
    paramBuffer[0] = chr((nameLen shr 24) or 0x80)
    paramBuffer[1] = chr((nameLen shr 16) and 0xff)
    paramBuffer[2] = chr((nameLen shr 8) and 0xff)
    paramBuffer[3] = chr(nameLen and 0xff)
    length = 4

  if valueLen < 128:
    paramBuffer[length] = chr(valueLen)
    inc(length, 1)
  else:
    paramBuffer[length] = chr((valueLen shr 24) or 0x80)
    paramBuffer[length + 1] = chr((valueLen shr 16) and 0xff)
    paramBuffer[length + 2] = chr((valueLen shr 8) and 0xff)
    paramBuffer[length + 3] = chr(valueLen and 0xff)
    inc(length, 4)

  copyMem(addr paramBuffer[length], name.cstring, nameLen)
  copyMem(addr paramBuffer[length + nameLen], value.cstring, valueLen)

  let bodyLen = length + nameLen + valueLen

  header = initHeader(FCGI_PARAMS, 0, bodylen, 0)
  if s.send(addr header, FCGI_HEADER_LENGTH) != FCGI_HEADER_LENGTH:
    raise newException(IOError, "unable to send param header")
  if s.send(addr paramBuffer, bodyLen) != bodyLen:
    raise newException(IOError, "unable to send param body")

proc sendStdin*(s: Socket, payload = "") =
  let payloadLen = payload.len
  var header = initHeader(FCGI_STDIN, 0, payloadLen, 0)
  if s.send(unsafeAddr header, FCGI_HEADER_LENGTH) != FCGI_HEADER_LENGTH:
    raise newException(IOError, "unable to send stdin header")
  if payloadLen != 0:
    if s.send(payload.cstring, payloadLen) != sizeof(payloadLen):
      raise newException(IOError, "unable to send stdin body")
    header = initHeader(FCGI_STDIN, 0, 0, 0)
    if s.send(unsafeAddr header, FCGI_HEADER_LENGTH) != FCGI_HEADER_LENGTH:
      raise newException(IOError, "unable to send end stdin request")

proc readResponse*(s: Socket): TaintedString =
  var
    header: Header
    padding: array[8, char]

  while true:
    let len = s.recv(addr header, FCGI_HEADER_LENGTH)
    if len != FCGI_HEADER_LENGTH:
      raise newException(IOError, "unable to read response header, errno " & $errno)

    case header.kind
    of FCGI_STDOUT, FCGI_STDERR:
      let contentLength = int((header.contentLengthB1 shr 8) + header.contentLengthB0)
      if contentLength > 0:
        result = newString(contentLength)
        if s.recv(result.cstring, contentLength) != contentLength:
          raise newException(IOError, "unable to read response body")
        if header.paddingLength > 0 and header.paddingLength <= 8:
          if s.recv(addr padding, header.paddingLength.int) != header.paddingLength.int:
            raise newException(IOError, "unable to read response padding")
    of FCGI_END_REQUEST:
      var body: EndRequestBody
      if s.recv(addr body, sizeof(body)) != sizeof(body):
        raise newException(IOError, "unable to read end request body")
      break
    else:
      discard