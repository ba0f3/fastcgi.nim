# This is just an example to get you started. You may wish to put all of your
# tests into a single file, or separate them into multiple `test1`, `test2`
# etc. files (better names are recommended, just make sure the name starts with
# the letter 't').
#
# To run these tests, simply execute `nimble test`.

import unittest, fastcgi/client

test "test client request":
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
