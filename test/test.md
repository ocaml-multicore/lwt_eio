## Setup

```ocaml
# #require "eio_main";;
# #require "lwt_eio";;
```

```ocaml
open Lwt.Syntax
open Eio.Std

let run fn =
  Eio_main.run @@ fun env ->
  Lwt_eio.with_event_loop ~clock:env#clock @@ fun _ ->
  fn ()
```

## Fairness

Lwt and Eio fibers don't block each other, although `Lwt_main.run` does call `Lwt.wakeup_paused` twice
during each iteration of the main loop, so the Lwt thread runs twice as often.

```ocaml
# run @@ fun () ->
  Fiber.both
    (fun () ->
       for i = 1 to 8 do
         traceln "eio: i = %d" i;
         Fiber.yield ()
       done
    )
    (fun () ->
       Lwt_eio.Promise.await_lwt begin
         let rec aux i =
           traceln "  lwt: i = %d" i;
           let* () = Lwt.pause () in
           if i < 8 then aux (i + 1)
           else Lwt.return_unit
         in
         aux 1
       end
    );;
+eio: i = 1
+  lwt: i = 1
+eio: i = 2
+  lwt: i = 2
+  lwt: i = 3
+eio: i = 3
+  lwt: i = 4
+  lwt: i = 5
+eio: i = 4
+  lwt: i = 6
+  lwt: i = 7
+eio: i = 5
+  lwt: i = 8
+eio: i = 6
+eio: i = 7
+eio: i = 8
- : unit = ()
```

## Forking

We can fork (as long we we're not using multiple domains):

```ocaml
# run @@ fun () ->
  let output = Lwt_eio.run_lwt (fun () -> Lwt_process.(pread (shell "echo test"))) in
  traceln "Subprocess produced %S" output;;
+Subprocess produced "test\n"
- : unit = ()
```

## Signals

Installing a signal handler with `Lwt_unix.on_signal` causes `lwt_unix_send_notification` to be called when the signal occurs. This signals the main event thread by writing to a pipe or eventfd, which is processed by Eio in the usual way.

```ocaml
# run @@ fun () ->
  let p, r = Promise.create () in
  Lwt_eio.run_lwt (fun () ->
     let handler = Lwt_unix.on_signal Sys.sigusr1 (fun (_ : int) ->
          traceln "Signal handler received USR1";
          (* It's OK to use Promise.resolve here, as it never blocks *)
          Promise.resolve r ()
       )
     in
     Unix.(kill (getpid ())) Sys.sigusr1;
     let* () = Lwt_eio.Promise.await_eio p in
     traceln "Finished; removing signal handler";
     Lwt_unix.disable_signal_handler handler;
     Lwt.return_unit
  );;
+Signal handler received USR1
+Finished; removing signal handler
- : unit = ()
```

## Exceptions

Lwt failures become Eio exceptions:

```ocaml
# run @@ fun () ->
  try Lwt_eio.run_lwt (fun () -> Lwt.fail_with "Simulated error")
  with Failure msg -> traceln "Eio caught: %s" msg;;
+Eio caught: Simulated error
- : unit = ()
```

Eio exceptions become Lwt failures:

```ocaml
# run @@ fun () ->
  Lwt_eio.run_lwt (fun () ->
     Lwt.catch
       (fun () -> Lwt_eio.run_eio (fun () -> failwith "Simulated error"))
       (fun ex -> traceln "Lwt caught: %a" Fmt.exn ex; Lwt.return_unit)
  );;
+Lwt caught: Failure("Simulated error")
- : unit = ()
```

## Cancellation

Cancelling an Eio fiber that is running Lwt code cancels the Lwt promise:

```ocaml
# run @@ fun () ->
  let p, r = Lwt.task () in
  try
    Fiber.both
      (fun () -> Lwt_eio.run_lwt (fun () -> p))
      (fun () -> failwith "Simulated error");
  with Failure _ ->
    traceln "Checking status of Lwt promise...";
    Lwt_eio.Promise.await_lwt p;;
+Checking status of Lwt promise...
Exception: Lwt.Resolution_loop.Canceled.
```

Cancelling a Lwt thread that is running Eio code cancels the Eio context:

```ocaml
# run @@ fun () ->
  Switch.run @@ fun sw ->
  Lwt_eio.run_lwt (fun () ->
     let p = Lwt_eio.run_eio (fun () ->
        try Fiber.await_cancel ()
        with Eio.Cancel.Cancelled ex -> traceln "Eio fiber cancelled: %a" Fmt.exn ex
     ) in
     Lwt.cancel p;
     Lwt.return_unit
  );;
+Eio fiber cancelled: Lwt.Resolution_loop.Canceled
- : unit = ()
```

Trying to run Lwt code from an already-cancelled context fails immediately:

```ocaml
# run @@ fun () ->
  Switch.run @@ fun sw ->
  Switch.fail sw (Failure "Simulated error");
  Lwt_eio.run_lwt (fun () ->
     let* () = Lwt.pause () in
     assert false
  );;
Exception: Failure "Simulated error".
```
