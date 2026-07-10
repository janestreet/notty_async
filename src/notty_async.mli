open! Base
open! Async

module For_mocking : sig
  type t

  (** [create] allows you to mock out a Term with ANSI capabilities + a specific optional
      size (specified in (width, height)). This is useful for mocking purposes in non-tty
      scenarios like inside of an expect test without a tty. *)
  val create
    :  capabilities:(Core_unix.File_descr.t -> Notty.Cap.t)
    -> dimensions:(Core_unix.File_descr.t -> (int * int) option)
    -> wait_for_next_window_change:(unit -> unit Deferred.t)
    -> is_a_tty:(Fd.t -> bool Deferred.t)
    -> t
end

module Term : sig
  type t

  val create
    :  ?dispose:bool
    -> ?nosig:bool
    -> ?mouse:bool
    -> ?hover:
         (bool
         [@ocaml.doc
           {| When [true] and [~mouse] is also enabled, enables {e any-event} mouse
               reporting (xterm mode 1003) so that mouse motion without any button pressed
               is reported as [`Hover] events. Defaults to [false] because it can generate
               a large volume of input events. |}])
    -> ?bpaste:bool
    -> ?reader:(Reader.t[@ocaml.doc {| stdin by default |}])
    -> ?writer:(Writer.t[@ocaml.doc {| stdout by default |}])
    -> ?for_mocking:For_mocking.t
    -> unit
    -> t Deferred.t

  val refresh : t -> unit Deferred.t
  val image : t -> Notty.image -> unit Deferred.t
  val writer : t -> Writer.t

  val set_mouse : t -> bool -> unit Deferred.t
  [@@ocaml.doc
    {| Dynamically enable/disable mouse reporting.

        When mouse reporting is disabled, terminals typically allow native text selection.
        When enabled, the terminal will send mouse events on stdin (e.g. for clicks). |}]

  val set_hover : t -> bool -> unit Deferred.t
  [@@ocaml.doc
    {| Dynamically enable/disable {e any-event} mouse reporting.

        When enabled, the terminal reports mouse motion without any button pressed as
        [`Hover] events, as long as ordinary mouse reporting is also enabled. Disabling
        hover does not disable ordinary mouse events. |}]

  type cursor :=
    [ `Default
    | `Bar
    | `Bar_blinking
    | `Block
    | `Block_blinking
    | `Underline
    | `Underline_blinking
    ]

  val cursor : t -> (int * int * cursor) option -> unit Deferred.t
  val set_title : t -> string -> unit Deferred.t
  val save_title : t -> unit Deferred.t
  val restore_title : t -> unit Deferred.t
  val size : t -> int * int

  (** Release the terminal, restoring it to a state where ordinary I/O can be performed. *)
  val release : t -> unit Deferred.t

  (** [dead term] returns whether [term] has been released. *)
  val dead : t -> bool

  (** This pipe will automatically be shut down once [release] is called, and closing this
      pipe will asynchronous trigger [release] to be called.

      When the [reader] passed to ?reader is reaches [`Eof], the [events] pipe will close. *)
  val events : t -> [ Notty.Unescape.event | `Resize of int * int ] Pipe.Reader.t
end
