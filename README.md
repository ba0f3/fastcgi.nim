FastCGI
-------

FastCGI library for Nim. Server library will coming soon

Installation
------------

```shell
nimble  install fastcgi
```

Usage
-----

### FastCGI Server
```nim
import fastcgi/server, asyncdispatch

type
  SimpleHandler* = ref object of RequestHandler

method process*(h: SimpleHandler, req: Request) {.async.} =
  await req.respond("Hello from simple FastCGI request handler")

let s = newAsyncFCGIServer()
s.addHandler("/fcgi/simple", new SimpleHandler)
waitFor s.serve(Port(9000))
```

### FastCGI Client
```nim
import fastcgi/client

# create new instance
let client = newFCGICLient("127.0.0.1", 9000)
# set params
client.setParam("SERVER_SOFTWARE", "fastcgi.nim/0.1.0")
client.setParams({
  "SERVER_PORT": "80",
  "SERVER_ADDR": "127.0.0.1",
  "SCRIPT_FILENAME": "/index.php",
  "REQUEST_METHOD": "POST"
})
# connect to fastcgi server on port 9000
client.connect()
# send stdin payload
echo client.sendRequest("{'name':'John', 'age':30, 'car':null}")
# close connection
client.close()
```

Donate
-----

Buy me some beer https://paypal.me/ba0f3
