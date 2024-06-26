module Token : sig
  [@@@warning "-65"]
  type t = private ()
  (** A token indicating that Lwt_eio was started.

      If a library needs Lwt_eio to be running, it can request this token to remind the application
      to initialise it. This is most useful if a library has a main entry point, or some configuration
      value that has to be constructed before the library is used.

      This type should be treated as abstract, but it is defined as [private ()] to avoid breaking
      existing code. *)
end

val with_event_loop : ?debug:bool -> clock:_ Eio.Time.clock -> (Token.t -> 'a) -> 'a
(** [with_event_loop ~clock fn] starts an Lwt event loop running and then executes [fn t].
    When that finishes, the event loop is stopped.

    @param debug If [true] (the default is [false]), block attempts to perform effects in Lwt context.
                 [Get_context] is allowed, so [traceln] still works,
                 but this will detect cases where Lwt code tries to call Eio code directly. *)

module Promise : sig
  val await_lwt : 'a Lwt.t -> 'a
  (** [await_lwt p] allows an Eio fiber to wait for a Lwt promise [p] to be resolved,
      much like {!Eio.Promise.await} does for Eio promises.

      This can only be used while the event loop created by {!with_event_loop} is still running.

      Note: in the usual case of needing to run some Lwt code to generate the promise first, use {!run_lwt} instead.
      That handles cancellation and also tracks the current context so that debug mode works. *)

  val await_eio : 'a Eio.Promise.t -> 'a Lwt.t
  (** [await_eio p] allows a Lwt thread to wait for an Eio promise [p] to be resolved.
      This can only be used while the event loop created by {!with_event_loop} is still running. *)

  val await_eio_result : 'a Eio.Promise.or_exn -> 'a Lwt.t
  (** [await_eio_result] is like [await_eio], but allows failing the lwt thread too. *)
end

val run_eio : (unit -> 'a) -> 'a Lwt.t 
(** [run_eio fn] allows running Eio code from within a Lwt function.
    
    It runs [fn ()] in a new Eio fiber and returns a promise for the result.
    If the returned promise is cancelled, it will cancel the Eio fiber.
    The new fiber is attached to the Lwt event loop's switch and will also be
    cancelled if the function passed to {!with_event_loop} returns. *)

val run_lwt : (unit -> 'a Lwt.t) -> 'a
(** [run_lwt fn] allows running Lwt code from within an Eio function.

    It runs [fn ()] to create a Lwt promise and then awaits it.
    If the Eio fiber is cancelled, the Lwt promise is cancelled too.

    This can only be called from the domain running Lwt.
    For other domains, use {!run_lwt_in_main} instead. *)

val run_lwt_in_main : (unit -> 'a Lwt.t) -> 'a
(** [run_lwt_in_main fn] schedules [fn ()] to run in Lwt's domain
    and waits for the result.

    It is similar to {!Lwt_preemptive.run_in_main},
    but allows other Eio fibers to run while it's waiting.
    It can be called from any Eio domain.

    If the Eio fiber is cancelled, the Lwt promise is cancelled too. *)

val notify : unit -> unit
(** [notify ()] causes [Lwt_engine.iter] to return,
    indicating that the event loop should run the hooks and resume yielded threads.

    Ideally, you should call this when an Eio fiber wakes up a Lwt thread, e.g. by resolving a Lwt promise.
    In most cases however this isn't really needed,
    since [Lwt_unix.yield] is deprecated and [Lwt.pause] will call this automatically. *)
