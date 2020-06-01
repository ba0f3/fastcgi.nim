import fastcgi/server, asyncdispatch

type
  WildcardHandler* = ref object of RequestHandler

method process*(h: WildcardHandler, req: Request) {.async.} =
  await req.respond("You requested: " & req.reqUri)

let s = newAsyncFCGIServer()
s.addHandler("/fcgi/*", new WildcardHandler)
waitFor s.serve(Port(9000))