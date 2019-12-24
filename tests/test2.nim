import fastcgi/server, asyncdispatch

type
  SimpleHandler* = ref object of RequestHandler

method process*(h: SimpleHandler, req: Request) {.async.} =
  echo req
  await req.respond("Hello from simple FastCGI request handler")

let s = newAsyncFCGIServer()
s.addHandler("/fcgi/simple", new SimpleHandler)
waitFor s.serve(Port(9000))