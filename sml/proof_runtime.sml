structure HolbuildProofRuntime =
struct

type config = {checkpoint_enabled : bool,
               tactic_timeout : real option,
               timeout_marker : string option,
               plan_theorem : string option,
               trace_all : bool,
               plan_only_marker : string option}

val checkpoint_enabled_ref = ref false
val tactic_timeout_ref = ref (NONE : real option)
val tactic_timeout_marker_ref = ref (NONE : string option)
val plan_theorem_ref = ref (NONE : string option)
val trace_all_ref = ref false
val plan_only_marker_ref = ref (NONE : string option)
val plan_active_ref = ref false
val trace_active_ref = ref false
val trace_current_theorem_ref = ref ""
val theorem_info_ref = ref NONE : (string * string * string * string * string * string * string * string * string * bool * int) option ref
val context_info_ref = ref NONE : (string * string * int) option ref
val proving_with_proof_ir_ref = ref false
val active_tactic_text_ref = ref ""
val successful_step_count_ref = ref 0
val successful_prefix_end_ref = ref 0
val failed_step_end_ref = ref NONE : int option ref
val compiled_tactic_ref = ref Tactical.ALL_TAC
val compiled_list_tactic_ref = ref Tactical.ALL_LT
val proof_history_ref = ref (NONE : goalStack.gstk History.history option)

fun env_bool name =
  case OS.Process.getEnv name of
      SOME "1" => SOME true
    | SOME "true" => SOME true
    | SOME "yes" => SOME true
    | SOME "0" => SOME false
    | SOME "false" => SOME false
    | SOME "no" => SOME false
    | _ => NONE

fun bool_text true = "true"
  | bool_text false = "false"

fun seconds (a, b) = Time.toReal (Time.-(b, a))
fun fmt_time t = Real.fmt (StringCvt.FIX (SOME 3)) t
fun fmt_ms t = Real.fmt (StringCvt.FIX (SOME 3)) (1000.0 * t)

fun delete_file path = OS.FileSys.remove path handle _ => ()
fun file_exists path = OS.FileSys.access(path, [OS.FileSys.A_READ]) handle _ => false
fun rename_file old new = OS.FileSys.rename {old = old, new = new}
fun rename_if_exists old new = if file_exists old then rename_file old new else ()

fun delete_checkpoint path =
  (delete_file (path ^ ".ok.bak");
   delete_file (path ^ ".bak");
   delete_file (path ^ ".ok");
   delete_file (path ^ ".meta");
   delete_file (path ^ ".prefix");
   delete_file path)

fun write_checkpoint_ok path ok_text =
  let val out = TextIO.openOut (path ^ ".ok")
  in TextIO.output(out, ok_text); TextIO.closeOut out end

fun backup_checkpoint path =
  (delete_file (path ^ ".bak");
   delete_file (path ^ ".ok.bak");
   rename_if_exists (path ^ ".ok") (path ^ ".ok.bak");
   rename_if_exists path (path ^ ".bak"))

fun discard_checkpoint_backup path =
  (delete_file (path ^ ".bak"); delete_file (path ^ ".ok.bak"))

fun write_timeout_marker label seconds =
  case !tactic_timeout_marker_ref of
      NONE => ()
    | SOME path =>
        let val out = TextIO.openOut path
        in TextIO.output(out, String.concat [label, "\t", Real.toString seconds, "\n"]);
           TextIO.closeOut out
        end

fun timeout_message label seconds =
  String.concat ["holbuild tactic timeout after ", Real.toString seconds, "s: ", label]

fun with_tactic_timeout label f x =
  case !tactic_timeout_ref of
      NONE => f x
    | SOME seconds =>
        (smlTimeout.timeout seconds f x
         handle smlTimeout.FunctionTimeout =>
           (write_timeout_marker label seconds;
            raise Fail (timeout_message label seconds)))

fun save_checkpoint label default_share path ok_text depth =
  if not (!checkpoint_enabled_ref) then ()
  else
    let
      val share = Option.getOpt(env_bool "HOLBUILD_SHARE_COMMON_DATA", default_share)
      val timing = Option.getOpt(env_bool "HOLBUILD_CHECKPOINT_TIMING", false)
      val t0 = Time.now()
      val _ = backup_checkpoint path
      val _ = if share then PolyML.shareCommonData PolyML.rootFunction else ()
      val t1 = Time.now()
      val _ = PolyML.SaveState.saveChild(path, depth)
      val t2 = Time.now()
      val _ = write_checkpoint_ok path ok_text
      val _ = discard_checkpoint_backup path
      val _ =
        if timing then
          TextIO.output
            (TextIO.stdErr,
             String.concat ["holbuild checkpoint kind=", label,
                            " share=", bool_text share,
                            " depth=", Int.toString depth,
                            " share_s=", fmt_time (seconds (t0, t1)),
                            " save_s=", fmt_time (seconds (t1, t2)),
                            " size=", Position.toString (OS.FileSys.fileSize path),
                            " path=", path, "\n"])
        else ()
    in () end

fun write_text_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun save_failed_prefix_checkpoint () =
  case !theorem_info_ref of
      NONE => ()
    | SOME (kind, _, _, _, _, _, _, failed_prefix_path, failed_prefix_ok, _, depth) =>
        if kind <> "theorem" orelse not (!checkpoint_enabled_ref) then ()
        else
          let
            val prefix_end = !successful_prefix_end_ref
            val prefix_text = String.substring(!active_tactic_text_ref, 0, prefix_end)
            val meta_text =
              String.concat ["step_count=", Int.toString (!successful_step_count_ref), "\n",
                             "prefix_end=", Int.toString prefix_end, "\n"]
            val _ = save_checkpoint "failed_prefix" false failed_prefix_path failed_prefix_ok depth
            val _ = write_text_file (failed_prefix_path ^ ".meta") meta_text
            val _ = write_text_file (failed_prefix_path ^ ".prefix") prefix_text
          in () end

fun begin_theorem (kind, name, tactic_text, context_path, context_ok,
                   end_path, end_ok, failed_prefix_path, failed_prefix_ok, has_attrs) =
  let val depth = length (PolyML.SaveState.showHierarchy())
  in
    theorem_info_ref := SOME (kind, name, tactic_text, context_path, context_ok,
                              end_path, end_ok, failed_prefix_path, failed_prefix_ok, has_attrs, depth);
    context_info_ref := SOME (context_path, context_ok, depth)
  end

fun save_theorem_context () =
  case !context_info_ref of
      NONE => ()
    | SOME (context_path, context_ok, depth) =>
        (context_info_ref := NONE;
         save_checkpoint "theorem_context" false context_path context_ok depth)

fun top_goal_text [] = "<no open goals>\n"
  | top_goal_text (goal :: _) = PP.pp_to_string 100 goalStack.std_pp_goal goal ^ "\n"

fun active_theorem_name () =
  case !theorem_info_ref of
      SOME (_, name, _, _, _, _, _, _, _, _, _) => SOME name
    | NONE => NONE

fun failed_theorem_line () =
  case active_theorem_name () of
      NONE => ""
    | SOME name => "\nholbuild failed theorem: " ^ name

fun failed_step_end_line () =
  case !failed_step_end_ref of
      NONE => ""
    | SOME end_pos => "\nholbuild failed fragment end: " ^ Int.toString end_pos

fun current_history () =
  case !proof_history_ref of
      SOME history => history
    | NONE => raise Fail "proof IR goal history is not initialized"

fun set_history history = proof_history_ref := SOME history
fun clear_history () = proof_history_ref := NONE

fun project_history f = History.project f (current_history())

fun init_history g limit =
  set_history (History.new_history {obj = goalStack.new_goal g Lib.I,
                                    limit = Int.max(15, limit)})

fun append_history f = set_history (History.apply f (current_history()))
fun ensure_history_limit limit = set_history (History.set_limit (current_history()) (Int.max(15, limit)))

fun history_top_goals () = project_history goalStack.top_goals
fun history_top_thm () = project_history goalStack.extract_thm

fun print_goal_state label =
  let val goals = history_top_goals()
  in
    TextIO.output(TextIO.stdErr,
      String.concat ["\nholbuild goal state at failed fragment: ", label,
                     failed_theorem_line (),
                     failed_step_end_line (),
                     "\nholbuild remaining goals: ", Int.toString (length goals), "\n",
                     "holbuild top goal:\n",
                     top_goal_text goals,
                     "holbuild end top goal\n"])
  end
  handle e =>
    TextIO.output(TextIO.stdErr,
      String.concat ["holbuild failed to print goal state: ", General.exnMessage e, "\n"])

fun report_step_failure label e = (save_failed_prefix_checkpoint (); print_goal_state label; raise e)

fun compile_tactic label program =
  if smlExecute.quse_string ("HolbuildProofRuntime.compiled_tactic_ref := (" ^ program ^ ");") then
    !compiled_tactic_ref
  else
    raise Fail ("tactic fragment did not compile: " ^ label)

fun compile_list_tactic label program =
  if smlExecute.quse_string ("HolbuildProofRuntime.compiled_list_tactic_ref := (" ^ program ^ ");") then
    !compiled_list_tactic_ref
  else
    raise Fail ("list tactic fragment did not compile: " ^ label)

fun apply_tactic_step label program =
  let val tactic = compile_tactic label program
  in
    with_tactic_timeout label (fn () => append_history (goalStack.expandf tactic)) ()
    handle e => report_step_failure label e
  end

fun no_open_goals () =
  ((history_top_goals (); false)
   handle _ => true)

fun allgoals_suffix_label label = String.isPrefix ">> " label

fun apply_list_tactic_step label program =
  if allgoals_suffix_label label andalso no_open_goals () then ()
  else
    let val list_tactic = compile_list_tactic label program
    in
      with_tactic_timeout label (fn () => append_history (goalStack.expand_listf list_tactic)) ()
      handle e => report_step_failure label e
    end

fun gentle_then1 tac1 tac2 goal =
  let
    fun chop 0 front rest = (List.rev front, rest)
      | chop n front (x :: xs) = chop (n - 1) (x :: front) xs
      | chop _ _ [] = raise Fail "gentle_then1 validation underflow"
    val (subgoals, validation) = tac1 goal
  in
    case subgoals of
        [] => ([], validation)
      | head :: tail =>
          let val (head_goals, head_validation) = tac2 head
          in
            (head_goals @ tail,
             fn thms =>
               let val (head_thms, tail_thms) = chop (length head_goals) [] thms
               in validation (head_validation head_thms :: tail_thms) end)
          end
  end

fun apply_gentle_then1_step label false first_program second_program =
      let
        val first_tactic = compile_tactic label first_program
        val second_tactic = compile_tactic label second_program
      in
        with_tactic_timeout label
          (fn () => append_history (goalStack.expandf (gentle_then1 first_tactic second_tactic))) ()
        handle e => report_step_failure label e
      end
  | apply_gentle_then1_step label true first_program second_program =
      let
        val first_tactic = compile_tactic label first_program
        val second_tactic = compile_tactic label second_program
      in
        with_tactic_timeout label
          (fn () => append_history (goalStack.expand_listf (Tactical.ALLGOALS (gentle_then1 first_tactic second_tactic)))) ()
        handle e => report_step_failure label e
      end

fun step proof_step =
  case proof_step of
      HolbuildProofIr.StepTactic {label, program, ...} => apply_tactic_step label program
    | HolbuildProofIr.StepList {label, program, ...} => apply_list_tactic_step label program
    | HolbuildProofIr.StepChoice {label, program, ...} => apply_tactic_step label program
    | HolbuildProofIr.StepListChoice {label, program, ...} => apply_list_tactic_step label program
    | HolbuildProofIr.StepGentleThen1 {label, list_suffix, first_program, second_program, ...} =>
        apply_gentle_then1_step label list_suffix first_program second_program
    | HolbuildProofIr.StepPlain _ => raise Fail "plain proof step must cover the whole theorem"

fun inspection_matches wanted name =
  case wanted of NONE => false | SOME selected => selected = name

fun trace_enabled () =
  !trace_active_ref orelse Option.getOpt(env_bool "HOLBUILD_GOALFRAG_TRACE", false)

fun plan_enabled () =
  !plan_active_ref orelse trace_enabled ()

fun current_goal_count () = length (history_top_goals()) handle _ => ~1

fun trace_line parts =
  if trace_enabled () then TextIO.output(TextIO.stdErr, String.concat parts) else ()

fun display_label label =
  String.translate (fn #"\n" => "\\n" | #"\t" => "\\t" | c => String.str c) label

fun trace_plan theorem_name plan =
  if plan_enabled () then
    (TextIO.output(TextIO.stdErr,
       String.concat ["holbuild proof-ir plan theorem=", theorem_name,
                      " steps=", Int.toString (length plan), "\n"]);
     List.app
       (fn (index, proof_step) =>
          TextIO.output(TextIO.stdErr,
            String.concat ["holbuild proof-ir plan step=", Int.toString index,
                           " theorem=", theorem_name,
                           " kind=", HolbuildProofIr.step_kind proof_step,
                           " end=", Int.toString (HolbuildProofIr.step_end proof_step),
                           " label=", display_label (HolbuildProofIr.step_label proof_step), "\n"]))
       (ListPair.zip (List.tabulate(length plan, fn i => i), plan)))
  else ()

fun stop_after_plan_if_requested () =
  if !plan_active_ref andalso not (!trace_active_ref) then
    case !plan_only_marker_ref of
        NONE => ()
      | SOME path => (write_text_file path "holbuild-proof-ir-plan-ok\n";
                      OS.Process.exit OS.Process.success)
  else ()

fun trace_before index proof_step =
  trace_line ["holbuild proof-ir before theorem=", !trace_current_theorem_ref,
              " step=", Int.toString index,
              " kind=", HolbuildProofIr.step_kind proof_step,
              " goals=", Int.toString (current_goal_count()),
              " label=", display_label (HolbuildProofIr.step_label proof_step), "\n"]

fun trace_after status elapsed index proof_step =
  trace_line ["holbuild proof-ir after theorem=", !trace_current_theorem_ref,
              " step=", Int.toString index,
              " kind=", HolbuildProofIr.step_kind proof_step,
              " status=", status,
              " elapsed_ms=", fmt_ms elapsed,
              " goals=", Int.toString (current_goal_count()),
              " label=", display_label (HolbuildProofIr.step_label proof_step), "\n"]

fun run_maybe_traced_step index proof_step =
  let
    val old_failed_step_end = !failed_step_end_ref
    val _ = failed_step_end_ref := SOME (HolbuildProofIr.step_end proof_step)
    fun restore () = failed_step_end_ref := old_failed_step_end
  in
    if trace_enabled () then
      let
        val _ = trace_before index proof_step
        val t0 = Time.now()
        val result = (step proof_step; NONE) handle e => SOME e
        val elapsed = seconds (t0, Time.now())
      in
        case result of
            NONE => (trace_after "ok" elapsed index proof_step; restore ())
          | SOME e => (trace_after "failed" elapsed index proof_step; restore (); raise e)
      end
    else (step proof_step; restore ())
  end

fun run_steps_from _ [] = ()
  | run_steps_from index (proof_step :: rest) =
      (successful_step_count_ref := index;
       run_maybe_traced_step index proof_step;
       successful_step_count_ref := index + 1;
       successful_prefix_end_ref := HolbuildProofIr.step_end proof_step;
       run_steps_from (index + 1) rest)

fun drop_steps 0 steps = steps
  | drop_steps _ [] = []
  | drop_steps n (_ :: rest) = drop_steps (n - 1) rest

fun run_steps steps =
  (successful_step_count_ref := 0;
   successful_prefix_end_ref := 0;
   run_steps_from 0 steps)

datatype 'a traced_result = TraceOk of 'a | TraceError of exn

fun run_whole_tactic g label tac =
  with_tactic_timeout label (fn () => Tactical.TAC_PROOF(g, tac)) ()
  handle e => (init_history g 15; print_goal_state label; clear_history (); raise e)

fun backup_n 0 = ()
  | backup_n n = (set_history (History.undo (current_history())); backup_n (n - 1))

fun drop_all () = clear_history ()

fun atomic_prove label g tac =
  with_tactic_timeout label (fn () => Tactical.TAC_PROOF(g, tac)) ()
  handle e => (init_history g 15; report_step_failure label e)

fun with_theorem_trace name f =
  let
    val old_active = !trace_active_ref
    val old_plan_active = !plan_active_ref
    val old_name = !trace_current_theorem_ref
    val _ = plan_active_ref := (inspection_matches (!plan_theorem_ref) name orelse !trace_all_ref)
    val _ = trace_active_ref := !trace_all_ref
    val _ = trace_current_theorem_ref := name
    val result = TraceOk (f ()) handle e => TraceError e
    val _ = trace_active_ref := old_active
    val _ = plan_active_ref := old_plan_active
    val _ = trace_current_theorem_ref := old_name
  in
    case result of TraceOk value => value | TraceError e => raise e
  end

fun proof_ir_prove name end_path end_ok checkpoint_depth g tactic_text =
  let
    val _ = active_tactic_text_ref := tactic_text
    val plan = HolbuildProofIr.steps tactic_text
    val _ = trace_plan name plan
    val _ = stop_after_plan_if_requested ()
  in
    case plan of
        [HolbuildProofIr.StepPlain {label, ...}] =>
          let
            val th = atomic_prove label g (compile_tactic label (HolbuildProofIr.step_program (hd plan)))
            val _ = save_checkpoint "end_of_proof" false end_path end_ok checkpoint_depth
          in th end
      | _ =>
          let
            val _ = init_history g (length plan + 1)
            val _ = run_steps plan
            val th = history_top_thm()
                     handle e => (print_goal_state (name ^ " finish"); raise e)
            val _ = save_checkpoint "end_of_proof" false end_path end_ok checkpoint_depth
            val _ = drop_all()
          in th end
  end

fun common_prefix_size old_text new_text =
  let
    val old_n = size old_text
    val new_n = size new_text
    val limit = Int.min(old_n, new_n)
    fun loop i =
      if i >= limit then i
      else if String.sub(old_text, i) = String.sub(new_text, i) then loop (i + 1)
      else i
  in
    loop 0
  end

fun step_count_at_prefix common_bytes plan =
  let
    fun loop count [] = count
      | loop count (proof_step :: rest) =
          if HolbuildProofIr.step_end proof_step <= common_bytes then loop (count + 1) rest else count
  in
    loop 0 plan
  end

fun finish_failed_prefix name old_prefix_text old_step_count tactic_text =
  with_theorem_trace name (fn () =>
    let
      val _ = active_tactic_text_ref := tactic_text
      val plan = HolbuildProofIr.steps tactic_text
      val _ = ensure_history_limit (length plan + 1)
      val _ = trace_plan name plan
      val _ = stop_after_plan_if_requested ()
      val common_bytes = common_prefix_size old_prefix_text tactic_text
      val skip_count = step_count_at_prefix common_bytes plan
      val backup_count = Int.max(0, old_step_count - skip_count)
      val _ = backup_n backup_count
      val _ = successful_step_count_ref := skip_count
      val _ = successful_prefix_end_ref := common_bytes
      val _ = run_steps_from skip_count (drop_steps skip_count plan)
      val th = history_top_thm()
               handle e => (print_goal_state (name ^ " finish"); raise e)
      val _ = drop_all()
    in th end)

fun prove_outer_theorem (g, tac) (_, name, tactic_text, _, _, end_path, end_ok, _, _, has_attrs, checkpoint_depth) =
  let
    val atomic = has_attrs orelse tactic_text = ""
    val _ = proving_with_proof_ir_ref := true
    val th =
      with_theorem_trace name (fn () =>
        if atomic then atomic_prove name g tac
        else proof_ir_prove name end_path end_ok checkpoint_depth g tactic_text)
      handle e => (proving_with_proof_ir_ref := false; raise e)
    val _ = proving_with_proof_ir_ref := false
    val _ = theorem_info_ref := NONE
  in
    th
  end

fun proof_ir_prover (g, tac) =
  if !proving_with_proof_ir_ref then
    Tactical.TAC_PROOF(g, tac)
  else
    case !theorem_info_ref of
        NONE => Tactical.TAC_PROOF(g, tac)
      | SOME info =>
          prove_outer_theorem (g, tac) info
          handle e =>
            (proving_with_proof_ir_ref := false;
             theorem_info_ref := NONE;
             context_info_ref := NONE;
             drop_all();
             raise e)

fun install ({checkpoint_enabled, tactic_timeout, timeout_marker, plan_theorem, trace_all, plan_only_marker} : config) =
  (checkpoint_enabled_ref := checkpoint_enabled;
   tactic_timeout_ref := tactic_timeout;
   tactic_timeout_marker_ref := timeout_marker;
   plan_theorem_ref := plan_theorem;
   trace_all_ref := trace_all;
   plan_only_marker_ref := plan_only_marker;
   plan_active_ref := false;
   trace_active_ref := false;
   theorem_info_ref := NONE;
   context_info_ref := NONE;
   proving_with_proof_ir_ref := false;
   Tactical.set_prover proof_ir_prover)

end
