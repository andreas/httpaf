open Lwt.Infix



(* Based on the Buffer module in httpaf_async.ml. *)
module Buffer : sig
  type t

  val create : int -> t

  val get : t -> f:(Lwt_bytes.t -> off:int -> len:int -> int) -> int
  val put : t -> f:(Lwt_bytes.t -> off:int -> len:int -> int Lwt.t) -> int Lwt.t
end = struct
  type t =
    { buffer      : Lwt_bytes.t
    ; mutable off : int
    ; mutable len : int }

  let create size =
    let buffer = Lwt_bytes.create size in
    { buffer; off = 0; len = 0 }

  let compress t =
    if t.len = 0
    then begin
      t.off <- 0;
      t.len <- 0;
    end else if t.off > 0
    then begin
      Lwt_bytes.blit t.buffer t.off t.buffer 0 t.len;
      t.off <- 0;
    end

  let get t ~f =
    let n = f t.buffer ~off:t.off ~len:t.len in
    t.off <- t.off + n;
    t.len <- t.len - n;
    if t.len = 0
    then t.off <- 0;
    n

  let put t ~f =
    compress t;
    f t.buffer ~off:(t.off + t.len) ~len:(Lwt_bytes.length t.buffer - t.len)
    >>= fun n ->
    t.len <- t.len + n;
    Lwt.return n
end

let read fd buffer =
  Lwt.catch
    (fun () ->
      Buffer.put buffer ~f:(fun bigstring ~off ~len ->
        Lwt_bytes.read fd bigstring off len))
    (function
    | Unix.Unix_error (Unix.EBADF, _, _) as exn ->
      Lwt.fail exn
    | exn ->
      Lwt.async (fun () ->
        Lwt_unix.close fd);
      Lwt.fail exn)

  >>= fun bytes_read ->
  if bytes_read = 0 then
    Lwt.return `Eof
  else
    Lwt.return (`Ok bytes_read)



let shutdown socket command =
  try Lwt_unix.shutdown socket command
  with Unix.Unix_error (Unix.ENOTCONN, _, _) -> ()

module Config = Httpaf.Config

module type Protocol = sig
  open Httpaf

  type t

  val next_read_operation : t -> [ `Read | `Yield | `Close ]

  val read : t -> Bigstring.t -> off:int -> len:int -> int

  val read_eof : t -> Bigstring.t -> off:int -> len:int -> int

  val yield_reader : t -> (unit -> unit) -> unit

  val next_write_operation : t -> [
    | `Write of Bigstring.t IOVec.t list
    | `Yield
    | `Close of int ]

  val report_write_result : t -> [`Ok of int | `Closed] -> unit

  val yield_writer : t -> (unit -> unit) -> unit

  val report_exn : t -> exn -> unit
end

type 'a protocol = (module Protocol with type t = 'a)

module Upgradable_reqd = struct
  open Httpaf

  type t = T : {
    reqd    : Reqd.t;
    upgrade : 'a protocol -> 'a -> unit;
  } -> t

  let create reqd upgrade =
    T { reqd; upgrade }
end

module Upgradable_connection = struct
  open Httpaf

  type io_handler = IOHandler : 'a protocol * 'a -> io_handler

  type t = {
    mutable io_handler : io_handler;
  }

  let upgrade_protocol t protocol' t' =
    t.io_handler <- IOHandler (protocol', t')

  let create ?config ?error_handler request_handler =
    let rec t = lazy {
      io_handler = IOHandler ((module Server_connection), Server_connection.create ?config ?error_handler request_handler')
    }
    and request_handler' reqd =
      let reqd' = Upgradable_reqd.create reqd (upgrade_protocol Lazy.(force t)) in
      request_handler reqd'
    in
    Lazy.force t

  let next_read_operation { io_handler = IOHandler((module P), t) } =
    P.next_read_operation t

  let read { io_handler = IOHandler((module P), t) } =
    P.read t

  let read_eof { io_handler = IOHandler((module P), t) } =
    P.read_eof t

  let yield_reader { io_handler = IOHandler((module P), t) } =
    P.yield_reader t

  let next_write_operation { io_handler = IOHandler((module P), t) } =
    P.next_write_operation t

  let report_write_result { io_handler = IOHandler((module P), t) } =
    P.report_write_result t

  let yield_writer { io_handler = IOHandler((module P), t) } =
    P.yield_writer t

  let report_exn { io_handler = IOHandler((module P), t) } =
    P.report_exn t
end

module Server = struct
  let server_loop connection socket ~read_buffer =
    let read_loop_exited, notify_read_loop_exited = Lwt.wait () in

    let rec read_loop () =
      let rec read_loop_step () =
        match Upgradable_connection.next_read_operation connection with
        | `Read ->
          read socket read_buffer >>= begin function
          | `Eof ->
            Buffer.get read_buffer ~f:(fun bigstring ~off ~len ->
              Upgradable_connection.read_eof connection bigstring ~off ~len)
            |> ignore;
            read_loop_step ()
          | `Ok _ ->
            Buffer.get read_buffer ~f:(fun bigstring ~off ~len ->
              Upgradable_connection.read connection bigstring ~off ~len)
            |> ignore;
            read_loop_step ()
          end

        | `Yield ->
          Upgradable_connection.yield_reader connection read_loop;
          Lwt.return_unit

        | `Close ->
          Lwt.wakeup_later notify_read_loop_exited ();
          if not (Lwt_unix.state socket = Lwt_unix.Closed) then begin
            shutdown socket Unix.SHUTDOWN_RECEIVE
          end;
          Lwt.return_unit
      in

      Lwt.async (fun () ->
        Lwt.catch
          read_loop_step
          (fun exn ->
            Upgradable_connection.report_exn connection exn;
            Lwt.return_unit))
    in


    let writev = Faraday_lwt_unix.writev_of_fd socket in
    let write_loop_exited, notify_write_loop_exited = Lwt.wait () in

    let rec write_loop () =
      let rec write_loop_step () =
        match Upgradable_connection.next_write_operation connection with
        | `Write io_vectors ->
          writev io_vectors >>= fun result ->
          Upgradable_connection.report_write_result connection result;
          write_loop_step ()

        | `Yield ->
          Upgradable_connection.yield_writer connection write_loop;
          Lwt.return_unit

        | `Close _ ->
          Lwt.wakeup_later notify_write_loop_exited ();
          if not (Lwt_unix.state socket = Lwt_unix.Closed) then begin
            shutdown socket Unix.SHUTDOWN_SEND
          end;
          Lwt.return_unit
      in

      Lwt.async (fun () ->
        Lwt.catch
          write_loop_step
          (fun exn ->
            Upgradable_connection.report_exn connection exn;
            Lwt.return_unit))
    in


    read_loop ();
    write_loop ();
    Lwt.join [read_loop_exited; write_loop_exited] >>= fun () ->

    if Lwt_unix.state socket <> Lwt_unix.Closed then
      Lwt.catch
        (fun () -> Lwt_unix.close socket)
        (fun _exn -> Lwt.return_unit)
    else
      Lwt.return_unit

  let create_connection_handler ?(config=Config.default) ~request_handler ~error_handler =
    fun client_addr socket ->
      let module Server_connection = Httpaf.Server_connection in
      let connection =
        Upgradable_connection.create
          ~config
          ~error_handler:(error_handler client_addr)
          (request_handler client_addr)
      in
      let read_buffer = Buffer.create config.read_buffer_size in
      server_loop connection socket ~read_buffer
end



module Client = struct
  let request ?(config=Config.default) socket request ~error_handler ~response_handler =
    let module Client_connection = Httpaf.Client_connection in
    let request_body, connection =
      Client_connection.request ~config request ~error_handler ~response_handler in


    let read_buffer = Buffer.create config.read_buffer_size in
    let read_loop_exited, notify_read_loop_exited = Lwt.wait () in

    let read_loop () =
      let rec read_loop_step () =
        match Client_connection.next_read_operation connection with
        | `Read ->
          read socket read_buffer >>= begin function
          | `Eof ->
            Buffer.get read_buffer ~f:(fun bigstring ~off ~len ->
              Client_connection.read_eof connection bigstring ~off ~len)
            |> ignore;
            read_loop_step ()
          | `Ok _ ->
            Buffer.get read_buffer ~f:(fun bigstring ~off ~len ->
              Client_connection.read connection bigstring ~off ~len)
            |> ignore;
            read_loop_step ()
          end

        | `Close ->
          Lwt.wakeup_later notify_read_loop_exited ();
          if not (Lwt_unix.state socket = Lwt_unix.Closed) then begin
            shutdown socket Unix.SHUTDOWN_RECEIVE
          end;
          Lwt.return_unit
      in

      Lwt.async (fun () ->
        Lwt.catch
          read_loop_step
          (fun exn ->
            Client_connection.report_exn connection exn;
            Lwt.return_unit))
    in


    let writev = Faraday_lwt_unix.writev_of_fd socket in
    let write_loop_exited, notify_write_loop_exited = Lwt.wait () in

    let rec write_loop () =
      let rec write_loop_step () =
        match Client_connection.next_write_operation connection with
        | `Write io_vectors ->
          writev io_vectors >>= fun result ->
          Client_connection.report_write_result connection result;
          write_loop_step ()

        | `Yield ->
          Client_connection.yield_writer connection write_loop;
          Lwt.return_unit

        | `Close _ ->
          Lwt.wakeup_later notify_write_loop_exited ();
          if not (Lwt_unix.state socket = Lwt_unix.Closed) then begin
            shutdown socket Unix.SHUTDOWN_SEND
          end;
          Lwt.return_unit
      in

      Lwt.async (fun () ->
        Lwt.catch
          write_loop_step
          (fun exn ->
            Client_connection.report_exn connection exn;
            Lwt.return_unit))
    in


    read_loop ();
    write_loop ();

    Lwt.async (fun () ->
      Lwt.join [read_loop_exited; write_loop_exited] >>= fun () ->

      if Lwt_unix.state socket <> Lwt_unix.Closed then
        Lwt.catch
          (fun () -> Lwt_unix.close socket)
          (fun _exn -> Lwt.return_unit)
      else
        Lwt.return_unit);

    request_body
end
