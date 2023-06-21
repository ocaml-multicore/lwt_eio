open Eio.Std

exception Cancel

module Token = struct
  [@@@warning "-65"]
  type t = ()
  let v : t = ()
end

(* Call this to cause the current [Lwt_engine.iter] to return. *)
let ready = ref (lazy ())

(* Indicates that [Lwt_unix.fork] has been called and we're the child process.
   Lwt tries to reinitialise the Lwt engine in the child in case the user wants
   to continue using Lwt there (rather than execing), but we don't support that.
   Make sure the reinitialisation doesn't break things (e.g. by adding bogus
   cancellation requests to the io_uring). *)
let is_forked = ref false

(* While the Lwt event loop is running, this is the switch that contains any fibers handling Lwt operations.
   Lwt does not use structured concurrency, so it can spawn background threads without explicitly taking a
   switch argument, which is why we need to use a global variable here. *)
let loop_switch = ref None

let notify () = Lazy.force !ready

(* Run [fn] in a new fiber and return a lazy value that can be forced to cancel it. *)
let fork_with_cancel ~sw fn =
  if !is_forked then lazy (failwith "Can't use Eio in a forked child process")
  else (
    let cancel = ref None in
    Fiber.fork ~sw (fun () ->
        try
          Eio.Cancel.sub @@ fun cc ->
          cancel := Some (lazy (
              if not !is_forked then (
                try Eio.Cancel.cancel cc Cancel with Invalid_argument _ -> ()
              )
            ));
          fn ()
        with Eio.Cancel.Cancelled Cancel -> ()
      );
    (* The forked fiber runs first, so [cancel] must be set by now. *)
    Option.get !cancel
  )

(* Lwt wants to set SIGCHLD to its own handler, but some Eio backends also install a handler for it.
   Both Lwt and Eio need to be notified, as they may each have child processes to monitor.

   There are two cases:

   1. Eio installs its handler first, then Lwt tries to replace it while Eio is running.
      We intercept that attempt and prevent the handler from changing.

   2. Lwt installs its handler first (e.g. because someone ran a Lwt event loop for a bit before using Eio).
      In that case, Eio will already have replaced Lwt's handler by the time we get called.

   Either way, Eio ends up owning the installed handler. We also want things to continue working if the Eio
   event loop finishes and then the application runs a plain Lwt loop. That's why we use [register_immediate],
   rather than running an Eio fiber.

   We also send an extra notification initially, in case we missed one during the hand-over. *)
let install_sigchld_handler = lazy (
  if not Sys.win32 then (
    Eio_unix.Process.install_sigchld_handler ();
    let rec register () =
      ignore (Eio.Condition.register_immediate Eio_unix.Process.sigchld register : Eio.Condition.request);
      Lwt_unix.handle_signal Sys.sigchld
    in
    register ()
  )
)

let make_engine ~sw ~clock = object
  inherit Lwt_engine.abstract

  method private cleanup =
    try Switch.fail sw Exit
    with Invalid_argument _ -> ()            (* Already destroyed *)

  method private register_readable fd callback =
    fork_with_cancel ~sw @@ fun () ->
    while true do
      Eio_unix.await_readable fd;
      Eio.Cancel.protect (fun () -> callback (); notify ())
    done

  method private register_writable fd callback =
    fork_with_cancel ~sw @@ fun () ->
    while true do
      Eio_unix.await_writable fd;
      Eio.Cancel.protect (fun () -> callback (); notify ())
    done

  method private register_timer delay repeat callback =
    fork_with_cancel ~sw @@ fun () ->
    if repeat then (
      while true do
        Eio.Time.sleep clock delay;
        Eio.Cancel.protect (fun () -> callback (); notify ())
      done
    ) else (
      Eio.Time.sleep clock delay;
      Eio.Cancel.protect (fun () -> callback (); notify ())
    )

  method! forwards_signal signum =
    signum = Sys.sigchld

  method iter block =
    if block then (
      let p, r = Promise.create () in
      ready := lazy (Promise.resolve r ());
      Promise.await p
    ) else (
      Fiber.yield ()
    )

  method! fork =
    is_forked := true
end

(* Run an Lwt event loop until [user_promise] resolves. Raises [Exit] when done. *)
let main ~clock user_promise =
  let old_engine = Lwt_engine.get () in
  try
    Switch.run @@ fun sw ->
    if Option.is_some !loop_switch then invalid_arg "Lwt_eio event loop already running";
    Switch.on_release sw (fun () -> loop_switch := None);
    loop_switch := Some sw;
    Lwt_engine.set ~destroy:false (make_engine ~sw ~clock);
    (* An Eio fiber may resume an Lwt thread while in [Lwt_engine.iter] and forget to call [notify].
       If that called [Lwt.pause] then it wouldn't wake up, so handle this common case here. *)
    Lwt.register_pause_notifier (fun _ -> notify ());
    Lwt_main.run user_promise;
    (* Stop any event fibers still running: *)
    raise Exit
  with Exit ->
    Lwt_engine.set old_engine

let with_event_loop ~clock fn =
  Lazy.force install_sigchld_handler;
  let p, r = Lwt.wait () in
  Switch.run @@ fun sw ->
  Fiber.fork ~sw (fun () -> main ~clock p);
  Fun.protect (fun () -> fn Token.v)
    ~finally:(fun () ->
        Lwt.wakeup r ();
        notify ()
      )

let get_loop_switch () =
  match !loop_switch with
  | Some sw -> sw
  | None -> Fmt.failwith "Must be called from within Lwt_eio.with_event_loop!"

module Promise = struct
  let await_lwt lwt_promise =
    let p, r = Promise.create () in
    Lwt.on_any lwt_promise (Promise.resolve_ok r) (Promise.resolve_error r);
    Promise.await_exn p

  let await_eio eio_promise =
    let sw = get_loop_switch () in
    let p, r = Lwt.wait () in
    Fiber.fork ~sw (fun () ->
        Lwt.wakeup r (Promise.await eio_promise);
        notify ()
      );
    p

  let await_eio_result eio_promise =
    let sw = get_loop_switch () in
    let p, r = Lwt.wait () in
    Fiber.fork ~sw (fun () ->
        match Promise.await eio_promise with
        | Ok x -> Lwt.wakeup r x; notify ()
        | Error ex -> Lwt.wakeup_exn r ex; notify ()
      );
    p
end

let run_eio fn =
  let sw = get_loop_switch () in
  let p, r = Lwt.task () in
  let cc = ref None in
  Fiber.fork ~sw (fun () ->
      Eio.Cancel.sub (fun cancel ->
          cc := Some cancel;
          match fn () with
          | x -> Lwt.wakeup r x; notify ()
          | exception ex -> Lwt.wakeup_exn r ex; notify ()
        )
    );
  Lwt.on_cancel p (fun () -> Option.iter (fun cc -> Eio.Cancel.cancel cc Lwt.Canceled) !cc);
  p

let run_lwt fn =
  Fiber.check ();
  let p = fn () in
  try
    Fiber.check ();
    Promise.await_lwt p
  with Eio.Cancel.Cancelled _ as ex ->
    Lwt.cancel p;
    raise ex

module Lf_queue = Eio_utils.Lf_queue

(* Jobs to be run in the main Lwt domain. *)
let jobs : (unit -> unit) Lf_queue.t = Lf_queue.create ()

let job_notification =
  Lwt_unix.make_notification
    (fun () ->
       (* Take the first job. The queue is never empty at this point. *)
       let thunk = Lf_queue.pop jobs |> Option.get in
       thunk ()
    )

let run_in_main_dont_wait f =
  (* Add the job to the queue. *)
  Lf_queue.push jobs f;
  (* Notify the main thread. *)
  Lwt_unix.send_notification job_notification

let run_lwt_in_main f =
  let cancel = ref (fun () -> assert false) in
  let p, r = Eio.Promise.create () in
  run_in_main_dont_wait (fun () ->
      let thread = f () in
      cancel := (fun () -> Lwt.cancel thread);
      Lwt.on_any thread
        (Eio.Promise.resolve_ok r)
        (Eio.Promise.resolve_error r)
    );
  match
    Fiber.check ();
    Eio.Promise.await p
  with
  | Ok x -> x
  | Error ex -> raise ex
  | exception (Eio.Cancel.Cancelled _ as ex) ->
    let cancelled, set_cancelled = Eio.Promise.create () in
    run_in_main_dont_wait (fun () ->
        (* By the time this runs, [cancel] must have been set. *)
        !cancel ();
        Eio.Promise.resolve set_cancelled ()
      );
    Eio.Cancel.protect (fun () -> Eio.Promise.await cancelled);
    raise ex
