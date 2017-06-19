module M = Module
module Edge = Deps.Edge
module P = Paths.Pkg
module Out = Outliner
module Y = Summary

let debug fmt =
  Pp.(fp err) ("Debug:" ^^ fmt ^^ "@.")

type answer = Out.answer =
  | M of Module.m
  | Namespace of { name:Name.t; modules:Module.dict }

type context =
  | Signature of M.signature
  | In_namespace of M.dict

module Query = struct

  type 'a t = 'a Outliner.query_result
  let pure main = { Outliner.main; msgs = [] }
  let (++) (query:_ t) fault = { query with msgs = fault :: query.msgs }
  let create main msgs : _ t = {main; msgs}
  let fmap f (q: _ t) : _ t = { q with main = f q.main }
  let (>>=) (x: _ t) f: _ t =
    let {main;msgs}: _ t = f x.main in
    { main; msgs = msgs @ x.msgs }

  let (>>?) (x: _ t option) f =
    Option.( x >>= fun x ->
             f x.main >>| fun q ->
             { q with Out.msgs = q.Out.msgs @ x.msgs }
           )

  let add_msg msgs (q: _ t) = { q with msgs = msgs @ q.msgs }

end

type negative_membership = Not_found | Negative
type module_provider = Name.t -> (Module.t Query.t, negative_membership) result

let to_context s = Signature (Exact (M.Def.modules s) )

module Core = struct

  type t = {
    top: M.Dict.t;
    current: context;
    deps: Edge.t P.Map.t ref;
    providers: module_provider list;
  }

  let start s =
    { top = s; current = to_context s;
      deps = ref P.Map.empty;
      providers = []
    }

  module D = struct
    let path_record edge p env =
      env.deps := Deps.update p edge !(env.deps)

    let phantom_record name env =
      path_record Edge.Normal { P.source = Unknown; file = [name] } env

    let ambiguity name breakpoint =
      let f = Standard_faults.ambiguous in
      { f  with
        Fault.log = (fun lvl l -> f.log lvl l name breakpoint)
      }

    let record edge root env (m:Module.m) =
      match m.origin with
      | M.Origin.Unit p ->
        path_record edge p env; []
      | Phantom (phantom_root, b) ->
        if root && not phantom_root then
          (phantom_record m.name env; [ambiguity m.name b] ) else []
      | _ -> []
  end open D

  let request name env =
    debug "asking auxiliary definition sources for %s" name;
    let rec request name  = function
      | [] -> debug "end of auxiliary sources"; None
      | f :: q ->
        debug "new aux source";
        match f name with
        | Ok q -> Some q
        | Error Negative -> None
        | Error Not_found -> request name q in
    request name env.providers


  let proj lvl def = match lvl with
    | M.Module -> def.M.modules
    | M.Module_type -> def.module_types


  (* compute if the level of the root of the path is
     at level module
  *)
  let record_level level = function
    | _ :: _ :: _ -> true
    | [_] -> level = M.Module
    | [] -> false

  let adjust_level level = function
    | [] -> level
    | _ :: _ -> M.Module

  let is_unit = function
    |{ M.origin = M.Origin.Unit _ ; _ } -> true
    | _ -> false

  let restrict env context = { env with current = context }
  let top env =
    { env with current = Signature (Exact (M.Def.modules env.top) ) }

  let find_opt name m =
    match Name.Map.find name m with
    | exception Not_found -> None
    | x -> Some x

  let rec find_name level name current =
    match current with
    | Signature Module.Blank -> None
    | In_namespace modules ->
      if level = M.Module_type then None
      else Option.fmap Query.pure @@ find_opt name modules
    | Signature Exact def ->
      Option.fmap Query.pure @@ find_opt name @@ proj level def
    | Signature Divergence d ->
      (* If we have a divergent signature, we first look
         at the signature after the divergence: *)
      match find_opt name @@ proj level d.after with
      | Some x -> Some(Query.pure x)
      | None ->
        let open Query in
        (* We then try to find the searched name in the signature
           before the divergence *)
        find_name level name (Signature d.before) >>? fun q ->
        Some (Query.create (Module.spirit_away d.point q) [ambiguity name d.point])
  (* If we found the expected name before the divergence,
     we add a new message to the message stack, and return
     the found module, after marking it as a phantom module. *)

  let rec find ?(edge=Edge.Normal) ~root level path env =
    debug "looking for %a" Paths.S.pp path;
    match path with
    | [] ->
      raise (Invalid_argument "Envt.find cannot find empty path")
    | a :: q ->
      let open Query in
      Option.(find_name (adjust_level level q) a env.current
              ||| lazy (request a env))
      >>? function
      | Alias { weak = true; _ } -> None
      | Alias {path; phantom; name; weak= false } ->
        let msgs =
          match phantom with
          | None -> []
          | Some b ->
            if root then
              (phantom_record name env; [ambiguity name b])
            else [] in
        (* aliases link only to compilation units *)
        Option.(
          find ~root:true ~edge
            level (Namespaced.flatten path @ q) (top env)
          >>| Query.add_msg msgs
        )
      | M.M m ->
        debug "found module %s" m.name;
        begin
          let faults = record edge root env m in
          if q = [] then
            Some ((create (M m) faults))
          else
            find  ~root:false level q
            @@ restrict env @@ Signature m.signature
        end
      | Namespace {name;modules} ->
        begin
          (*          let faults = record edge root env name in*)
          if q = [] then
            Some (Query.pure (Namespace {name;modules}))
          else
            find ~root:true level q
            @@ restrict env @@ In_namespace modules

        end

  let find ?edge level path envt =
    match find ?edge ~root:true level path envt with
    | None -> raise Not_found
    | Some x -> x

    let deps env = !(env.deps)
    let reset_deps env = env.deps := P.Map.empty

  let to_sign = function
    | Signature s -> s
    | In_namespace modules ->
      M.Exact { M.Def.empty with modules }

  let (>>) env def =
    restrict env @@
    Signature (Y.extend (to_sign env.current) (Y.strenghen def))

  let add_unit env ?(namespace=[]) x =
    let m: Module.t = M.with_namespace namespace x in
    let t = Name.Map.add  (M.name m)  m env.top in
    top { env with top = t }

  let pp_context ppf = function
    | In_namespace modules ->
      Pp.fp ppf "namespace [%a]@." Module.pp_mdict modules
    | Signature sg -> Pp.fp ppf "[%a]@." Module.pp_signature sg

  let add_namespace env (nms:Namespaced.t) =
    Pp.(fp err) "@[<v 2>Adding %a@; to %a@]@." Namespaced.pp nms pp_context
      env.current;
    if nms.namespace = [] then env else
    let t = M.Dict.( union env.top @@ of_list [Module.namespace nms] ) in
    debug "result: %a" pp_context env.current;
    top { env with top = t }

  let rec resolve_alias_md path def =
    match path with
    | [] -> None
    | a :: q ->
      match Name.Map.find a def with
      | M.Alias {path; weak = false; _ } -> Some path
      | M.Alias { weak = true; _ } -> None
      | M m -> resolve_alias_sign q m.signature
      | Namespace n -> resolve_alias_md q n.modules
      | exception Not_found -> None
  and resolve_alias_sign path = function
    | Blank -> None
    | Exact s -> resolve_alias_md path s.modules
    | Divergence d ->
      match resolve_alias_md path d.after.modules with
      | Some _ as r -> r
      | None ->
        (* FIXME: Should we warn here? *)
        resolve_alias_sign path d.before

  let resolve_alias path env =
    match env.current with
    | In_namespace md -> resolve_alias_md path md
    | Signature sg -> resolve_alias_sign path sg

  let is_exterior path envt =
    match path with
    | [] -> false (* should not happen *)
    | a :: _ ->
      match find_name Module a envt.current with
      | None -> false
      | Some m ->
        match m.main with
        | M { origin = Unit _; _ } -> true
        | M.Alias _ -> false
        | exception Not_found -> true
        | _ -> false

end

let mask fileset request =
   debug "masked file %s:%b" request (Name.Set.mem request fileset);
  if Name.Set.mem request fileset then
    Error Negative
  else
    Error Not_found


let approx name =
  Module.mockup name ~path:{Paths.P.source=Unknown; file=[name]}

let open_world request =
  debug "open world: requesting %s" request;
  Ok (Query.pure @@ M.M(approx request))

module Libraries = struct

  type source = {
    origin: Paths.Simple.t;
    mutable resolved: Core.t;
    cmis: P.t Name.map
  }


  let read_dir dir =
    let files = Sys.readdir dir in
    let origin = Paths.S.parse_filename dir in
    let cmis_map =
      Array.fold_left (fun m x ->
          if Filename.check_suffix x ".cmi" then
            let p = {P.source = P.Pkg origin; file = Paths.S.parse_filename x} in
            Name.Map.add (P.module_name p) p m
          else m
        )
        Name.Map.empty files in
    { origin; resolved= Core.start Name.Map.empty; cmis= cmis_map }

  type t = source list

  let create includes =  List.map read_dir includes

  module I = Outliner.Make(Core)(struct
      let policy = Standard_policies.quiet
      let transparent_aliases = false
      (* we are not recording anything *)
      let transparent_extension_nodes = false
      (* extension nodes should not appear in cmi *)
      let epsilon_dependencies = false
      (* do no try epsilon dependencies yet *)
    end)


  let rec track source stack = match stack with
    | [] -> ()
    | (name, path, code) :: q ->
      match I.m2l path source.resolved code with
      | Error code ->
        begin match M2l.Block.m2l code with
          | None -> assert false
          | Some { data = _y, bl_path ; _ } ->
            let name' = List.hd bl_path in
            let path' = Name.Map.find name' source.cmis in
            let code' = Cmi.m2l @@ P.filename path' in
            track source ( (name', path', code') :: (name, path, code) :: q )
        end
      | Ok (_, sg) ->
        let md = M.create
            ~origin:(M.Origin.Unit path) name sg in
        source.resolved <- Core.add_unit source.resolved (M.M md);
        track source q

  let rec pkg_find name source =
    match Core.find_name M.Module name source.resolved.current with
    | Some {main = M.M { origin = Unit { source = Unknown; _ }; _ }; _ } ->
      raise Not_found
    | None ->
      let path = Name.Map.find name source.cmis in
      track source
        [name, path, Cmi.m2l @@ P.filename path ];
      pkg_find name source
    | Some m -> m.Out.main

  let rec pkgs_find name = function
    | [] -> raise Not_found
    | source :: q ->
      try
        let m = pkg_find name source in
        m
      with Not_found ->
        pkgs_find name q

  let provider libs =
    let pkgs = create libs in
    fun name ->
      debug "library layer: requesting %s" name;
      match pkgs_find name pkgs with
      | exception Not_found -> Error Not_found
      | q -> Ok (Query.pure q)
end

let start ?(open_approximation=true) root_sets libs predefs =
  let core = Core.start predefs in
  let providers =
    [ mask root_sets; Libraries.provider libs] @
    (if open_approximation  then [open_world] else [] ) in
  { core with providers }
