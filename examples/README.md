There are two example programs:

- `simple.ml` runs a Lwt thread and an Eio fiber, communicating over a pair of streams.
- `chat.ml` runs a chat server.
  An Eio fiber accepts (loopback) connections on port 8001, while a Lwt thread accepts connections on port 8002.
  All clients on either port see the room history, which consists of all messages sent by any client as well as join/leave events.

```
$ dune exec -- ./simple.exe
+Eio fiber waiting...
Lwt thread sleeping...
Lwt thread sending 1 to Eio
+Eio fiber got "1" from Lwt
+Eio fiber sleeping...
+Eio fiber sending 2 to Lwt...
+Eio fiber done
Lwt got "2" from Eio
```

To use the chat example, start the server in a terminal:

```
$ dune exec -- ./chat.exe
+Eio fiber waiting for connections on 8001...
+Lwt thread waiting for connections on 8002...
```

Then connect to the Eio port from another terminal:

```
$ telnet localhost 8001
Trying 127.0.0.1...
Connected to localhost.
Escape character is '^]'.
Got connection from tcp:127.0.0.1:51296 via Eio
Hello from client A
Hello from client A
```

It echos back whatever you type.

Then connect on the Lwt port using a third terminal:

```
$ telnet localhost 8002
Trying 127.0.0.1...
Connected to localhost.
Escape character is '^]'.
Got connection from tcp:127.0.0.1:51296 via Eio
Hello from client A
Got connection from tcp:127.0.0.1:47674 via Lwt
Hello from client B
Hello from client B
```

Both clients should show all messages.
