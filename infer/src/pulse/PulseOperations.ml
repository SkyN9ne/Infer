(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module L = Logging
open PulseBasicInterface
open PulseDomainInterface
open PulseOperationResult.Import

type t = AbductiveDomain.t

let check_addr_access path ?must_be_valid_reason access_mode location (address, history) astate =
  let access_trace = Trace.Immediate {location; history} in
  let* astate =
    AddressAttributes.check_valid path ?must_be_valid_reason access_trace address astate
    |> Result.map_error ~f:(fun (invalidation, invalidation_trace) ->
           ReportableError
             { diagnostic=
                 Diagnostic.AccessToInvalidAddress
                   { calling_context= []
                   ; invalid_address= Decompiler.find address astate
                   ; invalidation
                   ; invalidation_trace
                   ; access_trace
                   ; must_be_valid_reason }
             ; astate } )
    |> AccessResult.of_result
  in
  match access_mode with
  | Read ->
      AddressAttributes.check_initialized path access_trace address astate
      |> Result.map_error ~f:(fun typ ->
             ReportableError
               { diagnostic=
                   Diagnostic.ReadUninitialized {typ; calling_context= []; trace= access_trace}
               ; astate } )
      |> AccessResult.of_result_f ~f:(fun _ ->
             (* do not report further uninitialized reads errors on this value *)
             AddressAttributes.initialize address astate )
  | Write ->
      Ok (AddressAttributes.initialize address astate)
  | NoAccess ->
      Ok astate


module Closures = struct
  let is_captured_by_ref_access (access : _ MemoryAccess.t) =
    match access with
    | FieldAccess fieldname ->
        Fieldname.is_capture_field_in_cpp_lambda_by_ref fieldname
    | _ ->
        false


  let mk_capture_edges ~is_lambda captured =
    let add_edge id edges (mode, typ, addr, trace, captured_as) =
      (* it's ok to use [UnsafeMemory] here because we are building edges *)
      let var_name = Pvar.get_name captured_as in
      let field_name =
        if not is_lambda then Fieldname.mk_fake_capture_field ~id typ mode
        else Fieldname.mk_capture_field_in_cpp_lambda var_name mode
      in
      UnsafeMemory.Edges.add (FieldAccess field_name) (addr, trace) edges
    in
    List.foldi captured ~init:BaseMemory.Edges.empty ~f:add_edge


  let check_captured_addresses path action lambda_addr (astate : t) =
    match AddressAttributes.get_closure_proc_name lambda_addr astate with
    | None ->
        Ok astate
    | Some _ ->
        Memory.fold_edges lambda_addr astate ~init:(Ok astate)
          ~f:(fun astate_result (access, addr_trace) ->
            if is_captured_by_ref_access access then
              astate_result >>= check_addr_access path Read action addr_trace
            else astate_result )


  let record ({PathContext.timestamp; conditions} as path) location pname captured astate =
    let captured_addresses =
      List.filter_map captured
        ~f:(fun (captured_as, (address_captured, trace_captured), typ, mode) ->
          let new_trace =
            ValueHistory.sequence ~context:conditions
              (Capture {captured_as; mode; location; timestamp})
              trace_captured
          in
          Some (mode, typ, address_captured, new_trace, captured_as) )
    in
    let ((closure_addr, _) as closure_addr_hist) =
      (AbstractValue.mk_fresh (), ValueHistory.singleton (Assignment (location, timestamp)))
    in
    let is_lambda = Procname.is_cpp_lambda pname in
    let fake_capture_edges = mk_capture_edges ~is_lambda captured_addresses in
    let++ astate =
      AbductiveDomain.set_post_cell path closure_addr_hist
        (fake_capture_edges, Attributes.singleton (Closure pname))
        location astate
      |> PulseArithmetic.and_positive closure_addr
    in
    (astate, closure_addr_hist)
end

let pulse_model_type = Typ.CStruct (QualifiedCppName.of_list ["__infer_pulse_model"])

module ModeledField = struct
  let string_length = Fieldname.make pulse_model_type "__infer_model_string_length"

  let internal_string = Fieldname.make pulse_model_type "__infer_model_backing_string"

  let internal_ref_count = Fieldname.make pulse_model_type "__infer_model_reference_count"

  let delegated_release = Fieldname.make pulse_model_type "__infer_model_delegated_release"
end

let conservatively_initialize_args arg_values astate =
  let reachable_values =
    AbductiveDomain.reachable_addresses_from (Caml.List.to_seq arg_values) astate `Post
  in
  AbstractValue.Set.fold AddressAttributes.initialize reachable_values astate


let eval_access_to_value_origin path ?must_be_valid_reason mode location addr_hist access astate =
  let+ astate = check_addr_access path ?must_be_valid_reason mode location addr_hist astate in
  let astate, dest = Memory.eval_edge addr_hist access astate in
  (astate, ValueOrigin.InMemory {src= addr_hist; access; dest})


let eval_access path ?must_be_valid_reason mode location addr_hist access astate =
  let+ astate, value_origin =
    eval_access_to_value_origin path ?must_be_valid_reason mode location addr_hist access astate
  in
  (astate, ValueOrigin.addr_hist value_origin)


let eval_deref_access path ?must_be_valid_reason mode location addr_hist access astate =
  let* astate, addr_hist = eval_access path Read location addr_hist access astate in
  eval_access path ?must_be_valid_reason mode location addr_hist Dereference astate


let eval_var_to_value_origin {PathContext.timestamp} location pvar astate =
  let var = Var.of_pvar pvar in
  let astate, addr_hist =
    Stack.eval (ValueHistory.singleton (VariableAccessed (pvar, location, timestamp))) var astate
  in
  let origin = ValueOrigin.OnStack {var; addr_hist} in
  (astate, origin)


let eval_var path location pvar astate =
  let astate, value_origin = eval_var_to_value_origin path location pvar astate in
  (astate, ValueOrigin.addr_hist value_origin)


let eval_ident id astate = Stack.eval ValueHistory.epoch (Var.of_id id) astate

let write_access path location addr_trace_ref access addr_trace_obj astate =
  check_addr_access path Write location addr_trace_ref astate
  >>| Memory.add_edge path addr_trace_ref access addr_trace_obj location


let write_deref path location ~ref:addr_trace_ref ~obj:addr_trace_obj astate =
  write_access path location addr_trace_ref Dereference addr_trace_obj astate


let rec eval (path : PathContext.t) mode location exp astate :
    (t * (AbstractValue.t * ValueHistory.t)) PulseOperationResult.t =
  let++ astate, value_origin = eval_to_value_origin path mode location exp astate in
  (astate, ValueOrigin.addr_hist value_origin)


and record_closure_cpp_lambda astate (path : PathContext.t) loc procname
    (captured_vars : (Exp.t * Pvar.t * Typ.t * CapturedVar.capture_mode) list) =
  let assign_event = ValueHistory.Assignment (loc, path.timestamp) in
  let closure_addr_hist = (AbstractValue.mk_fresh (), ValueHistory.singleton assign_event) in
  let astate =
    AddressAttributes.add_one (fst closure_addr_hist) (Attribute.Closure procname) astate
  in
  let** astate = PulseArithmetic.and_positive (fst closure_addr_hist) astate in
  let store_captured_var result (exp, var, _typ, mode) =
    let field_name = Fieldname.mk_capture_field_in_cpp_lambda (Pvar.get_name var) mode in
    let** astate = result in
    let** astate, rhs_value_origin = eval_to_value_origin path NoAccess loc exp astate in
    let rhs_addr, rhs_history = ValueOrigin.addr_hist rhs_value_origin in
    let astate = conservatively_initialize_args [rhs_addr] astate in
    L.d_printfln "Storing %a.%a = %a" AbstractValue.pp (fst closure_addr_hist) Fieldname.pp
      field_name AbstractValue.pp rhs_addr ;
    let=+ astate, lhs_addr_hist =
      eval_access path Read loc closure_addr_hist (FieldAccess field_name) astate
    in
    write_deref path loc ~ref:lhs_addr_hist ~obj:(rhs_addr, rhs_history) astate
  in
  let++ astate = List.fold captured_vars ~init:(Sat (Ok astate)) ~f:store_captured_var in
  (astate, ValueOrigin.Unknown closure_addr_hist)


and eval_to_value_origin (path : PathContext.t) mode location exp astate :
    (t * ValueOrigin.t) PulseOperationResult.t =
  match (exp : Exp.t) with
  | Var id ->
      let var = Var.of_id id in
      (* error in case of missing history? *)
      let astate, addr_hist = Stack.eval ValueHistory.epoch var astate in
      let origin = ValueOrigin.OnStack {var; addr_hist} in
      Sat (Ok (astate, origin))
  | Lvar pvar ->
      Sat (Ok (eval_var_to_value_origin path location pvar astate))
  | Lfield (exp', field, _) ->
      let+* astate, addr_hist = eval path Read location exp' astate in
      eval_access_to_value_origin path mode location addr_hist (FieldAccess field) astate
  | Lindex (exp', exp_index) ->
      let** astate, addr_hist_index = eval path Read location exp_index astate in
      let+* astate, addr_hist = eval path Read location exp' astate in
      eval_access_to_value_origin path mode location addr_hist
        (ArrayAccess (StdTyp.void, fst addr_hist_index))
        astate
  | Closure {name; captured_vars} ->
      if Procname.is_cpp_lambda name then
        let++ astate, v_hist = record_closure_cpp_lambda astate path location name captured_vars in
        (astate, v_hist)
      else
        let** astate, rev_captured =
          List.fold captured_vars
            ~init:(Sat (Ok (astate, [])))
            ~f:(fun result (capt_exp, captured_as, typ, mode) ->
              let** astate, rev_captured = result in
              let++ astate, addr_trace = eval path Read location capt_exp astate in
              (astate, (captured_as, addr_trace, typ, mode) :: rev_captured) )
        in
        let++ astate, v_hist = Closures.record path location name (List.rev rev_captured) astate in
        let astate =
          conservatively_initialize_args
            (List.rev_map rev_captured ~f:(fun (_, (addr, _), _, _) -> addr))
            astate
        in
        (astate, ValueOrigin.Unknown v_hist)
  | Const (Cfun proc_name) ->
      (* function pointers are represented as closures with no captured variables *)
      let++ astate, addr_hist = Closures.record path location proc_name [] astate in
      (astate, ValueOrigin.Unknown addr_hist)
  | Cast (_, exp') ->
      eval_to_value_origin path mode location exp' astate
  | Const (Cint i) ->
      let v = Formula.absval_of_int astate.AbductiveDomain.path_condition i in
      let invalidation = Invalidation.ConstantDereference i in
      let++ astate =
        PulseArithmetic.and_eq_int v i astate
        >>|| AddressAttributes.invalidate
               (v, ValueHistory.singleton (Assignment (location, path.timestamp)))
               invalidation location
      in
      let addr_hist =
        (v, ValueHistory.singleton (Invalidated (invalidation, location, path.timestamp)))
      in
      (astate, ValueOrigin.Unknown addr_hist)
  | Const (Cstr s) ->
      (* TODO: record actual string value; since we are making strings be a record in memory
         instead of pure values some care has to be added to access string values once written *)
      let v = AbstractValue.mk_fresh () in
      let=* astate, (len_addr, hist) =
        eval_access path Write location
          (v, ValueHistory.singleton (Assignment (location, path.timestamp)))
          (FieldAccess ModeledField.string_length) astate
      in
      let len_int = IntLit.of_int (String.length s) in
      let++ astate = PulseArithmetic.and_eq_int len_addr len_int astate in
      let astate = AddressAttributes.add_one v (ConstString s) astate in
      (astate, ValueOrigin.Unknown (v, hist))
  | Const ((Cfloat _ | Cclass _) as c) ->
      let v = AbstractValue.mk_fresh () in
      let++ astate = PulseArithmetic.and_eq_const v c astate in
      ( astate
      , ValueOrigin.Unknown (v, ValueHistory.singleton (Assignment (location, path.timestamp))) )
  | UnOp (unop, exp, _typ) ->
      let** astate, (addr, hist) = eval path Read location exp astate in
      let unop_addr = AbstractValue.mk_fresh () in
      let++ astate, unop_addr = PulseArithmetic.eval_unop unop_addr unop addr astate in
      (astate, ValueOrigin.Unknown (unop_addr, hist))
  | BinOp (bop, e_lhs, e_rhs) ->
      let** astate, (addr_lhs, hist_lhs) = eval path Read location e_lhs astate in
      let** astate, (addr_rhs, hist_rhs) = eval path Read location e_rhs astate in
      let binop_addr = AbstractValue.mk_fresh () in
      let++ astate, binop_addr =
        PulseArithmetic.eval_binop binop_addr bop (AbstractValueOperand addr_lhs)
          (AbstractValueOperand addr_rhs) astate
      in
      (astate, ValueOrigin.Unknown (binop_addr, ValueHistory.binary_op bop hist_lhs hist_rhs))
  | Exn exp ->
      eval_to_value_origin path Read location exp astate
  | Sizeof _ ->
      let addr_hist = (AbstractValue.mk_fresh (), (* TODO history *) ValueHistory.epoch) in
      Sat (Ok (astate, ValueOrigin.Unknown addr_hist))


let eval_to_operand path location exp astate =
  match (exp : Exp.t) with
  | Const c ->
      Sat (Ok (astate, PulseArithmetic.ConstOperand c, ValueHistory.epoch))
  | exp ->
      let++ astate, (value, hist) = eval path Read location exp astate in
      (astate, PulseArithmetic.AbstractValueOperand value, hist)


let prune path location ~condition astate =
  let rec prune_aux ~negated exp astate =
    match (exp : Exp.t) with
    | BinOp (bop, exp_lhs, exp_rhs) ->
        let** astate, lhs_op, lhs_hist = eval_to_operand path location exp_lhs astate in
        let** astate, rhs_op, rhs_hist = eval_to_operand path location exp_rhs astate in
        let++ astate = PulseArithmetic.prune_binop ~negated bop lhs_op rhs_op astate in
        let hist =
          match (lhs_hist, rhs_hist) with
          | ValueHistory.Epoch, hist | hist, ValueHistory.Epoch ->
              (* if one history is empty then just propagate the other one (which could also be
                 empty) *)
              hist
          | _ ->
              ValueHistory.binary_op bop lhs_hist rhs_hist
        in
        (astate, hist)
    | UnOp (LNot, exp', _) ->
        prune_aux ~negated:(not negated) exp' astate
    | exp ->
        prune_aux ~negated (Exp.BinOp (Ne, exp, Exp.zero)) astate
  in
  prune_aux ~negated:false condition astate


let eval_deref_to_value_origin path ?must_be_valid_reason location exp astate =
  let+* astate, addr_hist = eval path Read location exp astate in
  let+ astate = check_addr_access path ?must_be_valid_reason Read location addr_hist astate in
  let astate, dest_addr_hist = Memory.eval_edge addr_hist Dereference astate in
  (astate, ValueOrigin.InMemory {src= addr_hist; access= Dereference; dest= dest_addr_hist})


let eval_deref path ?must_be_valid_reason location exp astate =
  let++ astate, value_origin =
    eval_deref_to_value_origin path ?must_be_valid_reason location exp astate
  in
  (astate, ValueOrigin.addr_hist value_origin)


let eval_proc_name path location call_exp astate =
  match (call_exp : Exp.t) with
  | Const (Cfun proc_name) | Closure {name= proc_name} ->
      Sat (Ok (astate, Some proc_name))
  | _ ->
      let++ astate, (f, _) = eval path Read location call_exp astate in
      (astate, AddressAttributes.get_closure_proc_name f astate)


let realloc_pvar tenv ({PathContext.timestamp} as path) ~set_uninitialized pvar typ location astate
    =
  let addr = AbstractValue.mk_fresh () in
  let astate =
    Stack.add (Var.of_pvar pvar)
      (addr, ValueHistory.singleton (VariableDeclared (pvar, location, timestamp)))
      astate
  in
  if set_uninitialized then
    AddressAttributes.set_uninitialized tenv path (`LocalDecl (pvar, Some addr)) typ location astate
  else astate


let write_id id new_addr_loc astate = Stack.add (Var.of_id id) new_addr_loc astate

let read_id id astate = Stack.find_opt (Var.of_id id) astate

let havoc_id id loc_opt astate =
  (* Topl needs to track the return value of a method; even if nondet now, it may be pruned later. *)
  if Topl.is_active () || Stack.mem (Var.of_id id) astate then
    write_id id (AbstractValue.mk_fresh (), loc_opt) astate
  else astate


let write_field path location ~ref:addr_trace_ref field ~obj:addr_trace_obj astate =
  write_access path location addr_trace_ref (FieldAccess field) addr_trace_obj astate


let write_deref_field path location ~ref:addr_trace_ref field ~obj:addr_trace_obj astate =
  let* astate, addr_hist =
    eval_access path Read location addr_trace_ref (FieldAccess field) astate
  in
  write_deref path location ~ref:addr_hist ~obj:addr_trace_obj astate


let write_arr_index path location ~ref:addr_trace_ref ~index ~obj:addr_trace_obj astate =
  write_access path location addr_trace_ref (ArrayAccess (StdTyp.void, index)) addr_trace_obj astate


let havoc_deref_field path location addr_trace field trace_obj astate =
  write_deref_field path location ~ref:addr_trace field
    ~obj:(AbstractValue.mk_fresh (), trace_obj)
    astate


let hack_python_propagates_type_on_load tenv path loc rhs_exp addr astate =
  ( if Language.curr_language_is Hack || Language.curr_language_is Python then
      (* The Hack and Python frontends do not propagate types from declarations to usage,
         so we redo part of the work ourself *)
      let open IOption.Let_syntax in
      match rhs_exp with
      | Exp.Lfield (recv, field_name, _) ->
          let* _, (base_addr, _) =
            eval path NoAccess loc recv astate |> PulseOperationResult.sat_ok
          in
          let* typ_name = AbductiveDomain.AddressAttributes.get_static_type base_addr astate in
          let* {Struct.typ= field_typ} = Tenv.resolve_field_info tenv typ_name field_name in
          let+ field_typ_name =
            if Typ.is_pointer field_typ then Typ.name (Typ.strip_ptr field_typ) else None
          in
          AbductiveDomain.AddressAttributes.add_static_type tenv field_typ_name addr astate
      | _ ->
          None
    else None )
  |> Option.value ~default:astate


let always_reachable address astate = AddressAttributes.always_reachable address astate

let allocate allocator location addr astate =
  AddressAttributes.allocate allocator addr location astate


let java_resource_release ~recursive address astate =
  let if_valid_access_then_eval addr access astate =
    Option.map (Memory.find_edge_opt addr access astate) ~f:fst
  in
  let if_valid_field_then_load obj field astate =
    let open IOption.Let_syntax in
    let* field_addr = if_valid_access_then_eval obj (FieldAccess field) astate in
    if_valid_access_then_eval field_addr Dereference astate
  in
  let rec loop seen obj astate =
    if AbstractValue.Set.mem obj seen || AddressAttributes.is_java_resource_released obj astate then
      astate
    else
      let astate = AddressAttributes.java_resource_release obj astate in
      match if_valid_field_then_load obj ModeledField.delegated_release astate with
      | Some delegation ->
          (* beware: if the field is not valid, a regular call to Java.load_field will generate a
             fresh abstract value and we will loop forever, even if we use the [seen] set *)
          if recursive then loop (AbstractValue.Set.add obj seen) delegation astate else astate
      | None ->
          astate
  in
  loop AbstractValue.Set.empty address astate


let csharp_resource_release ~recursive address astate =
  let if_valid_access_then_eval addr access astate =
    Option.map (Memory.find_edge_opt addr access astate) ~f:fst
  in
  let if_valid_field_then_load obj field astate =
    let open IOption.Let_syntax in
    let* field_addr = if_valid_access_then_eval obj (FieldAccess field) astate in
    if_valid_access_then_eval field_addr Dereference astate
  in
  let rec loop seen obj astate =
    if AbstractValue.Set.mem obj seen || AddressAttributes.is_csharp_resource_released obj astate
    then astate
    else
      let astate = AddressAttributes.csharp_resource_release obj astate in
      match if_valid_field_then_load obj ModeledField.delegated_release astate with
      | Some delegation ->
          (* beware: if the field is not valid, a regular call to CSharp.load_field will generate a
             fresh abstract value and we will loop forever, even if we use the [seen] set *)
          if recursive then loop (AbstractValue.Set.add obj seen) delegation astate else astate
      | None ->
          astate
  in
  loop AbstractValue.Set.empty address astate


let add_dynamic_type typ address astate = AddressAttributes.add_dynamic_type typ address astate

let add_dynamic_type_source_file typ source_file address astate =
  AddressAttributes.add_dynamic_type_source_file typ source_file address astate


let add_ref_counted address astate = AddressAttributes.add_ref_counted address astate

let is_ref_counted address astate = AddressAttributes.is_ref_counted address astate

let remove_allocation_attr address astate = AddressAttributes.remove_allocation_attr address astate

type invalidation_access =
  | MemoryAccess of
      {pointer: AbstractValue.t * ValueHistory.t; access: Access.t; hist_obj_default: ValueHistory.t}
  | StackAddress of Var.t * ValueHistory.t
  | UntraceableAccess

let record_invalidation ({PathContext.timestamp; conditions} as path) access_path location cause
    astate =
  match access_path with
  | StackAddress (x, hist0) ->
      let astate, (addr, hist) = Stack.eval hist0 x astate in
      let hist' =
        ValueHistory.sequence ~context:conditions (Invalidated (cause, location, timestamp)) hist
      in
      Stack.add x (addr, hist') astate
  | MemoryAccess {pointer; access; hist_obj_default} ->
      let addr_obj, hist_obj =
        match Memory.find_edge_opt (fst pointer) access astate with
        | Some addr_hist ->
            addr_hist
        | None ->
            (AbstractValue.mk_fresh (), hist_obj_default)
      in
      let hist' =
        ValueHistory.sequence ~context:conditions
          (Invalidated (cause, location, timestamp))
          hist_obj
      in
      Memory.add_edge path pointer access (addr_obj, hist') location astate
  | UntraceableAccess ->
      astate


let invalidate path access_path location cause addr_trace astate =
  AddressAttributes.invalidate addr_trace cause location astate
  |> record_invalidation path access_path location cause


let check_and_invalidate path access_path location cause addr_trace astate =
  check_addr_access path NoAccess location addr_trace astate
  >>| invalidate path access_path location cause addr_trace


let invalidate_access path location cause ref_addr_hist access astate =
  let astate, (addr_obj, hist_obj) = Memory.eval_edge ref_addr_hist access astate in
  invalidate path
    (MemoryAccess {pointer= ref_addr_hist; access; hist_obj_default= hist_obj})
    location cause
    (addr_obj, snd ref_addr_hist)
    astate


let invalidate_deref_access path location cause ref_addr_hist access astate =
  let astate, addr_hist = Memory.eval_edge ref_addr_hist access astate in
  let astate, (addr_obj, hist_obj) = Memory.eval_edge addr_hist Dereference astate in
  invalidate path
    (MemoryAccess {pointer= ref_addr_hist; access; hist_obj_default= hist_obj})
    location cause
    (addr_obj, snd ref_addr_hist)
    astate


let invalidate_array_elements path location cause addr_trace astate =
  let+ astate = check_addr_access path NoAccess location addr_trace astate in
  Memory.fold_edges (fst addr_trace) astate ~init:astate ~f:(fun astate (access, dest_addr_trace) ->
      match (access : Access.t) with
      | ArrayAccess _ as access ->
          AddressAttributes.invalidate dest_addr_trace cause location astate
          |> record_invalidation path
               (MemoryAccess {pointer= addr_trace; access; hist_obj_default= snd dest_addr_trace})
               location cause
      | _ ->
          astate )


let shallow_copy ({PathContext.timestamp} as path) location addr_hist astate =
  let+ astate = check_addr_access path Read location addr_hist astate in
  let cell_opt = AbductiveDomain.find_post_cell_opt (fst addr_hist) astate in
  let copy =
    (AbstractValue.mk_fresh (), ValueHistory.singleton (Assignment (location, timestamp)))
  in
  ( Option.value_map cell_opt ~default:astate ~f:(fun cell ->
        AbductiveDomain.set_post_cell path copy cell location astate )
  , copy )


let rec deep_copy ?depth_max ({PathContext.timestamp} as path) location addr_hist_src astate =
  match depth_max with
  | Some 0 ->
      shallow_copy path location addr_hist_src astate
  | _ ->
      let depth_max = Option.map ~f:(fun n -> n - 1) depth_max in
      let* astate = check_addr_access path Read location addr_hist_src astate in
      let copy =
        (AbstractValue.mk_fresh (), ValueHistory.singleton (Assignment (location, timestamp)))
      in
      let+ astate =
        Memory.fold_edges (fst addr_hist_src) astate ~init:(Ok astate)
          ~f:(fun astate_result (access, addr_hist_dest) ->
            let* astate = astate_result in
            let+ astate, addr_hist_dest_copy =
              deep_copy ?depth_max path location addr_hist_dest astate
            in
            Memory.add_edge path copy access addr_hist_dest_copy location astate )
      in
      let astate =
        AddressAttributes.find_opt (fst addr_hist_src) astate
        |> Option.value_map ~default:astate ~f:(fun src_attrs ->
               AddressAttributes.add_all (fst copy) src_attrs astate )
      in
      (astate, copy)


let check_address_escape escape_location proc_desc address history astate =
  let is_assigned_to_global address astate =
    let points_to_address pointer address astate =
      Memory.find_edge_opt pointer Dereference astate
      |> Option.exists ~f:(fun (pointee, _) -> AbstractValue.equal pointee address)
    in
    Stack.exists
      (fun var (pointer, _) -> Var.is_global var && points_to_address pointer address astate)
      astate
  in
  let check_address_of_cpp_temporary () =
    AddressAttributes.find_opt address astate
    |> Option.value_map ~default:(Result.Ok ()) ~f:(fun attrs ->
           IContainer.iter_result ~fold:Attributes.fold attrs ~f:(fun attr ->
               match attr with
               | Attribute.AddressOfCppTemporary (variable, _)
                 when not (is_assigned_to_global address astate) ->
                   (* The returned address corresponds to a C++ temporary. It will have gone out of
                      scope by now except if it was bound to a global. *)
                   Error
                     (ReportableError
                        { diagnostic=
                            Diagnostic.StackVariableAddressEscape
                              {variable; location= escape_location; history}
                        ; astate } )
               | _ ->
                   Ok () ) )
  in
  let check_address_of_stack_variable () =
    let proc_name = Procdesc.get_proc_name proc_desc in
    IContainer.iter_result ~fold:(IContainer.fold_of_pervasives_map_fold Stack.fold) astate
      ~f:(fun (variable, (var_address, _)) ->
        if
          AbstractValue.equal var_address address
          && ( Var.is_cpp_temporary variable
             || Var.is_local_to_procedure proc_name variable
                && not (Procdesc.is_captured_var proc_desc variable) )
        then (
          L.d_printfln_escaped "Stack variable address &%a detected at address %a" Var.pp variable
            AbstractValue.pp address ;
          Error
            (ReportableError
               { diagnostic=
                   Diagnostic.StackVariableAddressEscape
                     {variable; location= escape_location; history}
               ; astate } ) )
        else Ok () )
  in
  let+ () =
    let open Result.Monad_infix in
    check_address_of_cpp_temporary () >>= check_address_of_stack_variable
    |> AccessResult.of_result_f ~f:(fun _ -> ())
  in
  astate


let mark_address_of_cpp_temporary history variable address astate =
  AddressAttributes.add_one address (AddressOfCppTemporary (variable, history)) astate


let mark_address_of_stack_variable history variable location address astate =
  match AddressAttributes.get_address_of_stack_variable address astate with
  | None ->
      Sat
        (AddressAttributes.add_one address
           (AddressOfStackVariable (variable, location, history))
           astate )
  | Some (variable', location', _) ->
      L.d_printfln ~color:Orange
        "UNSAT: variables %a and %a have the same address on the stack.@\n  %a: %a@\n  %a: %a"
        Var.pp variable Var.pp variable' Var.pp variable Location.pp location Var.pp variable'
        Location.pp location' ;
      Unsat


let get_dynamic_type_unreachable_values vars astate =
  (* For each unreachable address we find a root variable for it; if there is
     more than one, it doesn't matter which *)
  let find_var_opt astate addr =
    Stack.fold
      (fun var (var_addr, _) var_opt ->
        if AbstractValue.equal addr var_addr then Some var else var_opt )
      astate None
  in
  let astate' = Stack.remove_vars vars astate in
  let unreachable_addrs = AbductiveDomain.get_unreachable_attributes astate' in
  let res =
    List.fold unreachable_addrs ~init:[] ~f:(fun res addr ->
        (let open IOption.Let_syntax in
         let* attrs = AbductiveDomain.AddressAttributes.find_opt addr astate in
         let* typ, _ = Attributes.get_dynamic_type_source_file attrs in
         let+ var = find_var_opt astate addr in
         (var, addr, typ) :: res )
        |> Option.value ~default:res )
  in
  List.map ~f:(fun (var, _, typ) -> (var, typ)) res


let remove_vars vars location astate =
  let open SatUnsat.Import in
  let astate = AbductiveDomain.mark_potential_leaks location ~dead_roots:vars astate in
  (* remember addresses that will marked invalid later *)
  let+ astate =
    SatUnsat.list_fold vars ~init:astate ~f:(fun astate var ->
        match Stack.find_opt var astate with
        | Some (address, history) ->
            let* astate =
              if Var.appears_in_source_code var && AbductiveDomain.is_local var astate then
                mark_address_of_stack_variable history var location address astate
              else Sat astate
            in
            if Var.is_cpp_temporary var then
              Sat (mark_address_of_cpp_temporary history var address astate)
            else Sat astate
        | _ ->
            Sat astate )
  in
  Stack.remove_vars vars astate


let get_var_captured_actuals path location ~is_lambda ~captured_formals ~actual_closure astate =
  let+ _, astate, captured_actuals =
    PulseResult.list_fold captured_formals ~init:(0, astate, [])
      ~f:(fun (id, astate, captured) (var, mode, typ) ->
        match var with
        | Var.ProgramVar pvar ->
            let var_name = Pvar.get_name pvar in
            let field_name =
              if not is_lambda then Fieldname.mk_fake_capture_field ~id typ mode
              else Fieldname.mk_capture_field_in_cpp_lambda var_name mode
            in
            let+ astate, captured_actual =
              if is_lambda then
                eval_deref_access path Read location actual_closure (FieldAccess field_name) astate
              else eval_access path Read location actual_closure (FieldAccess field_name) astate
            in
            (id + 1, astate, (captured_actual, typ) :: captured)
        | Var.LogicalVar _ ->
            L.die InternalError "program var expected but got %a" Var.pp var )
  in
  (* captured_actuals is currently in reverse order compared with the given
     captured_formals because it is built during the above fold (equivalent to a
     fold_left). We reverse it back to have a direct correspondece between the
     two lists' elements *)
  (astate, List.rev captured_actuals)


let get_closure_captured_actuals path location ~captured_actuals astate =
  let++ astate, captured_actuals =
    PulseOperationResult.list_fold captured_actuals ~init:(astate, [])
      ~f:(fun (astate, captured_actuals) (exp, _, typ, _) ->
        let++ astate, captured_actual = eval path Read location exp astate in
        (astate, (captured_actual, typ) :: captured_actuals) )
  in
  (* captured_actuals is currently in reverse order compared with its original
     order. We reverse it back to have it in the same order as the given
     captured_actuals and therefore not break the element-wise correspondence
     between the captured_actuals and captured_formals in the caller *)
  (astate, List.rev captured_actuals)


type call_kind =
  [ `Closure of (Exp.t * Pvar.t * Typ.t * CapturedVar.capture_mode) list
  | `Var of Ident.t
  | `ResolvedProcname ]

let get_captured_actuals procname path location ~captured_formals ~call_kind ~actuals astate =
  let is_lambda = Procname.is_cpp_lambda procname in
  if
    Procname.is_objc_block procname
    || Procname.is_specialized_with_function_parameters procname
    || Procname.is_erlang procname
  then
    match call_kind with
    | `Closure captured_actuals ->
        get_closure_captured_actuals path location ~captured_actuals astate
    | `Var id ->
        let+* astate, actual_closure = eval path Read location (Exp.Var id) astate in
        get_var_captured_actuals path location ~is_lambda ~captured_formals ~actual_closure astate
    | `ResolvedProcname ->
        Sat (Ok (astate, []))
  else
    match actuals with
    | (actual_closure, _) :: _ when not (List.is_empty captured_formals) ->
        Sat
          ((* Assumption: the first parameter will be a closure *)
           let* astate, actual_closure =
             eval_access path Read location actual_closure Dereference astate
           in
           get_var_captured_actuals path location ~is_lambda ~captured_formals ~actual_closure
             astate )
    | _ ->
        Sat (Ok (astate, []))


let check_used_as_branch_cond (addr, hist) ~pname_using_config ~branch_location ~location trace
    astate =
  let report_config_usage config =
    let diagnostic =
      Diagnostic.ConfigUsage {pname= pname_using_config; config; branch_location; location; trace}
    in
    Recoverable (astate, [ReportableError {astate; diagnostic}])
  in
  match AddressAttributes.get_config_usage addr astate with
  | None ->
      Ok
        (AddressAttributes.abduce_one addr
           (UsedAsBranchCond (pname_using_config, branch_location, trace))
           astate )
  | Some (ConfigName config) ->
      if FbPulseConfigName.has_config_read hist then report_config_usage config else Ok astate
  | Some (StringParam {v; config_type}) -> (
    match AddressAttributes.get_const_string v astate with
    | None ->
        Ok astate
    | Some s ->
        report_config_usage (FbPulseConfigName.of_string ~config_type s) )
