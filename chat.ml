open Eio.Std
open Lwt.Syntax

module Stream = struct
  type cons = Cons of (string * cons) Promise.t

  type prod = {
    mutable resolver : (string * cons) Promise.u;
  }

  let create () : prod * cons =
    let cons, resolver = Promise.create () in
    let prod = { resolver } in
    prod, Cons cons

  let next (Cons p) =
    Promise.await p

  let next_lwt (Cons p) =
    Lwt_eio.Promise.await_eio p

  let add prod msg =
    let cons, resolver = Promise.create () in
    Promise.resolve prod.resolver (msg, Cons cons);
    prod.resolver <- resolver
end

module Eio_server = struct
  let handle_client flow (prod, cons) =
    let rec send cons =
      let (msg, cons) = Stream.next cons in
      Eio.Flow.copy_string msg flow;
      send cons
    in
    Fibre.first
      (fun () -> send cons)
      (fun () ->
         try
           while true do
             let buf = Cstruct.create 100 in
             let len = Eio.Flow.read flow buf in
             Stream.add prod (Cstruct.to_string buf ~len)
           done
         with End_of_file ->
           Stream.add prod "Eio connection closed\n"
      )

  let run ~net ~port (prod, cons) =
    Switch.run @@ fun sw ->
    let socket = Eio.Net.listen ~sw ~reuse_addr:true net ~backlog:5
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
    traceln "Eio fibre waiting for connections on %d..." port;
    while true do
      Eio.Net.accept_sub ~sw socket ~on_error:(traceln "Eio connection failed: %a" Fmt.exn)
        (fun ~sw:_ flow addr ->
           Stream.add prod (Fmt.str "Got connection from %a via Eio@." Eio.Net.Sockaddr.pp addr);
           handle_client flow (prod, cons)
        )
    done
end

module Lwt_server = struct
  let write_all fd msg =
    let rec aux i =
      let len = String.length msg - i in
      if len = 0 then Lwt.return_unit
      else (
        let* sent = Lwt_unix.write_string fd msg i len in
        aux (i + sent)
      )
    in
    aux 0

  let handle_client client (prod, cons) =
    Lwt.finalize
      (fun () ->
         let rec send cons =
           let* (msg, cons) = Stream.next_lwt cons in
           let* () = write_all client msg in
           send cons
         in
         let rec recv () =
           let buf = Bytes.create 100 in
           let* len = Lwt_unix.read client buf 0 (Bytes.length buf) in
           if len = 0 then (
             Stream.add prod "Connection closed\n";
             Lwt.return_unit
           ) else (
             Stream.add prod (Bytes.sub_string buf 0 len);
             recv ()
           )
         in
         Lwt.pick [send cons; recv ()]
      )
      (fun () ->
         let+ () = Lwt_unix.close client in
         Stream.add prod "Lwt connection closed\n"
      )

  let run ~port (prod, cons) =
    let socket = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
    Lwt_unix.setsockopt socket Lwt_unix.SO_REUSEADDR true;
    let* () = Lwt_unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) in
    Lwt_unix.listen socket 5;
    traceln "Lwt thread waiting for connections on %d..." port;
    let rec aux () =
      let* client, addr = Lwt_unix.accept socket in
      let addr = match addr with Lwt_unix.ADDR_INET (h, p) -> `Tcp (Eio_unix.Ipaddr.of_unix h, p) | _ -> assert false in
      Stream.add prod (Fmt.str "Got connection from %a via Lwt@." Eio.Net.Sockaddr.pp addr);
      Lwt.dont_wait
        (fun () -> handle_client client (prod, cons))
        (traceln "Lwt connection failed: %a" Fmt.exn);
      aux ()
    in
    Lwt.finalize aux (fun () -> Lwt_unix.close socket)
end

let () =
  (* Ctf_unix.with_tracing "/tmp/trace.ctf" @@ fun () -> *)
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let net = Eio.Stdenv.net env in
  Lwt_eio.with_event_loop ~clock @@ fun () ->
  let stream = Stream.create () in
  Fibre.both
    (fun () -> Eio_server.run ~port:8001 stream ~net)
    (fun () -> Lwt_eio.Promise.await_lwt (Lwt_server.run ~port:8002 stream))
