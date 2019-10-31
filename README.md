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

```nim
import fastcgi/client

let client = connect("127.0.0.1", 5555)
client.sendBeginRequest()
client.sendParam("SERVER_PORT", "80")
client.sendParam("SERVER_ADDR", "127.0.0.1")
client.sendParam("SCRIPT_FILENAME", "/index.php")
client.sendParam("REQUEST_METHOD", "GET")
client.sendParam()
client.sendStdin()
echo client.readResponse()
```

Donate
-----

Buy me some beer https://paypal.me/ba0f3