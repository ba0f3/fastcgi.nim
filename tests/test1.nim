# This is just an example to get you started. You may wish to put all of your
# tests into a single file, or separate them into multiple `test1`, `test2`
# etc. files (better names are recommended, just make sure the name starts with
# the letter 't').
#
# To run these tests, simply execute `nimble test`.

import unittest, fastcgi/client

test "correct welcome":
  let client = connect("127.0.0.1", 5555)
  client.sendBeginRequest()
  client.sendParam("SERVER_PORT", "80")
  client.sendParam("SERVER_ADDR", "127.0.0.1")
  client.sendParam("SCRIPT_FILENAME", "/index.php")
  client.sendParam("REQUEST_METHOD", "GET")
  client.sendParam()
  client.sendStdin()
  echo client.readResponse()

