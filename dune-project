(lang dune 2.9)
(name lwt_eio)
(formatting disabled)
(generate_opam_files true)
(source (github talex5/lwt_eio))
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
  (mdx (and (>= 1.10.0) :with-test))
  (eio_main :with-test)))
(using mdx 0.1)
