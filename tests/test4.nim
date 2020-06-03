import fastcgi/server, asyncdispatch

type
  WildcardHandler* = ref object of StreamHandler

var
  myreq: Request
  mydata: string

method beginRequest*(h: WildcardHandler, req: Request) {.async.} =
  echo "new request"
  myreq = req

method onData*(h: WildcardHandler, data: string) {.async.} =
  echo "data receiced: ", data.len
  mydata.add(data)

method endRequest*(h: WildcardHandler) {.async.} =
  await myreq.respond("You requested: " & myreq.reqUri)
  echo mydata

let s = newAsyncFCGIServer()
s.addHandler("/fcgi/sendtext", new WildcardHandler)
waitFor s.serve(Port(9000))