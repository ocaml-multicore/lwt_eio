# Lwt_eio - run Lwt code from within Eio

Lwt_eio is a Lwt engine that uses Eio.
It can be used to run Lwt and Eio code in a single domain.
It allows converting existing code to Eio incrementally.

See `lib/lwt_eio.mli` for the API.

The [examples](./examples/) directory contains some example programs and instructions on using them.

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
  Lwt_eio.with_event_loop ~clock:env#clock @@ fun _ ->
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
  Lwt_eio.with_event_loop ~clock:env#clock @@ fun _ ->
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
  Lwt_eio.with_event_loop ~clock:env#clock @@ fun _ ->
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

  - If you are writing a library that requires `Lwt_eio`, consider having its main function (if any)
    take a value of type `Lwt_eio.Token.t`. This will remind users of the library to initialise Lwt_eio first.

## Limitations

- Lwt code can only run in a single domain, and using `Lwt_eio` does not change this.
  You can only run Lwt code in the domain that ran `Lwt_eio.with_event_loop`.

- `Lwt_eio` does not make your Lwt programs run faster than before.
  Lwt jobs are still run by Lwt, and do not take advantage of Eio's `io_uring` support, for example.
