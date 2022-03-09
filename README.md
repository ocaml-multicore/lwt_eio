# Lwt_eio - run Lwt code from within Eio

Lwt_eio is a Lwt engine that uses Eio.
It can be used to run Lwt and Eio code in a single domain.
It allows converting existing code to Eio incrementally.

See `lib/lwt_eio.mli` for the API.

## Examples

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

## Limitations

- Lwt code can only run in a single domain, and using `Lwt_eio` does not change this.
  You can only run Lwt code in the domain that ran `Lwt_eio.with_event_loop`.

- `Lwt_eio` does not make your Lwt programs run faster than before.
  Lwt jobs are still run by Lwt, and do not take advantage of Eio's `io_uring` support, for example.

## Porting a Lwt Application to Eio

This guide will show how to migrate an existing Lwt application or library to Eio.
We'll start with this Lwt program, which reads in a list of lines, sorts them,
and writes the result to stdout:

```ocaml
# #require "lwt.unix";;
# open Lwt.Syntax;;

# let process_lines src fn =
    let stream = Lwt_io.read_lines src in
    let* lines = Lwt_stream.to_list stream in
    let* lines = fn lines in
    let rec write = function
      | [] -> Lwt.return_unit
      | x :: xs ->
        let* () = Lwt_io.(write_line stdout) x in
        write xs
    in
    let* () = write lines in
    Lwt_io.(flush stdout);;
val process_lines :
  Lwt_io.input_channel -> (string list -> string list Lwt.t) -> unit Lwt.t =
  <fun>

# let sort src =
    process_lines src @@ fun lines ->
    let* () = Lwt.pause () in       (* Simulate async work *)
    Lwt.return (List.sort String.compare lines);;
val sort : Lwt_io.input_channel -> unit Lwt.t = <fun>

# Lwt_main.run begin
    let input = Lwt_io.(of_bytes ~mode:input)
      (Lwt_bytes.of_bytes (Bytes.of_string "b\na\nd\nc\n")) in
    sort input
  end;;
a
b
c
d
- : unit = ()
```

The first step is to replace `Lwt_main.run`, and check that the program still works:

```ocaml
# #require "eio_main";;
# #require "lwt_eio";;
# open Eio.Std;;

# Eio_main.run @@ fun env ->
  Lwt_eio.with_event_loop ~clock:env#clock @@ fun () ->
  Lwt_eio.Promise.await_lwt begin
    let input = Lwt_io.(of_bytes ~mode:input)
      (Lwt_bytes.of_bytes (Bytes.of_string "b\na\nd\nc\n")) in
    sort input
  end;;
a
b
c
d
- : unit = ()
```

Here, we're using the Eio event loop instead of the normal Lwt one,
but everything else stays the same.

Note: When I first tried this, it failed with `Fatal error: exception Unhandled`
because I'd forgotten to flush stdout in the Lwt code.
That meant that `sort` returned before Lwt had completely finished and then it
tried to flush lazily after the Eio loop had finished, which is an error.

We can now start converting code to Eio.
There are several places we could start.
Here we'll begin with the `process_lines` function.
We'll take an Eio flow instead of a Lwt_io input:

```ocaml
# let process_lines src fn =
    let* lines =
      Lwt_eio.run_eio @@ fun () ->
      Eio.Buf_read.of_flow src ~max_size:max_int
      |> Eio.Buf_read.lines
      |> List.of_seq
    in
    let* lines = fn lines in
    let rec write = function
      | [] -> Lwt.return_unit
      | x :: xs ->
        let* () = Lwt_io.(write_line stdout) x in
        write xs
    in
    let* () = write lines in
    Lwt_io.(flush stdout);;
val process_lines :
  #Eio.Flow.source -> (string list -> string list Lwt.t) -> unit Lwt.t =
  <fun>
```

Note that `process_lines` is still a Lwt function,
but it now uses `run_eio` internally to read from the input using Eio.

**Warning:** It's important not to call Eio functions directly from Lwt, but instead wrap such code with `run_eio`.
If you replace the `Lwt_eio.run_eio @@ fun () ->` line with `Lwt.return @@`
then it will appear to work in simple cases, but it will act as a blocking read.
It's similar to trying to turn a blocking call like `Stdlib.input_line` into an asynchronous one
using `Lwt.return`. It doesn't actually make it concurrent.

We can now test it using an Eio flow:

```ocaml
# let sort src =
    process_lines src @@ fun lines ->
    let* () = Lwt.pause () in       (* Simulate async work *)
    Lwt.return (List.sort String.compare lines);;
val sort : #Eio.Flow.source -> unit Lwt.t = <fun>

# Eio_main.run @@ fun env ->
  Lwt_eio.with_event_loop ~clock:env#clock @@ fun () ->
  Lwt_eio.Promise.await_lwt begin
    sort (Eio.Flow.string_source "b\na\nd\nc\n")
  end;;
a
b
c
d
- : unit = ()
```

Let's finish converting `process_lines`:

```ocaml
# let process_lines ~src ~dst fn =
    Eio.Buf_read.of_flow src ~max_size:max_int
    |> Eio.Buf_read.lines
    |> List.of_seq
    |> fn
    |> List.iter (fun line ->
       Eio.Flow.copy_string (line ^ "\n") dst
    );;
val process_lines :
  src:#Eio.Flow.source ->
  dst:#Eio.Flow.sink -> (string list -> string list) -> unit = <fun>
```

Now `process_lines` is an Eio function. The `Lwt.t` types have disappeared from its signature.

Note that we now take an extra `dst` argument for the output:
Eio functions should always receive access to external resources explicitly.

To use the new version, we'll have to update `sort` to wrap its Lwt callback:

```ocaml
# let sort ~src ~dst =
    process_lines ~src ~dst @@ fun lines ->
    Lwt_eio.Promise.await_lwt begin
      let* () = Lwt.pause () in       (* Simulate async work *)
      Lwt.return (List.sort String.compare lines)
    end;;
val sort : src:#Eio.Flow.source -> dst:#Eio.Flow.sink -> unit = <fun>
```

`sort` itself now looks like a normal Eio function from its signature.
We can therefore now call it directly from Eio:

```ocaml
# Eio_main.run @@ fun env ->
  Lwt_eio.with_event_loop ~clock:env#clock @@ fun () ->
  sort
    ~src:(Eio.Flow.string_source "b\na\nd\nc\n")
    ~dst:env#stdout;;
a
b
c
d
- : unit = ()
```

Finally, we can convert `sort`'s callback to Eio code and drop the use of `Lwt` and `Lwt_eio` completely:

```ocaml
# let sort ~src ~dst =
    process_lines ~src ~dst @@ fun lines ->
    Fiber.yield ();     (* Simulate async work *)
    List.sort String.compare lines;;
val sort : src:#Eio.Flow.source -> dst:#Eio.Flow.sink -> unit = <fun>

# Eio_main.run @@ fun env ->
  sort
    ~src:(Eio.Flow.string_source "b\na\nd\nc\n")
    ~dst:env#stdout;;
a
b
c
d
- : unit = ()
```

Key points:

- Start by replacing `Lwt_main.run` while keeping the rest of the code the same.

- Update your program piece by piece, using `Lwt_eio` when moving between Eio and Lwt contexts.

- Never call Eio code directly from Lwt code. Wrap it with `Lwt_eio.run_eio`.
  Simply wrapping the result of an Eio call with `Lwt.return` is NOT safe.

- Almost all uses of Lwt promises (`Lwt.t`) should disappear
  (do not blindly replace Lwt promises with Eio promises).

- You don't have to do the conversion in any particular order.

- You may need to make other changes to your API. In particular:

  - External resources (such as `stdout`, the network and the filesystem) should be passed as inputs to Eio code.

  - Take a `Switch.t` argument if your function creates fibers or file handles that out-live the function.
