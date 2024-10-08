(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
open PulseBasicInterface
open PulseDomainInterface
open PulseOperationResult.Import

type node = {procname: Procname.t; specialization: Specialization.Pulse.t}
[@@deriving equal, compare]

let pp fmt {procname; specialization} =
  F.fprintf fmt "%a (specialized for %a)" Procname.pp procname Specialization.Pulse.pp
    specialization


module NodeMap = PrettyPrintable.MakePPMap (struct
  type nonrec t = node

  let compare = compare_node

  let pp = pp
end)

module NodeSet = PrettyPrintable.MakePPSet (struct
  type nonrec t = node

  let compare = compare_node

  let pp = pp
end)

let get_missed_captures ~get_summary procnames =
  let from_execution = function
    | ExecutionDomain.ContinueProgram summary
    | ExceptionRaised summary
    | ExitProgram summary
    | AbortProgram summary ->
        AbductiveDomain.Summary.get_transitive_info summary
    | LatentAbortProgram {astate}
    | LatentInvalidAccess {astate}
    | LatentSpecializedTypeIssue {astate} ->
        AbductiveDomain.Summary.get_transitive_info astate
  in
  let from_pre_post_list pre_post_list =
    List.map pre_post_list ~f:(fun exec -> from_execution exec)
    |> List.reduce ~f:TransitiveInfo.join
    |> Option.value ~default:TransitiveInfo.bottom
  in
  let from_simple_summary {PulseSummary.pre_post_list; non_disj} =
    let from_disjs = from_pre_post_list pre_post_list in
    let from_non_disj =
      NonDisjDomain.Summary.get_transitive_info_if_not_top non_disj
      |> Option.value ~default:TransitiveInfo.bottom
    in
    TransitiveInfo.join from_disjs from_non_disj
  in
  let from_specialized_summary specialization summary =
    if Specialization.Pulse.is_bottom specialization then
      from_simple_summary summary.PulseSummary.main
    else
      Specialization.Pulse.Map.find_opt specialization summary.PulseSummary.specialized
      |> Option.value_map ~default:TransitiveInfo.bottom ~f:from_simple_summary
  in
  let rec visit (seen, missed_captures_map) node =
    if NodeSet.mem node seen then (seen, missed_captures_map)
    else
      let seen = NodeSet.add node seen in
      let opt_summary = get_summary node.procname in
      let missed_captures, seen, missed_captures_map =
        Option.value_map opt_summary ~default:(Typ.Name.Set.empty, seen, missed_captures_map)
          ~f:(fun summary ->
            let info = from_specialized_summary node.specialization summary in
            let { TransitiveInfo.direct_callees
                ; has_transitive_missed_captures
                ; direct_missed_captures } =
              info
            in
            if has_transitive_missed_captures then
              TransitiveInfo.DirectCallee.Set.fold
                (fun {procname; specialization} (missed_captures, seen, missed_captures_map) ->
                  let node = {procname; specialization} in
                  let seen, missed_captures_map = visit (seen, missed_captures_map) node in
                  let callee_missed_captures =
                    NodeMap.find_opt node missed_captures_map
                    |> Option.value ~default:Typ.Name.Set.empty
                  in
                  ( Typ.Name.Set.union callee_missed_captures missed_captures
                  , seen
                  , missed_captures_map ) )
                direct_callees
                (direct_missed_captures, seen, missed_captures_map)
            else (direct_missed_captures, seen, missed_captures_map) )
      in
      (seen, NodeMap.add node missed_captures missed_captures_map)
  in
  let entry_nodes =
    List.map procnames ~f:(fun (procname, specialization) -> {procname; specialization})
  in
  let _, missed_captures_map =
    List.fold entry_nodes ~init:(NodeSet.empty, NodeMap.empty) ~f:visit
  in
  List.fold entry_nodes ~init:Typ.Name.Set.empty ~f:(fun set node ->
      Typ.Name.Set.union set (NodeMap.find node missed_captures_map) )
