(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Expression
open Pyre
open PyreParser


module Record = struct
  module Callable = struct
    module RecordParameter = struct
      type 'annotation named = {
        name: Access.t;
        annotation: 'annotation;
        default: bool;
      }
      [@@deriving compare, sexp, show, hash]


      type 'annotation anonymous = {
        index: int;
        annotation: 'annotation;
      }
      [@@deriving compare, eq, sexp, show, hash]


      let equal_named equal_annotation left right =
        left.default = right.default &&
        Access.equal (Access.sanitized left.name) (Access.sanitized right.name) &&
        equal_annotation left.annotation right.annotation


      type 'annotation t =
        | Anonymous of 'annotation anonymous
        | Named of 'annotation named
        | Variable of 'annotation named
        | Keywords of 'annotation named
      [@@deriving compare, eq, sexp, show, hash]
    end


    type kind =
      | Anonymous
      | Named of Access.t


    and 'annotation parameters =
      | Defined of ('annotation RecordParameter.t) list
      | Undefined


    and 'annotation overload = {
      annotation: 'annotation;
      parameters: 'annotation parameters;
    }


    and implicit =
      | Class
      | Instance
      | Function


    and 'annotation record = {
      kind: kind;
      implementation: 'annotation overload;
      overloads: ('annotation overload) list;
      implicit: implicit;
    }
    [@@deriving compare, eq, sexp, show, hash]


    let equal_record equal_annotation left right =
      (* Ignores implicit argument to simplify unit tests. *)
      equal_kind left.kind right.kind &&
      equal_overload equal_annotation left.implementation right.implementation &&
      List.equal ~equal:(equal_overload equal_annotation) left.overloads right.overloads
  end
end


open Record.Callable


module Parameter = Record.Callable.RecordParameter


type tuple =
  | Bounded of t list
  | Unbounded of t


and constraints =
  | Bound of t
  | Explicit of t list
  | Unconstrained


and typed_dictionary_field = {
  name: string;
  annotation: t;
}


and t =
  | Bottom
  | Callable of t Record.Callable.record
  | Deleted
  | Object
  | Optional of t
  | Parametric of { name: Identifier.t; parameters: t list }
  | Primitive of Identifier.t
  | Top
  | Tuple of tuple
  | TypedDictionary of { name: Identifier.t; fields: typed_dictionary_field list }
  | Union of t list
  | Variable of { variable: Identifier.t; constraints: constraints }
[@@deriving compare, eq, sexp, show, hash]


type type_t = t
[@@deriving compare, eq, sexp, show, hash]
let type_compare = compare
let type_sexp_of_t = sexp_of_t
let type_t_of_sexp = t_of_sexp


module Map = Map.Make(struct
    type nonrec t = t
    let compare = compare
    let sexp_of_t = sexp_of_t
    let t_of_sexp = t_of_sexp
  end)


module Set = Set.Make(struct
    type nonrec t = t
    let compare = compare
    let sexp_of_t = sexp_of_t
    let t_of_sexp = t_of_sexp
  end)


include Hashable.Make(struct
    type nonrec t = t
    let compare = compare
    let hash = Hashtbl.hash
    let hash_fold_t = hash_fold_t
    let sexp_of_t = sexp_of_t
    let t_of_sexp = t_of_sexp
  end)


module Cache = struct
  include Hashable.Make(struct
      type nonrec t = Expression.expression
      let compare = Expression.compare_expression
      let hash = Expression.hash_expression
      let hash_fold_t = Expression.hash_fold_expression
      let sexp_of_t = Expression.sexp_of_expression
      let t_of_sexp = Expression.expression_of_sexp
    end)

  let cache =
    Table.create ~size:1023 ()

  let enabled = ref true

  let find element =
    if !enabled then
      Hashtbl.find cache element
    else
      None

  let set ~key ~data =
    if !enabled then
      Hashtbl.set ~key ~data cache
    else
      ()

  let disable () =
    enabled := false;
    Hashtbl.clear cache

  let enable () =
    enabled := true
end


let reverse_substitute name =
  match Identifier.show name with
  | "collections.defaultdict" ->
      Identifier.create "typing.DefaultDict"
  | "dict" ->
      Identifier.create "typing.Dict"
  | "list" ->
      Identifier.create "typing.List"
  | "set" ->
      Identifier.create "typing.Set"
  | "type" ->
      Identifier.create "typing.Type"
  | _ ->
      name


let rec pp format annotation =
  match annotation with
  | Bottom ->
      Format.fprintf format "undefined"
  | Callable { kind; implementation; overloads; _ } ->
      let kind =
        match kind with
        | Anonymous -> ""
        | Named name -> Format.asprintf "(%a)" Access.pp name
      in
      let signature_to_string { annotation; parameters } =
        let parameters =
          match parameters with
          | Undefined ->
              "..."
          | Defined parameters ->
              let parameter = function
                | Parameter.Anonymous { Parameter.index; annotation } ->
                    Format.asprintf
                      "Anonymous(%d, %a)"
                      index
                      pp annotation
                | Parameter.Named { Parameter.name; annotation; default } ->
                    Format.asprintf
                      "Named(%a, %a%s)"
                      Access.pp_sanitized name
                      pp annotation
                      (if default then ", default" else "")
                | Parameter.Variable { Parameter.name; annotation; _ } ->
                    Format.asprintf
                      "Variable(%a, %a)"
                      Access.pp_sanitized name
                      pp annotation
                | Parameter.Keywords { Parameter.name; annotation; _ } ->
                    Format.asprintf
                      "Keywords(%a, %a)"
                      Access.pp_sanitized name
                      pp annotation
              in
              List.map parameters ~f:parameter
              |> String.concat ~sep:", "
              |> fun parameters -> Format.asprintf "[%s]" parameters
        in
        Format.asprintf "%s, %a" parameters pp annotation
      in
      let implementation = signature_to_string implementation in
      let overloads =
        let overloads = List.map overloads ~f:signature_to_string in
        if List.is_empty overloads then
          ""
        else
          String.concat ~sep:"][" overloads
          |> Format.sprintf "[[%s]]"
      in
      Format.fprintf format "typing.Callable%s[%s]%s" kind implementation overloads
  | Deleted ->
      Format.fprintf format "deleted"
  | Object ->
      Format.fprintf format "typing.Any"
  | Optional Bottom ->
      Format.fprintf format "None"
  | Optional parameter ->
      Format.fprintf format "typing.Optional[%a]" pp parameter
  | Parametric { name; parameters }
    when (Identifier.show name = "typing.Optional" or Identifier.show name = "Optional") &&
         parameters = [Bottom] ->
      Format.fprintf format "None"
  | Parametric { name; parameters } ->
      let parameters =
        if List.for_all parameters ~f:(equal Bottom) then
          ""
        else
          List.map parameters ~f:show
          |> String.concat ~sep:", "
      in
      Format.fprintf format
        "%s[%s]"
        (Identifier.show (reverse_substitute name))
        parameters
  | Primitive name ->
      Format.fprintf format "%a" Identifier.pp name
  | Top ->
      Format.fprintf format "unknown"
  | Tuple tuple ->
      let parameters =
        match tuple with
        | Bounded parameters ->
            List.map parameters ~f:show
            |> String.concat ~sep:", "
        | Unbounded parameter  ->
            Format.asprintf "%a, ..." pp parameter
      in
      Format.fprintf format "typing.Tuple[%s]" parameters
  | TypedDictionary { name; fields } ->
      let fields =
        fields
        |> List.map ~f:(fun { name; annotation } -> Format.asprintf "%s: %a" name pp annotation)
        |> String.concat ~sep:", "
      in
      Format.fprintf format
        "TypedDict `%a` with fields (%s)"
        Identifier.pp
        name
        fields
  | Union parameters ->
      Format.fprintf format
        "typing.Union[%s]"
        (List.map parameters ~f:show
         |> String.concat ~sep:", ")
  | Variable { variable; constraints } ->
      let constraints =
        match constraints with
        | Bound bound ->
            Format.asprintf " (bound to %a)" pp bound
        | Explicit constraints ->
            Format.asprintf
              " <: [%a]"
              (Format.pp_print_list ~pp_sep:(fun format () -> Format.fprintf format ", ") pp)
              constraints
        | Unconstrained ->
            ""
      in
      Format.fprintf
        format
        "Variable[%s%s]"
        (Identifier.show variable)
        constraints


and show annotation =
  Format.asprintf "%a" pp annotation


let rec serialize = function
  | Bottom ->
      "$bottom"
  | annotation ->
      Format.asprintf "%a" pp annotation


let primitive name =
  Primitive (Identifier.create name)


let parametric name parameters =
  Parametric { name = Identifier.create name; parameters }


let variable ?(constraints = Unconstrained) name =
  Variable { variable = Identifier.create name; constraints }


let awaitable parameter =
  Parametric {
    name = Identifier.create "typing.Awaitable";
    parameters = [parameter];
  }


let bool =
  Primitive (Identifier.create "bool")


let bytes =
  Primitive (Identifier.create "bytes")


let callable
    ?name
    ?(overloads = [])
    ?(parameters = Undefined)
    ~annotation
    () =
  let kind = name >>| (fun name -> Named name) |> Option.value ~default:Anonymous in
  Callable {
    kind;
    implementation = { annotation; parameters };
    overloads;
    implicit = Function;
  }


let complex =
  Primitive (Identifier.create "complex")


let dictionary ~key ~value =
  Parametric {
    name = Identifier.create "dict";
    parameters = [key; value];
  }


let ellipses =
  Primitive (Identifier.create "ellipses")


let float =
  Primitive (Identifier.create "float")


let generator ?(async=false) parameter =
  let none = Optional Bottom in
  if async then
    Parametric {
      name = Identifier.create "typing.AsyncGenerator";
      parameters = [parameter; none];
    }
  else
    Parametric {
      name = Identifier.create "typing.Generator";
      parameters = [parameter; none; none];
    }


let generic =
  Primitive (Identifier.create "typing.Generic")


let integer =
  Primitive (Identifier.create "int")


let iterable parameter =
  Parametric {
    name = Identifier.create "typing.Iterable";
    parameters = [parameter];
  }


let iterator parameter =
  Parametric {
    name = Identifier.create "typing.Iterator";
    parameters = [parameter];
  }


let lambda ~parameters ~return_annotation =
  Callable {
    kind = Anonymous;
    implementation = {
      annotation = return_annotation;
      parameters =
        Defined
          (List.mapi
             ~f:(fun index parameter ->
                 Parameter.Anonymous { Parameter.index; annotation = parameter })
             parameters);
    };
    overloads = [];
    implicit = Function;
  }


let list parameter =
  Parametric {
    name = Identifier.create "list";
    parameters = [parameter];
  }


let meta annotation =
  let parameter =
    match annotation with
    | Variable _ ->
        Object
    | annotation ->
        annotation
  in
  Parametric {
    name = Identifier.create "type";
    parameters = [parameter];
  }


let named_tuple =
  Primitive (Identifier.create "typing.NamedTuple")


let none =
  Optional Bottom


let rec optional parameter =
  match parameter with
  | Top ->
      Top
  | Deleted ->
      Deleted
  | Object ->
      Object
  | Optional _ ->
      parameter
  | _ ->
      Optional parameter


let sequence parameter =
  Parametric {
    name = Identifier.create "typing.Sequence";
    parameters = [parameter];
  }


let set parameter =
  Parametric {
    name = Identifier.create "set";
    parameters = [parameter];
  }


let string =
  Primitive (Identifier.create "str")


let tuple parameters: t =
  match parameters with
  | [] -> Tuple (Unbounded Object)
  | _ -> Tuple (Bounded parameters)


let undeclared =
  primitive "typing.Undeclared"


let union parameters =
  let parameters =
    let rec flattened parameters =
      let flatten sofar = function
        | Union parameters -> (flattened parameters) @ sofar
        | parameter -> parameter :: sofar
      in
      List.fold ~init:[] ~f:flatten parameters
    in
    let parameters = Set.of_list (flattened parameters) in
    let filter_redundant_annotations sofar annotation =
      match annotation with
      | Primitive _ when  Set.mem parameters (optional annotation) ->
          sofar
      | _ ->
          annotation :: sofar
    in
    Set.fold ~init:[] ~f:filter_redundant_annotations parameters
    |> List.sort ~compare
  in
  if List.mem ~equal parameters Object then
    Object
  else
    let normalize parameters =
      match parameters with
      | [] -> Bottom
      | [parameter] -> parameter
      | parameters -> Union parameters
    in
    if List.exists parameters ~f:(fun parameter -> equal parameter (Optional Bottom)) then
      Optional
        (normalize
           (List.filter
              parameters
              ~f:(fun parameter -> not (equal parameter (Optional Bottom)))))
    else
      normalize parameters


let yield parameter =
  Parametric {
    name = Identifier.create "Yield";
    parameters = [parameter];
  }


let primitive_substitution_map =
  let parametric_anys name number_of_anys =
    let rec parameters sofar remaining =
      match remaining with
      | 0 -> sofar
      | _ -> parameters (Object :: sofar) (remaining - 1)
    in
    Parametric { name = Identifier.create name; parameters = (parameters [] number_of_anys) }
  in
  [
    "$bottom", Bottom;
    "$deleted", Deleted;
    "$unknown", Top;
    "None", none;
    "dict", parametric_anys "dict" 2;
    "list", list Object;
    "object", Object;
    "type", parametric_anys "type" 1;
    "typing.Any", Object;
    "typing.AsyncGenerator", parametric_anys "typing.AsyncGenerator" 2;
    "typing.AsyncIterable", parametric_anys "typing.AsyncIterable" 1;
    "typing.AsyncIterator", parametric_anys "typing.AsyncIterator" 1;
    "typing.Awaitable", parametric_anys "typing.Awaitable" 1;
    "typing.ContextManager", parametric_anys "typing.ContextManager" 1;
    "typing.Coroutine", parametric_anys "typing.Coroutine" 3;
    "typing.DefaultDict", parametric_anys "collections.defaultdict" 2;
    "typing.Dict", parametric_anys "dict" 2;
    "typing.Generator", parametric_anys "typing.Generator" 3;
    "typing.Iterable", parametric_anys "typing.Iterable" 1;
    "typing.Iterator", parametric_anys "typing.Iterator" 1;
    "typing.List", list Object;
    "typing.Mapping", parametric_anys "typing.Mapping" 2;
    "typing.Sequence", parametric_anys "typing.Sequence" 1;
    "typing.Set", parametric_anys "typing.Set" 1;
    "typing.Tuple", Tuple (Unbounded Object);
    "typing.Type", parametric_anys "type" 1;
  ]
  |> List.map
    ~f:(fun (original, substitute) -> Identifier.create original, substitute)
  |> Identifier.Map.of_alist_exn


let parametric_substitution_map =
  [
    "typing.DefaultDict", "collections.defaultdict";
    "typing.Dict", "dict";
    "typing.FrozenSet", "frozenset";
    "typing.List", "list";
    "typing.Set", "set";
    "typing.Type", "type";
  ]
  |> List.map
    ~f:(fun (original, substitute) -> Identifier.create original, Identifier.create substitute)
  |> Identifier.Map.of_alist_exn


let rec create ~aliases { Node.value = expression; _ } =
  match Cache.find expression with
  | Some result ->
      result
  | _ ->
      let rec parse reversed_lead tail =
        let annotation =
          match tail with
          | (Access.Identifier get_item)
            :: (Access.Call { Node.value = [{ Argument.value = argument; _ }]; _ })
            :: _
            when Identifier.show get_item = "__getitem__" ->
              let parameters =
                match Node.value argument with
                | Expression.Tuple elements -> elements
                | _ -> [argument]
              in
              let name =
                List.rev reversed_lead
                |> Access.show
                |> Identifier.create
              in
              Parametric { name; parameters = List.map parameters ~f:(create ~aliases) }
          | (Access.Identifier _ as access) :: tail ->
              parse (access :: reversed_lead) tail
          | [] ->
              let name =
                let sanitized =
                  match reversed_lead with
                  | (Access.Identifier name) :: tail ->
                      let name =
                        Identifier.show_sanitized name
                        |> Identifier.create
                      in
                      (Access.Identifier name) :: tail
                  | _ ->
                      reversed_lead
                in
                List.rev sanitized
                |> Access.show
              in
              if name = "None" then
                none
              else
                Primitive (Identifier.create name)
          | _ ->
              Top
        in

        (* Resolve aliases. *)
        let resolved =
          let rec resolve visited annotation =
            if Set.mem visited annotation then
              annotation
            else
              let visited = Set.add visited annotation in
              match aliases annotation with
              | Some alias ->
                  resolve visited alias
              | _ ->
                  begin
                    match annotation with
                    | Optional annotation ->
                        Optional (resolve visited annotation)
                    | Tuple (Bounded elements) ->
                        Tuple (Bounded (List.map elements ~f:(resolve visited)))
                    | Tuple (Unbounded annotation) ->
                        Tuple (Unbounded (resolve visited annotation))
                    | Parametric { name; parameters } ->
                        begin
                          let parametric name =
                            Parametric {
                              name;
                              parameters = List.map parameters ~f:(resolve visited);
                            }
                          in
                          match aliases (Primitive name) with
                          | Some (Primitive name) ->
                              parametric name
                          | Some (Parametric { name; _ }) ->
                              (* Ignore parameters for now. *)
                              parametric name
                          | Some (Union elements) ->
                              let replace_parameters = function
                                | Parametric parametric -> Parametric { parametric with parameters }
                                | annotation -> annotation
                              in
                              Union (List.map elements ~f:replace_parameters)
                          | _ ->
                              parametric name
                        end
                    | Variable ({ constraints; _ } as variable) ->
                        let constraints =
                          match constraints with
                          | Bound bound ->
                              Bound (resolve visited bound)
                          | Explicit constraints ->
                              Explicit (List.map constraints ~f:(resolve visited))
                          | Unconstrained ->
                              Unconstrained
                        in
                        Variable { variable with constraints }
                    | TypedDictionary { fields; name } ->
                        let fields =
                          let resolve_field_annotation { name; annotation } =
                            { name; annotation = resolve visited annotation }
                          in
                          List.map fields ~f:resolve_field_annotation;
                        in
                        TypedDictionary { name; fields }
                    | Union elements ->
                        Union (List.map elements ~f:(resolve visited))
                    | Bottom
                    | Callable _
                    | Deleted
                    | Object
                    | Primitive _
                    | Top ->
                        annotation
                  end
          in
          resolve Set.empty annotation
        in

        (* Substitutions. *)
        match resolved with
        | Primitive name ->
            begin
              match Identifier.Map.find primitive_substitution_map name with
              | Some substitute -> substitute
              | None -> resolved
            end
        | Parametric { name; parameters } ->
            begin
              match Identifier.Map.find parametric_substitution_map name with
              | Some name ->
                  Parametric { name; parameters }
              | None ->
                  begin
                    match Identifier.show name with
                    | "typing.Optional" when List.length parameters = 1 ->
                        optional (List.hd_exn parameters)

                    | "tuple"
                    | "typing.Tuple" ->
                        let tuple: tuple =
                          match parameters with
                          | [parameter; Primitive ellipses] when Identifier.show ellipses = "..." ->
                              Unbounded parameter
                          | _ -> Bounded parameters
                        in
                        Tuple tuple

                    | "typing.Union" ->
                        union parameters

                    | _ ->
                        resolved
                  end
            end
        | Union elements ->
            union elements
        | _ ->
            resolved
      in
      let result =
        let parse_callable ?modifiers ~(signatures: Access.t) () =
          let kind =
            match modifiers with
            | Some ({
                Argument.value = { Node.value = String { StringLiteral.value; _ }; _ };
                _;
              } :: _) ->
                Named (Access.create value)
            | _ ->
                Anonymous
          in
          let implementation, overloads =
            let undefined = { annotation = Top; parameters = Undefined } in
            let get_signature argument =
              match Node.value argument with
              | Expression.Tuple [parameters; annotation] ->
                  let parameters =
                    let extract_parameter index parameter =
                      match Node.value parameter with
                      | Access [
                          Access.Identifier name;
                          Access.Call { Node.value = arguments; _ };
                        ] ->
                          begin
                            let arguments =
                              List.map
                                arguments
                                ~f:(fun { Argument.value; _ } -> value)
                            in
                            match Identifier.show name, arguments with
                            | "Named",
                              { Node.value = Access name; _ } :: annotation :: tail ->
                                let default =
                                  match tail with
                                  | [{ Node.value = Access [Access.Identifier default]; _ }]
                                    when Identifier.show default = "default" -> true
                                  | _ -> false
                                in
                                Parameter.Named {
                                  Parameter.name;
                                  annotation = create ~aliases annotation;
                                  default;
                                }
                            | "Variable", { Node.value = Access name; _ } :: tail ->
                                let annotation =
                                  match tail with
                                  | annotation :: _ -> create ~aliases annotation
                                  | _ -> Top
                                in
                                Parameter.Variable {
                                  Parameter.name;
                                  annotation;
                                  default = false;
                                }
                            | "Keywords", { Node.value = Access name; _ } :: tail ->
                                let annotation =
                                  match tail with
                                  | annotation :: _ -> create ~aliases annotation
                                  | _ -> Top
                                in
                                Parameter.Keywords {
                                  Parameter.name;
                                  annotation;
                                  default = false;
                                }
                            | _ ->
                                Parameter.Anonymous { Parameter.index; annotation = Top }
                          end
                      | _ ->
                          Parameter.Anonymous {
                            Parameter.index;
                            annotation = (create ~aliases parameter)
                          }
                    in
                    match Node.value parameters with
                    | List parameters ->
                        Defined (List.mapi ~f:extract_parameter parameters)
                    | _ ->
                        Undefined
                  in
                  { annotation = create ~aliases annotation; parameters }
              | _ ->
                  undefined
            in
            match signatures with
            | (Access.Identifier get_item) ::
              (Access.Call { Node.value = [{ Argument.value = argument; _ }]; _ }) ::
              []
              when Identifier.show get_item = "__getitem__" ->
                get_signature argument, []
            | (Access.Identifier get_item) ::
              (Access.Call { Node.value = [{ Argument.value = argument; _ }]; _ }) ::
              (Access.Identifier get_item_overloads) ::
              (Access.Call {
                  Node.value = [
                    { Argument.value = { Node.value = overloads_argument; location }; _ }
                  ];
                  _;
                }) ::
              []
              when Identifier.show get_item = "__getitem__"
                && Identifier.show get_item_overloads = "__getitem__" ->
                let rec parse_overloads overloads =
                  match overloads with
                  | Expression.List arguments ->
                      [get_signature (Node.create ~location (Expression.Tuple arguments))]
                  | Expression.Access
                      (Access.Expression { Node.value = (Expression.List arguments); _ }
                       :: tail) ->
                      get_signature (Node.create ~location (Expression.Tuple arguments))
                      :: (parse_overloads (Access tail))
                  | Expression.Access (
                      Access.Identifier get_item
                      :: Access.Call { Node.value = [{ Argument.value = argument; _ }]; _ }
                      :: tail
                    )
                    when Identifier.show get_item = "__getitem__" ->
                      get_signature argument :: (parse_overloads (Access tail))
                  | Access [] ->
                      []
                  | _ ->
                      [undefined]
                in
                get_signature argument, parse_overloads overloads_argument
            | _ ->
                undefined, []
          in
          Callable { kind; implementation; overloads; implicit = Function }
        in
        match expression with
        | Access [
            Access.Identifier typing;
            Access.Identifier typevar;
            Access.Call ({
                Node.value = {
                  Argument.value = { Node.value = String { StringLiteral.value; _ }; _ };
                  _;
                } :: arguments;
                _;
              });
          ]
          when Identifier.show typing = "typing" && Identifier.show typevar = "TypeVar" ->
            let constraints =
              let explicits =
                let explicit = function
                  | { Argument.value = { Node.value = Access access; _ }; Argument.name = None } ->
                      Some (parse [] access)
                  | _ ->
                      None
                in
                List.filter_map ~f:explicit arguments
              in
              let bound =
                let bound = function
                  | {
                    Argument.value = { Node.value = Access access; _ };
                    Argument.name = Some { Node.value = bound; _ };
                  } when Identifier.show bound = "$parameter$bound" ->
                      Some (parse [] access)
                  | _ ->
                      None
                in
                List.find_map ~f:bound arguments
              in
              if not (List.is_empty explicits) then
                Explicit explicits
              else if Option.is_some bound then
                Bound (Option.value_exn bound)
              else
                Unconstrained
            in
            Variable {
              variable = Identifier.create value;
              constraints;
            }

        | Access
            ((Access.Identifier typing)
             :: (Access.Identifier callable)
             :: (Access.Call { Node.value = modifiers; _ })
             :: signatures)
          when Identifier.show typing = "typing" && Identifier.show callable = "Callable" ->
            parse_callable ~modifiers ~signatures ()
        | Access ((Access.Identifier typing) :: (Access.Identifier callable) :: signatures)
          when Identifier.show typing = "typing" && Identifier.show callable = "Callable" ->
            parse_callable ~signatures ()

        | Access ([
            Access.Identifier mypy_extensions;
            Access.Identifier typed_dictionary;
            Access.Identifier get_item;
            Access.Call({
                Node.value = [{
                    Argument.name = None;
                    value = {
                      Node.value = Expression.Tuple ({
                          Node.value = Expression.String { value = typed_dictionary_name; _ };
                          _;
                        } :: fields);
                      _;
                    };
                  }];
                _;
              });
          ])
          when Identifier.show mypy_extensions = "mypy_extensions" &&
               Identifier.show typed_dictionary = "TypedDict" &&
               Identifier.show get_item  = "__getitem__" ->
            let fields =
              let tuple_to_field =
                function
                | {
                  Node.value = Expression.Tuple [
                      { Node.value = Expression.String { value = field_name; _ }; _ };
                      field_annotation;
                    ];
                  _;
                } ->
                    Some { name = field_name; annotation = create field_annotation ~aliases }
                | _ ->
                    None
              in
              fields
              |> List.filter_map ~f:tuple_to_field
            in
            TypedDictionary {
              name = Identifier.create typed_dictionary_name;
              fields;
            }
        | Access access ->
            parse [] access

        | Ellipses ->
            Primitive (Identifier.create "...")

        | String { StringLiteral.value; _ } ->
            let access =
              try
                let parsed =
                  Parser.parse [value]
                  |> Source.create
                  |> Preprocessing.preprocess
                  |> Source.statements
                in
                match parsed with
                | [{ Node.value = Statement.Expression { Node.value = Access access; _ }; _ }] ->
                    access
                | _ ->
                    Access.create value
              with _ ->
                Access.create value
            in
            parse [] access
        | _ ->
            Top
      in
      Cache.set ~key:expression ~data:result;
      result


let rec expression annotation =
  let split name =
    match Identifier.show name with
    | "..." ->
        [Access.Identifier (Identifier.create "...")]
    | name ->
        String.split name ~on:'.'
        |> List.map ~f:Access.create
        |> List.concat
  in

  let get_item_call ?call_parameters parameters =
    let parameter =
      match parameters with
      | _ when List.length parameters > 1 || Option.is_some call_parameters ->
          let tuple =
            let call_parameters =
              call_parameters
              >>| (fun call_parameters -> [call_parameters])
              |> Option.value ~default:[]
            in
            List.map parameters ~f:expression
            |> (fun elements -> Expression.Tuple (call_parameters @ elements))
            |> Node.create_with_default_location
          in
          [{ Argument.name = None; value = tuple }]
      | [parameter] ->
          [{ Argument.name = None; value = expression parameter }]
      | _ ->
          []
    in
    [
      Access.Identifier (Identifier.create "__getitem__");
      Access.Call (Node.create_with_default_location parameter);
    ]
  in

  let rec access annotation =
    match annotation with
    | Bottom -> Access.create "$bottom"
    | Callable { implementation; overloads; _ } ->
        let convert { annotation; parameters } =
          let call_parameters =
            match parameters with
            | Defined parameters ->
                let parameter parameter =
                  let call ?(default = false) name argument annotation =
                    let annotation =
                      annotation
                      >>| (fun annotation ->
                          [{
                            Argument.name = None;
                            value = expression annotation;
                          }])
                      |> Option.value ~default:[]
                    in
                    let arguments =
                      let default =
                        if default then
                          [
                            {
                              Argument.name = None;
                              value = Access.expression (Access.create "default");
                            };
                          ]
                        else
                          []
                      in
                      [{ Argument.name = None; value = Access.expression argument }]
                      @ annotation @ default
                    in
                    Access.expression
                      (Access.call ~arguments ~location:Location.Reference.any ~name ())
                  in
                  match parameter with
                  | Parameter.Anonymous { Parameter.annotation; _ } ->
                      expression annotation
                  | Parameter.Keywords { Parameter.name; annotation; _ } ->
                      call "Keywords" name (Some annotation)
                  | Parameter.Named { Parameter.name; annotation; default } ->
                      call "Named" ~default name (Some annotation)
                  | Parameter.Variable { Parameter.name; annotation; _ } ->
                      call "Variable" name (Some annotation)
                in
                List (List.map parameters ~f:parameter)
                |> Node.create_with_default_location
            | Undefined ->
                Node.create_with_default_location Ellipses
          in
          get_item_call ~call_parameters [annotation]
        in
        let overloads =
          let overloads = List.concat_map overloads ~f:convert in
          if List.is_empty overloads then
            []
          else
            [
              Access.Identifier (Identifier.create "__getitem__");
              Access.Call
                (Node.create_with_default_location [
                    {
                      Argument.name = None;
                      value = Node.create_with_default_location (Access overloads);
                    }
                  ]);
            ]
        in
        (Access.create "typing.Callable") @ (convert implementation) @ overloads
    | Deleted -> Access.create "$deleted"
    | Object -> Access.create "object"
    | Optional Bottom ->
        split (Identifier.create "None")
    | Optional parameter ->
        (Access.create "typing.Optional") @ (get_item_call [parameter])
    | Parametric { name; parameters }
      when Identifier.show name = "typing.Optional" && parameters = [Bottom] ->
        split (Identifier.create "None")
    | Parametric { name; parameters } ->
        (split (reverse_substitute name)) @ (get_item_call parameters)
    | Primitive name ->
        split name
    | Top -> Access.create "$unknown"
    | Tuple elements ->
        let parameters =
          match elements with
          | Bounded parameters -> parameters
          | Unbounded parameter -> [parameter; Primitive (Identifier.create "...")]
        in
        (Access.create "typing.Tuple") @ (get_item_call parameters)
    | TypedDictionary { name; fields; } ->
        let argument =
          let tuple =
            let tail =
              let field_to_tuple { name; annotation } =
                Node.create_with_default_location (Expression.Tuple [
                    Node.create_with_default_location (Expression.String {
                        value = name;
                        kind = StringLiteral.String;
                      });
                    expression annotation;
                  ])
              in
              List.map fields ~f:field_to_tuple
            in
            Expression.String { value = Identifier.show name; kind = StringLiteral.String }
            |> Node.create_with_default_location
            |> (fun name -> Expression.Tuple(name :: tail))
            |> Node.create_with_default_location
          in
          { Argument.name = None; value = tuple; }
        in
        (Access.create "mypy_extensions.TypedDict") @ [
          Access.Identifier (Identifier.create "__getitem__");
          Access.Call (Node.create_with_default_location ([argument]));
        ]
    | Union parameters ->
        (Access.create "typing.Union") @ (get_item_call parameters)
    | Variable { variable; _ } -> split variable
  in

  let value =
    match annotation with
    | Primitive name when Identifier.show name = "..." -> Ellipses
    | _ -> Access (access annotation)
  in
  Node.create_with_default_location value


let access annotation =
  match expression annotation with
  | { Node.value = Access access; _ } -> access
  | _ -> failwith "Annotation expression is not an access"


let rec exists annotation ~predicate =
  if predicate annotation then
    true
  else
    match annotation with
    | Callable { implementation; overloads; _ } ->
        let exists { annotation; parameters } =
          let exists_in_parameters =
            match parameters with
            | Defined parameters ->
                let parameter = function
                  | Parameter.Anonymous { Parameter.annotation; _ }
                  | Parameter.Named { Parameter.annotation; _ } ->
                      exists annotation ~predicate
                  | Parameter.Variable _
                  | Parameter.Keywords _ ->
                      false
                in
                List.exists ~f:parameter parameters
            | Undefined ->
                false
          in
          exists annotation ~predicate || exists_in_parameters
        in
        List.exists ~f:exists (implementation :: overloads)

    | Optional annotation
    | Tuple (Unbounded annotation) ->
        exists ~predicate annotation

    | Variable { constraints; _ } ->
        begin
          match constraints with
          | Bound bound -> exists ~predicate bound
          | Explicit constraints -> List.exists constraints ~f:(exists ~predicate)
          | Unconstrained -> false
        end

    | Parametric { parameters; _ }
    | Tuple (Bounded parameters)
    | Union parameters ->
        List.exists ~f:(exists ~predicate) parameters

    | TypedDictionary { name; fields } ->
        let annotations = List.map fields ~f:(fun { annotation; _ } -> annotation) in
        exists (Primitive name) ~predicate ||
        List.exists annotations ~f:(exists ~predicate)

    | Bottom
    | Deleted
    | Top
    | Object
    | Primitive _ ->
        false


let contains_callable annotation =
  exists annotation ~predicate:(function | Callable _ -> true | _ -> false)


let is_callable = function
  | Callable _ -> true
  | _ -> false


let is_deleted = function
  | Deleted -> true
  | _ -> false


let is_ellipses = function
  | Primitive primitive when Identifier.show primitive = "ellipses" -> true
  | _ -> false


let is_generator = function
  | Parametric { name; _ } ->
      List.mem
        ~equal:String.equal
        ["typing.Generator"; "typing.AsyncGenerator"]
        (Identifier.show name)
  | _ ->
      false


let is_generic = function
  | Parametric { name; _ } ->
      Identifier.show name = "typing.Generic"
  | _ ->
      false


let is_iterator = function
  | Parametric { name; _ } ->
      String.equal (Identifier.show name) "typing.Iterator"
  | _ ->
      false


let is_meta = function
  | Parametric { name; _ } -> Identifier.show name = "type"
  | _ -> false


let is_none = function
  | Optional Bottom -> true
  | _ -> false


let is_noreturn = function
  | Primitive name -> Identifier.show name = "typing.NoReturn"
  | _ -> false


let is_optional = function
  | Optional _ -> true
  | _ -> false


let is_optional_primitive = function
  | Primitive optional when Identifier.show optional = "typing.Optional" -> true
  | _ -> false


let is_primitive = function
  | Primitive _ -> true
  | _ -> false


let is_protocol = function
  | Parametric { name; _ } ->
      Identifier.show name = "typing.Protocol"
  | _ ->
      false


let is_tuple (annotation: t) =
  match annotation with
  | Tuple _ -> true
  | _ -> false


let is_unbound = function
  | Bottom -> true
  | _ -> false


let is_unknown annotation =
  exists annotation ~predicate:(function | Top | Deleted -> true | _ -> false)


let is_type_alias annotation = equal annotation (primitive "typing.TypeAlias")


let is_not_instantiated annotation =
  let predicate = function
    | Bottom -> true
    | Variable { constraints = Unconstrained; _ } -> true
    | _ -> false
  in
  exists annotation ~predicate


let rec variables = function
  | Callable { implementation; overloads; _ } ->
      let variables { annotation; parameters } =
        let variables_in_parameters  =
          match parameters with
          | Defined parameters ->
              let variables = function
                | Parameter.Anonymous { Parameter.annotation; _ }
                | Parameter.Named { Parameter.annotation; _ } ->
                    variables annotation
                | Parameter.Variable _
                | Parameter.Keywords _ ->
                    []
              in
              List.concat_map ~f:variables parameters
          | Undefined ->
              []
        in
        variables annotation @ variables_in_parameters
      in
      List.concat_map ~f:variables (implementation :: overloads)
  | Optional annotation ->
      variables annotation
  | Tuple (Bounded elements) ->
      List.concat_map ~f:variables elements
  | Tuple (Unbounded annotation) ->
      variables annotation
  | Parametric { parameters; _ } ->
      List.concat_map ~f:variables parameters
  | (Variable _) as annotation ->
      [annotation]
  | TypedDictionary { fields; _ } ->
      let annotations = List.map fields ~f:(fun { annotation; _ } -> annotation) in
      List.concat_map annotations ~f:variables
  | Union elements ->
      List.concat_map ~f:variables elements
  | Bottom
  | Deleted
  | Object
  | Primitive _
  | Top ->
      []


let rec primitives annotation =
  match annotation with
  | Primitive _ ->
      [annotation]
  | Callable { implementation; overloads; _ } ->
      let signature_primitives { annotation; parameters } =
        match parameters with
        | Defined parameters ->
            let parameter = function
              | Parameter.Anonymous { Parameter.annotation; _ }
              | Parameter.Named { Parameter.annotation; _ } ->
                  primitives annotation
              | Parameter.Variable _
              | Parameter.Keywords _ ->
                  []
            in
            (primitives annotation) @ List.concat_map ~f:parameter parameters
        | Undefined ->
            primitives annotation
      in
      List.concat_map (implementation :: overloads) ~f:signature_primitives

  | Optional annotation
  | Tuple (Unbounded annotation) ->
      primitives annotation

  | Variable { constraints; _ } ->
      begin
        match constraints with
        | Bound bound -> primitives bound
        | Explicit constraints ->
            List.concat_map constraints ~f:primitives
        | Unconstrained ->
            []
      end

  | TypedDictionary { name; fields } ->
      let annotations = List.map fields ~f:(fun { annotation; _ } -> annotation) in
      Primitive name :: (List.concat_map annotations ~f:primitives)
  | Parametric { parameters; _ }
  | Tuple (Bounded parameters)
  | Union parameters ->
      List.concat_map parameters ~f:primitives
  | Bottom
  | Deleted
  | Top
  | Object ->
      []


let is_resolved annotation =
  List.is_empty (variables annotation)


let is_partially_typed annotation =
  exists annotation ~predicate:(function | Object | Top | Bottom -> true | _ -> false)


let is_untyped = function
  | Object
  | Bottom
  | Top -> true
  | _ -> false


let rec mismatch_with_any left right =
  let compatible left right =
    let symmetric left right =
      (Identifier.show left = "typing.Mapping" && Identifier.show right = "dict") ||
      (Identifier.show left = "collections.OrderedDict" && Identifier.show right = "dict") ||
      (Identifier.show left = "typing.Iterable" && Identifier.show right = "list") ||
      (Identifier.show left = "typing.Iterable" && Identifier.show right = "typing.List") ||
      (Identifier.show left = "typing.Iterable" && Identifier.show right = "set") ||
      (Identifier.show left = "typing.Sequence" && Identifier.show right = "typing.List") ||
      (Identifier.show left = "typing.Sequence" && Identifier.show right = "list")
    in
    Identifier.equal left right ||
    symmetric left right ||
    symmetric right left
  in

  match left, right with
  | Object, Bottom
  | Bottom, Object
  | Object, Optional _
  | Optional _, Object
  | Object, Parametric _
  | Parametric _, Object
  | Object, Primitive _
  | Primitive _, Object
  | Object, Top
  | Top, Object
  | Object, Tuple _
  | Tuple _, Object
  | Object, Union _
  | Union _, Object
  | Object, Variable _
  | Variable _, Object ->
      true
  | Parametric { name; parameters = [left] }, right
    when Identifier.equal name (Identifier.create "typing.Optional") ->
      mismatch_with_any left right
  | left, Parametric { name; parameters = [right] }
    when Identifier.equal name (Identifier.create "typing.Optional") ->
      mismatch_with_any left right
  | Optional left, Optional right
  | Optional left, right
  | left, Optional right ->
      mismatch_with_any left right

  | Parametric left, Parametric right
    when compatible left.name right.name &&
         List.length left.parameters = List.length right.parameters ->
      List.exists2_exn ~f:mismatch_with_any left.parameters right.parameters

  | Parametric { name = iterator; parameters = [iterator_parameter] },
    Parametric { name = generator; parameters = generator_parameter :: _ }
  | Parametric { name = generator; parameters = generator_parameter :: _ },
    Parametric { name = iterator; parameters = [iterator_parameter] }
    when (Identifier.show iterator = "typing.Iterator" ||
          Identifier.show iterator = "typing.Iterable") &&
         Identifier.show generator = "typing.Generator" ->
      mismatch_with_any iterator_parameter generator_parameter

  | Tuple (Bounded left), Tuple (Bounded right) when List.length left = List.length right ->
      List.exists2_exn ~f:mismatch_with_any left right
  | Tuple (Unbounded left), Tuple (Unbounded right) ->
      mismatch_with_any left right
  | Tuple (Bounded bounded), Tuple (Unbounded unbounded)
  | Tuple (Unbounded unbounded), Tuple (Bounded bounded) ->
      begin
        match unbounded, bounded with
        | Object, _ ->
            true
        | unbounded, head :: tail ->
            mismatch_with_any unbounded head ||
            List.for_all ~f:(equal Object) tail
        | _ ->
            false
      end

  | Union left, Union right ->
      let left = Set.of_list left in
      let right = Set.of_list right in
      let mismatched left right =
        Set.length left = Set.length right &&
        Set.mem left Object &&
        not (Set.mem right Object) &&
        Set.length (Set.diff left right) = 1
      in
      mismatched left right || mismatched right left
  | Union union, other
  | other, Union union ->
      List.exists ~f:(mismatch_with_any other) union

  | _ ->
      false


let optional_value = function
  | Optional annotation -> annotation
  | annotation -> annotation


let async_generator_value = function
  | Parametric { name; parameters = [parameter; _] }
    when Identifier.show name = "typing.AsyncGenerator" ->
      generator parameter
  | _ ->
      Top


let awaitable_value = function
  | Parametric { name; parameters = [parameter] } when Identifier.show name = "typing.Awaitable" ->
      parameter
  | _ ->
      Top


let parameters = function
  | Parametric { parameters; _ } -> parameters
  | _ -> []


let single_parameter = function
  | Parametric { parameters = [parameter]; _ } -> parameter
  | _ -> failwith "Type does not have single parameter"


let split = function
  | Optional parameter ->
      primitive "typing.Optional", [parameter]
  | Parametric { name; parameters } ->
      Primitive name, parameters
  | Tuple tuple ->
      let parameters =
        match tuple with
        | Bounded parameters -> parameters
        | Unbounded parameter -> [parameter]
      in
      Primitive (Identifier.create "tuple"), parameters
  | annotation ->
      annotation, []


let class_name annotation =
  split annotation
  |> fst
  |> expression
  |> Expression.access


let class_variable annotation =
  parametric "typing.ClassVar" [annotation]


let class_variable_value = function
  | Parametric { name; parameters = [parameter] }
    when Identifier.show name = "typing.ClassVar" ->
      Some parameter
  | _ -> None


(* Angelic assumption: Any occurrences of top indicate that we're dealing with Any instead of None.
   See T22792667. *)
let assume_any = function
  | Top -> Object
  | annotation -> annotation


let instantiate ?(widen = false) annotation ~constraints =
  let rec instantiate annotation =
    match constraints annotation with
    | Some Bottom when widen ->
        Top
    | Some replacement ->
        replacement
    | None ->
        begin
          match annotation with
          | Optional parameter ->
              optional (instantiate parameter)
          | Callable { kind; implementation; overloads; implicit } ->
              let instantiate { annotation; parameters } =
                let parameters  =
                  match parameters with
                  | Defined parameters ->
                      let parameter parameter =
                        match parameter with
                        | Parameter.Anonymous { Parameter.index; annotation } ->
                            Parameter.Anonymous {
                              Parameter.index;
                              annotation = (instantiate annotation)
                            }
                        | Parameter.Named ({ Parameter.annotation; _ } as named) ->
                            Parameter.Named {
                              named with
                              Parameter.annotation = instantiate annotation;
                            }
                        | Parameter.Variable ({ Parameter.annotation; _ } as named) ->
                            Parameter.Variable {
                              named with
                              Parameter.annotation = instantiate annotation;
                            }
                        | Parameter.Keywords ({ Parameter.annotation; _ } as named) ->
                            Parameter.Keywords {
                              named with
                              Parameter.annotation = instantiate annotation;
                            }
                      in
                      Defined (List.map parameters ~f:parameter)
                  | Undefined ->
                      Undefined
                in
                { annotation = instantiate annotation; parameters }
              in
              Callable {
                kind;
                implementation = instantiate implementation;
                overloads = List.map overloads ~f:instantiate;
                implicit;
              }
          | Parametric ({ parameters; _ } as parametric) ->
              Parametric {
                parametric with
                parameters = List.map parameters ~f:instantiate;
              }
          | Tuple tuple ->
              let tuple =
                match tuple with
                | Bounded parameters ->
                    Bounded (List.map parameters ~f:instantiate)
                | Unbounded parameter ->
                    Unbounded (instantiate parameter)
              in
              Tuple tuple
          | Union parameters ->
              List.map parameters ~f:instantiate
              |> union
          | _ ->
              annotation
        end
  in
  instantiate annotation


let instantiate_variables annotation =
  let constraints =
    variables annotation
    |> List.fold
      ~init:Map.empty
      ~f:(fun constraints variable -> Map.set constraints ~key:variable ~data:Bottom)
  in
  instantiate annotation ~constraints:(Map.find constraints)


let rec dequalify map annotation =
  let dequalify_identifier identifier =
    let rec fold accumulator access =
      if Access.Map.mem map access then
        (Access.Map.find_exn map access) @ accumulator
      else
        match access with
        | tail :: rest ->
            fold (tail :: accumulator) rest
        | [] -> accumulator
    in
    Identifier.show identifier
    |> Access.create
    |> List.rev
    |> fold []
    |> Access.show
    |> Identifier.create
  in
  let dequalify_string string = Identifier.create string |> dequalify_identifier in
  match annotation with
  | Optional parameter ->
      Parametric {
        name = dequalify_string "typing.Optional";
        parameters = [dequalify map parameter];
      }
  | Parametric { name; parameters } ->
      Parametric {
        name = dequalify_identifier (reverse_substitute name);
        parameters = List.map parameters ~f:(dequalify map);
      }
  | Union parameters ->
      Parametric {
        name = dequalify_string "typing.Union";
        parameters = List.map parameters ~f:(dequalify map);
      }
  | Primitive name -> Primitive (dequalify_identifier name)
  | Variable { variable = name; constraints } ->
      let constraints =
        match constraints with
        | Bound bound -> Bound (dequalify map bound)
        | Explicit constraints -> Explicit (List.map constraints ~f:(dequalify map))
        | Unconstrained -> Unconstrained
      in
      Variable { variable = dequalify_identifier name; constraints }
  | _ -> annotation


module Callable = struct
  module Parameter = struct
    include Record.Callable.RecordParameter

    type parameter = type_t t
    [@@deriving compare, eq, sexp, show, hash]

    module Map = Core.Map.Make(struct
        type nonrec t = parameter
        let compare = compare type_compare
        let sexp_of_t = sexp_of_t type_sexp_of_t
        let t_of_sexp = t_of_sexp type_t_of_sexp
      end)

    let name = function
      | Anonymous { index; _ } -> Identifier.create (Format.sprintf "$%d" index)
      | Named { name; _ } -> Identifier.create (Access.show name)
      | Variable { name; _ } -> Identifier.create ("*" ^ (Access.show name))
      | Keywords { name; _ } -> Identifier.create ("**" ^ (Access.show name))


    let annotation = function
      | Anonymous { annotation; _ }
      | Named { annotation; _ }
      | Variable { annotation; _ }
      | Keywords { annotation; _ } ->
          annotation
  end

  include Record.Callable

  type t = type_t Record.Callable.record
  [@@deriving compare, eq, sexp, show, hash]


  module Overload = struct
    let parameters { parameters; _ } =
      match parameters with
      | Defined parameters -> Some parameters
      | Undefined -> None

    let return_annotation { annotation; _ } = annotation

    let is_undefined { parameters; annotation } =
      match parameters with
      | Undefined -> is_unknown annotation
      | _ -> false
  end


  let from_overloads overloads =
    match overloads with
    | ({ kind = Named _; _ } as initial) :: overloads ->
        let fold sofar signature =
          match sofar, signature with
          | Some sofar, { kind; implementation; overloads; implicit } ->
              if
                equal_kind kind sofar.kind && implicit = sofar.implicit
              then
                Some {
                  kind;
                  implementation;
                  overloads = sofar.overloads @ overloads;
                  implicit
                }
              else
                None
          | _ ->
              None
        in
        List.fold ~init:(Some initial) ~f:fold overloads
    | _ ->
        None

  let map callable ~f =
    Callable callable
    |> f
    |> (function | Callable callable -> Some callable | _ -> None)


  let with_return_annotation ~return_annotation ({ implementation; overloads; _ } as initial) =
    let re_annotate implementation = { implementation with annotation = return_annotation } in
    {
      initial with
      implementation = re_annotate implementation;
      overloads = List.map ~f:re_annotate overloads }
end


let to_yojson annotation =
  `String (show annotation)
