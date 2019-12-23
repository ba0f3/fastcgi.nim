
const
  PARAMS_BUFF_MAX_LEN* = 5120
  FCGI_MAX_LENGTH* = 0xffff
  FCGI_HEADER_LENGTH* = 8
  FCGI_VERSION_1* = 1

  FGCI_KEEP_CONNECTION* = 1

  FCGI_MAX_CONNS* = "FCGI_MAX_CONNS"
  FCGI_MAX_REQS* = "FCGI_MAX_REQS"
  FCGI_MPXS_CONNS* = "FCGI_MPXS_CONNS"

type
  FCGI_ROLE* = enum
    FCGI_RESPONDER = 1
    FCGI_AUTHORIZER = 2
    FCGI_FILTER = 3

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

  ProtocolStatus* = enum
    FCGI_REQUEST_COMPLETE
    FCGI_CANT_MPX_CONN
    FCGI_OVERLOADED
    FCGI_UNKNOWN_ROLE

  Header* = object
    version*: uint8
    kind*: HeaderKind
    requestIdB1*: uint8
    requestIdB0*: uint8
    contentLengthB1*: uint8
    contentLengthB0*: uint8
    paddingLength*: uint8
    reserved*: uint8

  BeginRequestBody* = object
    roleB1*: uint8
    roleB0*: uint8
    flags*: uint8
    reserved*: array[5, uint8]

  BeginRequestRecord* = object
    header*: Header
    body*: BeginRequestBody

  EndRequestBody* = object
    appStatusB3*: uint8
    appStatusB2*: uint8
    appStatusB1*: uint8
    appStatusB0*: uint8
    protocolStatus*: uint8
    reserved*: array[3, char]

  EndRequestRecord* = object
    header*: Header
    body*: EndRequestBody

  UnknownTypeBody* = object
    kind*: uint8
    reserved*: array[7, uint8]

  UnknownTypeRecord* = object
    header*: Header
    body*: UnknownTypeBody


proc initHeader*(kind: HeaderKind, reqId: uint16, contentLength, paddingLenth: int): Header =
  result.version = FCGI_VERSION_1
  result.kind = kind
  result.requestIdB1 = uint8((reqId shr 8) and 0xff)
  result.requestIdB0 = uint8(reqId and 0xff)
  result.contentLengthB1 = uint8((contentLength shr 8) and 0xff)
  result.contentLengthB0 = uint8(contentLength and 0xff)
  result.paddingLength = paddingLenth.uint8
  result.reserved = 0

proc initBeginRequestBody*(role: FCGI_ROLE, keepalive: bool): BeginRequestBody =
  result.roleB1 = uint8((role.int shr 8) and 0xff)
  result.roleB0 = uint8(role.int and 0xff)
  result.flags = if keepalive: FGCI_KEEP_CONNECTION else: 0

proc initEndRequestBody*(appStatus: int32, status = FCGI_REQUEST_COMPLETE): EndRequestBody =
  result.appStatusB3 = uint8((appStatus shr 24) and 0xff)
  result.appStatusB2 = uint8((appStatus shr 16) and 0xff)
  result.appStatusB1 = uint8((appStatus shr 8) and 0xff)
  result.appStatusB0 = uint8((appStatus) and 0xff)
  result.protocolStatus = status.uint8