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

# connect to fastcgi server on port 9000
let client = connect("127.0.0.1", 9000)
# start fastcgi request
client.sendBeginRequest()
# set params
client.sendParam("SERVER_PORT", "80")
client.sendParam("SERVER_ADDR", "127.0.0.1")
client.sendParam("SCRIPT_FILENAME", "/index.php")
client.sendParam("REQUEST_METHOD", "GET")
# end set params request
client.sendParam()
# send stdin payload
client.sendPayload("{'name':'John', 'age':30, 'car':null}")
# end payload
client.sendPayload()
# read response from server
echo client.readResponse()
```

Donate
-----

Buy me some beer https://paypal.me/ba0f3