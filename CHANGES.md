## v0.4

- Get Lwt and Eio to share the SIGCHLD handler (@talex5 #19).  
  Otherwise, Lwt replaces Eio's handler and may prevent Eio from noticing child processes finishing.

- Don't allow cancelling things after forking (@talex5 #21).  
  With io_uring, this will mess up the parent's ring.

- Add `Lwt_eio.run_lwt_in_main` (@talex5 #20).  
  This is useful if your program uses multiple Eio domains and you want to run some Lwt code from any of them.

- Fix some Eio deprecation warnings (@talex5 #18).  

## v0.3

- Restore the old Lwt engine after finishing (@talex5 #16, reported by @tmcgilchrist).

- Use `run_lwt` in documentation (@talex5 #13).

- Update for Eio deprecations (@talex5 #12 #14).

## v0.2

- Add some tests and documentation of the internals (@talex5 #9).

- Bridge Eio and Lwt cancellation (@talex5 #8).
  - Cancelling a `run_lwt` Fiber cancels the Lwt promise.
  - Cancelling a `run_eio` promise cancels the Eio fiber.

- Add `run_lwt` for consistency with `run_eio` and Async_eio (@talex5 #8).

- Add `Lwt_eio.Token.t` token to ensure library is initialised (@talex5 #5).
  `with_event_loop` now passes a `Lwt_eio.Token.t` to its callback.

- Update to Eio 0.2 (@talex5 #4).
  Eio 0.2 renamed "fibre" to "fiber". This fixes the deprecation warning.

## v0.1

- Initial release.
