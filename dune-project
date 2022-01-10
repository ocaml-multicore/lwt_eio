(lang dune 2.9)
(formatting disabled)
(generate_opam_files true)
(source (github ocaml-multicore/eio))
(license ISC)
(authors "Thomas Leonard")
(maintainers "talex5@gmail.com")
(package
 (name lwt_eio)
 (synopsis "Run Lwt code within Eio")
 (description "An Lwt engine that allows running Lwt within an Eio event loop.")
 (depends
  eio
  lwt
  (eio_main :with-test)))
