import fastcgi/server, asyncdispatch

type
  MyHandler* = ref object of StreamHandler

method beginRequest*(h: MyHandler, req: Request) {.async.} =
  if req.reqMethod != HttpGet:
    let headers = newHttpHeaders([
      ("status", "405 method not allowed"),
      ("content-type", "text/plain")
    ])
    await req.respond("405 Method Not Allowed", headers, appStatus=405)
    req.close()

let s = newAsyncFCGIServer()
s.addHandler("/*", new MyHandler)
waitFor s.serve(Port(9000))