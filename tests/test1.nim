# This is just an example to get you started. You may wish to put all of your
# tests into a single file, or separate them into multiple `test1`, `test2`
# etc. files (better names are recommended, just make sure the name starts with
# the letter 't').
#
# To run these tests, simply execute `nimble test`.

import unittest, fastcgi/client

test "correct welcome":
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
