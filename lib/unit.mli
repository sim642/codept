(** Functions for handling unit (aka .ml/.mli) files *)

module Pkg = Paths.Pkg
module Pth = Paths.Simple

type precision =
  | Exact
  | Approx

type t = {
  name : string;
  path : Pkg.t;
  kind : M2l.kind;
  precision: precision;
  code : M2l.t;
  dependencies : Pkg.set;
}
type u = t

val read_file : bool -> M2l.kind -> string -> u
(** [read_file allow_approx kind filename] reads the file [filename],
    extracting the corresponding m2l ast. If the file is not synctatically
    valid Ocaml and [allow_approx=true] the approximative parser is used.
*)

val pp : Format.formatter -> t -> unit

type 'a pair = { ml : 'a; mli : 'a; }
val map: ('a -> 'b) pair -> 'a pair -> 'b pair
val unimap: ('a -> 'b) -> 'a pair -> 'b pair

(** {!Group} handles pair of ml/mli files together *)
module type group =
sig
  type elt
  type ('a,'b) arrow
  exception Collision of { previous:elt; collision:elt}
  type t = elt option pair
  type group = t

  val add_mli : elt -> group -> group
  val add_ml : elt -> group -> group
  val add : (M2l.kind, elt -> group -> group) arrow
  val empty : group
  module Map :
  sig
    type t = group Pth.map
    val add : (M2l.kind , elt -> t -> t) arrow
    val of_list : (M2l.kind, elt list -> t) arrow
  end

  val group : elt list pair -> group Pth.map
  val split : group Pth.map -> elt list pair

end

module type group_core= sig
  type elt
  type ('a,'b) arrow
  val lift: ( (elt ->M2l.kind) -> 'c ) -> (M2l.kind, 'c) arrow
  val key: elt -> Pth.t
end

module Groups: sig

  module Make(Base: group_core):
    group with type elt = Base.elt and type ('a,'b) arrow = ('a,'b) Base.arrow

    module Filename: group with
    type elt = string and type ('a,'b) arrow = 'a -> 'b

  module Unit: group with
    type elt = u and type ('a,'b) arrow = 'b
end


module Set : Set.S with type elt = u
