# Lwt_eio - run Lwt code from within Eio

Status: experimental

Lwt_eio is an Lwt engine that uses Eio.
It can be used to run Lwt and Eio code in a single domain.

See `lwt_eio.mli` for the API.

# Examples

There are two example programs:

- `simple.ml` runs an Lwt thread and an Eio fibre, communicating over a pair of streams.
- `chat.ml` runs a chat server.
  An Eio fibre accepts (loopback) connections on port 8001, while an Lwt thread accepts connections on port 8002.
  All clients on either port see the room history, which consists of all messages sent by any client as well as join/leave events.

```
$ dune exec -- ./simple.exe
+Eio fibre waiting...
Lwt thread sleeping...
Lwt thread sending 1 to Eio
+Eio fibre got "1" from Lwt
+Eio fibre sleeping...
+Eio fibre sending 2 to Lwt...
+Eio fibre done
Lwt got "2" from Eio
```

To use the chat example, start the server in a terminal:

```
$ dune exec -- ./chat.exe
+Eio fibre waiting for connections on 8001...
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
