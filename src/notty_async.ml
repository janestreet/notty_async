open! Base
open! Async

include struct
  open Notty
  module Unescape = Unescape
  module Tmachine = Tmachine
end

module Winch_listener = struct
  let waiting = ref []

  external winch_number : unit -> int = "caml_notty_winch_number" [@@noalloc]

  let sigwinch = Async.Signal.of_caml_int (winch_number ())

  let setup_winch =
    lazy
      (Signal.handle [ sigwinch ] ~f:(fun (_ : Signal.t) ->
         List.iter !waiting ~f:(fun i -> Ivar.fill_exn i ());
         waiting := []))
  ;;

  let winch () =
    force setup_winch;
    let i = Ivar.create () in
    waiting := i :: !waiting;
    Ivar.read i
  ;;
end

module Terminal_info = struct
  type t =
    { capabilities : Core_unix.File_descr.t -> Notty.Cap.t
    ; dimensions : Core_unix.File_descr.t -> (int * int) option
    ; wait_for_next_window_change : unit -> unit Deferred.t
    ; is_a_tty : Fd.t -> bool Deferred.t
    }

  let create ~capabilities ~dimensions ~wait_for_next_window_change ~is_a_tty =
    { capabilities; dimensions; wait_for_next_window_change; is_a_tty }
  ;;

  let real =
    create
      ~capabilities:Notty_unix.Private.cap_for_fd
      ~dimensions:Notty_unix.winsize
      ~wait_for_next_window_change:Winch_listener.winch
      ~is_a_tty:Unix.isatty
  ;;
end

module Term = struct
  let bsize = 1024

  (* Call [f] function repeatedly as input is received from the
     stream. *)
  let input_pipe ~nosig reader =
    let (`Revert revert) =
      let fd = Unix.Fd.file_descr_exn (Reader.fd reader) in
      Notty_unix.Private.setup_tcattr ~nosig fd
    in
    let flt = Notty.Unescape.create () in
    let ibuf = Bytes.create bsize in
    let r, w = Pipe.create () in
    let rec loop () =
      match Unescape.next flt with
      | #Unescape.event as r ->
        (* As long as there are events to read without blocking, dump
           them all into the pipe. *)
        if Pipe.is_closed w
        then return ()
        else (
          Pipe.write_without_pushback w r;
          loop ())
      | `End -> return ()
      | `Await ->
        (* Don't bother issuing a new read until the pipe has space to
           write *)
        let%bind () = Pipe.pushback w in
        (match%bind Reader.read reader ibuf with
         | `Eof ->
           (* When stdin reaches `Eof, we also close the [events] pipe. *)
           Pipe.close w;
           return ()
         | `Ok n ->
           Unescape.input flt ibuf 0 n;
           loop ())
    in
    (* Some error handling to make sure that we call revert if the pipe fails *)
    let monitor = Monitor.create ~here:[%here] ~name:"Notty input pipe" () in
    don't_wait_for (Deferred.ignore_m (Monitor.get_next_error monitor) >>| revert);
    don't_wait_for (Scheduler.within' ~monitor loop);
    don't_wait_for (Pipe.closed r >>| revert);
    r
  ;;

  type t =
    { writer : Writer.t
    ; tmachine : Tmachine.t
    ; buf : Buffer.t
    ; fds : Fd.t * Fd.t
    ; events : [ Unescape.event | `Resize of int * int ] Pipe.Reader.t
    ; stop : unit -> unit
    }

  let write t =
    Buffer.clear t.buf;
    Tmachine.output t.tmachine t.buf;
    Writer.write t.writer (Buffer.contents t.buf);
    Writer.flushed t.writer
  ;;

  let refresh t =
    Tmachine.refresh t.tmachine;
    write t
  ;;

  let image t image =
    Tmachine.image t.tmachine image;
    write t
  ;;

  let cursor t curs =
    Tmachine.cursor t.tmachine curs;
    write t
  ;;

  let set_size t dim = Tmachine.set_size t.tmachine dim
  let size t = Tmachine.size t.tmachine
  let dead t = Tmachine.dead t.tmachine

  let release t =
    if Tmachine.release t.tmachine
    then (
      t.stop ();
      write t)
    else return ()
  ;;

  let resize_pipe_and_update_tmachine
    ~is_a_tty
    ~terminal_dimensions
    ~wait_for_next_window_change
    tmachine
    writer
    =
    let r, w = Pipe.create () in
    don't_wait_for
      (match%bind is_a_tty (Writer.fd writer) with
       | false ->
         Pipe.close w;
         return ()
       | true ->
         let rec loop () =
           let%bind () = wait_for_next_window_change () in
           match Fd.with_file_descr (Writer.fd writer) terminal_dimensions with
           | `Already_closed | `Error _ -> return ()
           | `Ok size ->
             (match size with
              | None ->
                (* Note 100% clear that this is the right behavior,
                 since it's not clear why one would receive None from
                 winsize at all.  In any case, causing further resizes
                 should cause an app to recover if there's a temporary
                 inability to read the size. *)
                loop ()
              | Some size ->
                if Pipe.is_closed w
                then return ()
                else (
                  Tmachine.set_size tmachine size;
                  let%bind () = Pipe.write w (`Resize size) in
                  loop ()))
         in
         let%map () = loop () in
         Pipe.close w);
    r
  ;;

  let create
    ?(dispose = true)
    ?(nosig = true)
    ?(mouse = true)
    ?(bpaste = true)
    ?(reader = force Reader.stdin)
    ?(writer = force Writer.stdout)
    ?(for_mocking = Terminal_info.real)
    ()
    =
    let { Terminal_info.capabilities; dimensions; is_a_tty; wait_for_next_window_change } =
      for_mocking
    in
    let cap, size =
      Fd.with_file_descr_exn (Writer.fd writer) (fun fd -> capabilities fd, dimensions fd)
    in
    let tmachine = Tmachine.create ~mouse ~bpaste cap in
    let input_pipe = input_pipe ~nosig reader in
    let resize_pipe =
      resize_pipe_and_update_tmachine
        ~is_a_tty
        ~terminal_dimensions:dimensions
        ~wait_for_next_window_change
        tmachine
        writer
    in
    let events =
      Pipe.interleave ~close_on:`Any_input_closed [ input_pipe; resize_pipe ]
    in
    let stop () = Pipe.close_read events in
    let buf = Buffer.create 4096 in
    let fds = Reader.fd reader, Writer.fd writer in
    let t = { tmachine; writer; events; stop; buf; fds } in
    Option.iter size ~f:(set_size t);
    if dispose then Shutdown.at_shutdown (fun () -> release t);
    don't_wait_for
      (let%bind () = Pipe.closed events in
       release t);
    let%map () = write t in
    t
  ;;

  let events t = t.events
end

include Notty_unix.Private.Gen_output (struct
    type fd = Writer.t lazy_t
    and k = unit Deferred.t

    let def = Writer.stdout

    let to_fd w =
      match Fd.with_file_descr (Writer.fd (force w)) Fn.id with
      | `Already_closed | `Error _ -> raise_s [%message "Couldn't obtain FD"]
      | `Ok x -> x
    ;;

    let write fd =
      let (lazy w) = fd in
      fun buf ->
        let bytes = Buffer.contents_bytes buf in
        Writer.write_bytes w bytes ~pos:0 ~len:(Bytes.length bytes);
        Writer.flushed w
    ;;
  end)

module For_mocking = Terminal_info
