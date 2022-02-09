open Eio.Std

exception Cancel

let ignore_cancel = function
  | Cancel -> ()
  | ex -> raise ex

(* Call this to cause the current [Lwt_engine.iter] to return. *)
let ready = ref (lazy ())

(* While the Lwt event loop is running, this is the switch that contains any fibres handling Lwt operations.
   Lwt does not use structured concurrency, so it can spawn background threads without explicitly taking a
   switch argument, which is why we need to use a global variable here. *)
let loop_switch = ref None

let notify () = Lazy.force !ready

(* Run [fn] in a new fibre and return a lazy value that can be forced to cancel it. *)
let fork_with_cancel ~sw fn =
  let cancel = ref None in
  Fibre.fork_sub ~sw ~on_error:ignore_cancel (fun sw ->
      cancel := Some (lazy (try Switch.fail sw Cancel with Invalid_argument _ -> ()));
      fn ()
    );
  (* The forked fibre runs first, so [cancel] must be set by now. *)
  Option.get !cancel

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

  method iter block =
    if block then (
      let p, r = Promise.create () in
      ready := lazy (Promise.resolve r ());
      Promise.await p
    ) else (
      Fibre.yield ()
    )
end

type no_return = |

(* Run an Lwt event loop until [user_promise] resolves. Raises [Exit] when done. *)
let main ~clock user_promise : no_return =
  Switch.run @@ fun sw ->
  if Option.is_some !loop_switch then invalid_arg "Lwt_eio event loop already running";
  Switch.on_release sw (fun () -> loop_switch := None);
  loop_switch := Some sw;
  Lwt_engine.set (make_engine ~sw ~clock);
  (* An Eio fibre may resume an Lwt thread while in [Lwt_engine.iter] and forget to call [notify].
     If that called [Lwt.pause] then it wouldn't wake up, so handle this common case here. *)
  Lwt.register_pause_notifier (fun _ -> notify ());
  Lwt_main.run user_promise;
  (* Stop any event fibres still running: *)
  raise Exit

let with_event_loop ~clock fn =
  let p, r = Lwt.wait () in
  Switch.run @@ fun sw ->
  Fibre.fork ~sw (fun () ->
      match main ~clock p with
      | _ -> .
      | exception Exit -> ()
    );
  Fun.protect fn
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
    Fibre.fork ~sw (fun () ->
        Lwt.wakeup r (Promise.await eio_promise);
        notify ()
      );
    p

  let await_eio_result eio_promise =
    let sw = get_loop_switch () in
    let p, r = Lwt.wait () in
    Fibre.fork ~sw (fun () ->
        match Promise.await eio_promise with
        | Ok x -> Lwt.wakeup r x; notify ()
        | Error ex -> Lwt.wakeup_exn r ex; notify ()
      );
    p
end

let run_eio fn =
  let sw = get_loop_switch () in
  let p, r = Lwt.wait () in
  Fibre.fork ~sw (fun () ->
      match fn () with
      | x -> Lwt.wakeup r x; notify ()
      | exception ex -> Lwt.wakeup_exn r ex; notify ()
    );
  p
