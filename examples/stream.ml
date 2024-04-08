open Eio.Std
open Lwt.Syntax

let main ~from_lwt ~to_lwt ~clock =
  traceln "Eio fiber waiting...";
  let msg = Eio.Stream.take from_lwt in
  traceln "Eio fiber got %S from Lwt" msg;
  traceln "Eio fiber sleeping...";
  Eio.Time.sleep clock 0.4;
  traceln "Eio fiber sending 2 to Lwt...";
  Eio.Stream.add to_lwt "2";
  traceln "Eio fiber done"

let main_lwt ~to_eio ~from_eio =
  let* () = Lwt_io.eprintf "Lwt thread sleeping...\n" in
  let* () = Lwt_io.(flush stderr) in
  let* () = Lwt_unix.sleep 0.4 in
  let* () = Lwt_io.eprintf "Lwt thread sending 1 to Eio\n" in
  let* () = Lwt_io.(flush stderr) in
  let* () = to_eio "1" in
  let* () = Lwt_io.eprintf "Lwt thread waiting for response...\n" in
  let* () = Lwt_io.(flush stderr) in
  let* msg = from_eio () in
  let* () = Lwt_io.eprintf "Lwt got %S from Eio\n" msg in
  let* () = Lwt_io.(flush stderr) in
  Lwt.return_unit

let () =
  (* Eio_unix.Ctf.with_tracing "/tmp/trace.ctf" @@ fun () -> *)
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Lwt_eio.with_event_loop ~debug:true ~clock @@ fun () ->
  let lwt_to_eio = Eio.Stream.create 0 in
  let eio_to_lwt = Eio.Stream.create 0 in
  let to_eio x = Lwt_eio.run_eio (fun () -> Eio.Stream.add lwt_to_eio x) in
  let from_eio () = Lwt_eio.run_eio (fun () -> Eio.Stream.take eio_to_lwt) in
  Fiber.both
    (fun () -> Lwt_eio.run_lwt (fun () -> main_lwt ~to_eio ~from_eio))
    (fun () -> main ~clock ~from_lwt:lwt_to_eio ~to_lwt:eio_to_lwt)
