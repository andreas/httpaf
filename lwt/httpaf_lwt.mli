open Httpaf

module type Protocol = sig
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

module Upgradable_reqd : sig
  type t
end

(* The function that results from [create_connection_handler] should be passed
   to [Lwt_io.establish_server_with_client_socket]. For an example, see
   [examples/lwt_echo_server.ml]. *)
module Server : sig
  val create_connection_handler
    :  ?config         : Config.t
    -> request_handler : (Unix.sockaddr -> Upgradable_reqd.t -> unit)
    -> error_handler   : (Unix.sockaddr -> Server_connection.error_handler)
    -> Unix.sockaddr
    -> Lwt_unix.file_descr
    -> unit Lwt.t
end

(* For an example, see [examples/lwt_get.ml]. *)
module Client : sig
  val request
    :  ?config          : Httpaf.Config.t
    -> Lwt_unix.file_descr
    -> Request.t
    -> error_handler    : Client_connection.error_handler
    -> response_handler : Client_connection.response_handler
    -> [`write] Httpaf.Body.t
end
