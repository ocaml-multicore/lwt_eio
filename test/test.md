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

Lwt and Eio fibers don't block each other:

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
+  lwt: i = 2
+eio: i = 2
+  lwt: i = 3
+eio: i = 3
+  lwt: i = 4
+eio: i = 4
+  lwt: i = 5
+eio: i = 5
+  lwt: i = 6
+eio: i = 6
+  lwt: i = 7
+eio: i = 7
+  lwt: i = 8
+eio: i = 8
- : unit = ()
```

## Forking

We can fork (as long we we're not using multiple domains):

```ocaml
# run @@ fun () ->
  let output = Lwt_eio.run_lwt (fun () -> Lwt_process.(pread (shell "sleep 0.1; echo test"))) in
  traceln "Subprocess produced %S" output;;
+Subprocess produced "test\n"
- : unit = ()
```

Lwt's SIGCHLD handling works:

```ocaml
# run @@ fun () ->
  Lwt_eio.run_lwt (fun () ->
     let p = Lwt_process.(open_process_none (shell "sleep 0.1; echo test")) in
     let+ status = p#status in
     assert (status = Unix.WEXITED 0)
    );;
test
- : unit = ()
```

Eio processes work too:

```ocaml
# Eio_main.run @@ fun env ->
  Lwt_eio.with_event_loop ~clock:env#clock @@ fun _ ->
  Lwt_eio.run_lwt Lwt.pause;
  let proc_mgr = Eio.Stdenv.process_mgr env in
  Eio.Process.run proc_mgr ["echo"; "hello"];;
hello
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

## Cleanup

After finishing with our mainloop, the old Lwt engine is ready for use again:

```ocaml
# run ignore;;
- : unit = ()
# Lwt_main.run (Lwt_unix.sleep 0.01);;
- : unit = ()
```

## Running Lwt code from another domain

A new Eio-only domain runs a job in the original Lwt domain.
The Eio domain is still running while it waits, allowing it to resolve an Lwt promise
and cause the original job to finish and return its result to the Eio domain:

```ocaml
# Eio_main.run @@ fun env ->
  Lwt_eio.with_event_loop ~clock:env#clock @@ fun _ ->
  let lwt_domain = Domain.self () in
  let pp_domain f d =
    if d = lwt_domain then Fmt.string f "Lwt domain"
    else Fmt.string f "new Eio domain"
  in
  traceln "Lwt running in %a" pp_domain lwt_domain;
  Eio.Domain_manager.run env#domain_mgr (fun () ->
    let eio_domain = Domain.self () in
    traceln "Eio running in %a" pp_domain eio_domain;
    let p, r = Lwt.wait () in
    let result =
      Fiber.first
        (fun () ->
           Lwt_eio.run_lwt_in_main (fun () ->
              traceln "Lwt callback running %a" pp_domain (Domain.self ());
              let+ p = p in
              p ^ "L"
           )
         )
         (fun () ->
            Lwt_eio.run_lwt_in_main (fun () -> Lwt.wakeup r "E"; Lwt.return_unit);
            Fiber.await_cancel ()
         )
    in
    traceln "Result: %S" result
  );;
+Lwt running in Lwt domain
+Eio running in new Eio domain
+Lwt callback running Lwt domain
+Result: "EL"
- : unit = ()
```

Cancelling the Eio fiber cancels the Lwt job too:

```ocaml
# Eio_main.run @@ fun env ->
  Lwt_eio.with_event_loop ~clock:env#clock @@ fun _ ->
  Eio.Domain_manager.run env#domain_mgr (fun () ->
    let p, r = Lwt.task () in
    Fiber.both
      (fun () ->
         Lwt_eio.run_lwt_in_main (fun () ->
            traceln "Starting Lwt callback...";
            Lwt.catch
              (fun () -> p)
              (fun ex -> traceln "Lwt caught: %a" Fmt.exn ex; raise ex)
         )
       )
       (fun () ->
          failwith "Simulated error"
       )
  );;
+Starting Lwt callback...
+Lwt caught: Lwt.Resolution_loop.Canceled
Exception: Failure "Simulated error".
```
