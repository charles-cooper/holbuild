(* Caller must load HOLSourceParser, TacticParse, smlExecute, and smlTimeout
   before using this helper; the generated staged script does that prelude. *)
structure HolbuildGoalfragRuntime =
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
val proving_with_goalfrag_ref = ref false
val active_tactic_text_ref = ref ""
val successful_step_count_ref = ref 0
val successful_prefix_end_ref = ref 0

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

(* Keep the new checkpoint filename stable. PolyML child states record parent
   filenames, so saving to a temporary filename and then renaming can leave a
   later child unable to find its parent. A future implementation may use PolyML
   parent-name retargeting, but until that is explicit and tested we replace in
   place with a .bak pair that checkpoint selection can restore after interrupt. *)
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
            val step_count = !successful_step_count_ref
            val meta_text =
              String.concat ["step_count=", Int.toString step_count, "\n",
                             "prefix_end=", Int.toString prefix_end, "\n"]
            val _ = proofManagerLib.set_backup (step_count + 1)
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

fun goal_text goal = PP.pp_to_string 100 proofManagerLib.std_goal_pp goal ^ "\n"

fun top_goal_text [] = "<no open goals>\n"
  | top_goal_text (goal :: _) = goal_text goal

fun numbered_goal_text total (index, goal) =
  String.concat ["holbuild goal ", Int.toString index, " of ", Int.toString total, ":\n",
                 goal_text goal]

val all_goals_limit = 4096

fun limited_all_goals_text text =
  if size text <= all_goals_limit then text
  else
    String.concat [String.substring(text, 0, all_goals_limit),
                   "\nholbuild failed tactic input goals truncated after ", Int.toString all_goals_limit, " bytes\n"]

fun all_goals_text goals =
  if length goals <= 1 then ""
  else
    let
      val total = length goals
      val indexed = ListPair.zip (List.tabulate(total, fn i => i + 1), goals)
      val text = String.concat (map (numbered_goal_text total) indexed)
    in
      String.concat ["holbuild all failed tactic input goals:\n", limited_all_goals_text text,
                     "holbuild end all failed tactic input goals\n"]
    end

fun active_theorem_name () =
  case !theorem_info_ref of
      SOME (_, name, _, _, _, _, _, _, _, _, _) => SOME name
    | NONE => NONE

fun failed_theorem_line () =
  case active_theorem_name () of
      NONE => ""
    | SOME name => "\nholbuild failed theorem: " ^ name

val failed_step_end_ref = ref NONE : int option ref
val failed_step_span_ref = ref NONE : (int * int) option ref
val failed_plan_position_ref = ref NONE : (int * string * string) option ref

fun failed_step_end_line () =
  case !failed_step_end_ref of
      NONE => ""
    | SOME end_pos => "\nholbuild failed fragment end: " ^ Int.toString end_pos

fun failed_step_span_line () =
  case !failed_step_span_ref of
      NONE => ""
    | SOME (start_pos, end_pos) =>
        String.concat ["\nholbuild failed fragment span: ", Int.toString start_pos,
                       " ", Int.toString end_pos]

fun plan_position_label label =
  String.translate (fn #"\n" => "\\n" | #"\t" => "\\t" | c => String.str c) label

fun failed_plan_position_line () =
  case !failed_plan_position_ref of
      NONE => ""
    | SOME (index, kind, label) =>
        String.concat ["\nholbuild plan position: ", HolbuildGoalfragPlan.pad2 index,
                       " ", kind, " ", plan_position_label label]

fun print_goal_state label =
  let
    val goals = proofManagerLib.top_goals()
  in
    TextIO.output(TextIO.stdErr,
      String.concat ["\nholbuild goal state at failed fragment: ", label,
                     failed_theorem_line (),
                     failed_step_end_line (),
                     failed_step_span_line (),
                     failed_plan_position_line (),
                     "\nholbuild failed tactic input goal count: ", Int.toString (length goals), "\n",
                     "holbuild failed tactic top input goal:\n",
                     top_goal_text goals,
                     "holbuild end failed tactic top input goal\n",
                     all_goals_text goals])
  end
  handle e =>
    TextIO.output(TextIO.stdErr,
      String.concat ["holbuild failed to print goal state: ", General.exnMessage e, "\n"])

(* Use the shared GoalFrag planner/step IR so goalfrag-plan and runtime
   execution cannot diverge.  The generated staging prelude loads
   sml/goalfrag_plan.sml before this helper. *)
open HolbuildGoalfragPlan

fun report_step_failure label e = (save_failed_prefix_checkpoint (); print_goal_state label; raise e)

fun quiet_goalstack f = Lib.with_flag (proofManagerLib.chatting, false) f ()

fun apply_ftac label ftac =
  with_tactic_timeout label (fn () => quiet_goalstack (fn () => (proofManagerLib.ef ftac; ()))) ()
  handle e => report_step_failure label e

fun eval_step label program fail_msg =
  with_tactic_timeout label
    (fn () => quiet_goalstack (fn () => if smlExecute.quse_string program then () else raise Fail fail_msg)) ()
  handle e => report_step_failure label e

fun int_arg_open prefix apply label =
  let val arg = String.extract(label, size prefix, NONE)
  in
    case Int.fromString arg of
        SOME n => apply_ftac label (apply n)
      | NONE =>
          eval_step label
            ("proofManagerLib.ef(" ^ prefix ^ "(" ^ arg ^ ")); ")
            ("open fragment failed: " ^ label)
  end

fun open_ftac label =
  case label of
        "open_paren" => goalFrag.open_paren
      | "open_then1" => goalFrag.open_then1
      | "open_first" => goalFrag.open_first
      | "open_repeat" => goalFrag.open_repeat
      | "open_tacs_to_lt" => goalFrag.open_tacs_to_lt
      | "open_null_ok" => goalFrag.open_null_ok
      | "open_last_goal" => goalFrag.open_last_goal
      | "open_head_goal" => goalFrag.open_head_goal
      | "open_select_lt" => goalFrag.open_select_lt
      | "open_first_lt" => goalFrag.open_first_lt
      | _ => raise Fail ("unknown open frag: " ^ label)

fun mid_ftac label =
  case label of
      "next_first" => goalFrag.next_first
    | "next_tacs_to_lt" => goalFrag.next_tacs_to_lt
    | "next_split_lt" => goalFrag.next_split_lt
    | "next_select_lt" => goalFrag.next_select_lt
    | _ => raise Fail ("unknown mid frag: " ^ label)

fun close_ftac label =
  case label of
      "close_paren" => goalFrag.close_paren
    | "close_first" => goalFrag.close_first
    | "close_repeat" => goalFrag.close_repeat
    | "close_first_lt" => goalFrag.close_first_lt
    | _ => raise Fail ("unknown close frag: " ^ label)

fun step (StepOpen {label, ...}) =
      if String.isPrefix "open_nth_goal " label then
        int_arg_open "open_nth_goal " goalFrag.open_nth_goal label
      else if String.isPrefix "open_split_lt " label then
        int_arg_open "open_split_lt " goalFrag.open_split_lt label
      else apply_ftac label (open_ftac label)
  | step (StepMid {label, ...}) = apply_ftac label (mid_ftac label)
  | step (StepClose {label, ...}) = apply_ftac label (close_ftac label)
  | step (StepExpand {label, ...}) =
      eval_step label
        ("proofManagerLib.ef(goalFrag.expand((" ^ label ^ ")));")
        ("tactic fragment failed: " ^ label)
  | step (StepExpandList {label, ...}) =
      eval_step label
        ("proofManagerLib.ef(goalFrag.expand_list((" ^ label ^ ")));")
        ("list tactic fragment failed: " ^ label)
  | step (StepPlain {label, ...}) = raise Fail ("plain tactic fragment must cover the whole proof: " ^ label)
  | step (StepSelect {label, ...}) = raise Fail ("unmerged select fragment: " ^ label)
  | step (StepSelects {label, ...}) = raise Fail ("unmerged select fragments: " ^ label)

fun inspection_matches wanted name =
  case wanted of
      NONE => false
    | SOME selected => selected = name

fun trace_enabled () =
  !trace_active_ref orelse Option.getOpt(env_bool "HOLBUILD_GOALFRAG_TRACE", false)

fun plan_enabled () =
  !plan_active_ref orelse trace_enabled ()

fun current_goal_count () = length (proofManagerLib.top_goals()) handle _ => ~1

fun trace_line parts =
  if trace_enabled () then TextIO.output(TextIO.stdErr, String.concat parts) else ()

fun display_label label =
  String.translate
    (fn #"\n" => "\\n"
      | #"\t" => "\\t"
      | c => String.str c)
    label

fun trace_goalfrag_plan theorem_name plan =
  if plan_enabled () then
    (TextIO.output(TextIO.stdErr,
       String.concat ["holbuild goalfrag plan theorem=", theorem_name,
                      " steps=", Int.toString (length plan), "\n"]);
     List.app
       (fn (index, step') =>
          TextIO.output(TextIO.stdErr,
            String.concat ["holbuild goalfrag plan step=", Int.toString index,
                           " theorem=", theorem_name,
                           " kind=", step_kind step',
                           " end=", Int.toString (step_end step'),
                           " label=", display_label (step_label step'), "\n"]))
       (ListPair.zip (List.tabulate(length plan, fn i => i), plan)))
  else ()

fun stop_after_plan_if_requested () =
  if !plan_active_ref andalso not (!trace_active_ref) then
    case !plan_only_marker_ref of
        NONE => ()
      | SOME path => (write_text_file path "holbuild-goalfrag-plan-ok\n";
                      OS.Process.exit OS.Process.success)
  else ()

fun trace_goalfrag_before index step' =
  trace_line ["holbuild goalfrag before theorem=", !trace_current_theorem_ref,
              " step=", Int.toString index,
              " kind=", step_kind step',
              " goals=", Int.toString (current_goal_count()),
              " label=", display_label (step_label step'), "\n"]

fun trace_goalfrag_after status elapsed index step' =
  trace_line ["holbuild goalfrag after theorem=", !trace_current_theorem_ref,
              " step=", Int.toString index,
              " kind=", step_kind step',
              " status=", status,
              " elapsed_ms=", fmt_ms elapsed,
              " goals=", Int.toString (current_goal_count()),
              " label=", display_label (step_label step'), "\n"]

fun run_maybe_traced_step index step' =
  let
    val old_failed_step_end = !failed_step_end_ref
    val old_failed_step_span = !failed_step_span_ref
    val old_failed_plan_position = !failed_plan_position_ref
    val _ = failed_step_end_ref := SOME (step_end step')
    val _ = failed_step_span_ref := SOME (step_start step', step_end step')
    val _ = failed_plan_position_ref := SOME (index, HolbuildGoalfragPlan.display_kind step', step_label step')
    fun restore () = (failed_step_end_ref := old_failed_step_end;
                      failed_step_span_ref := old_failed_step_span;
                      failed_plan_position_ref := old_failed_plan_position)
  in
    if trace_enabled () then
      let
        val _ = trace_goalfrag_before index step'
        val t0 = Time.now()
        val result = (step step'; NONE) handle e => SOME e
        val elapsed = seconds (t0, Time.now())
      in
        case result of
            NONE => (trace_goalfrag_after "ok" elapsed index step'; restore ())
          | SOME e => (trace_goalfrag_after "failed" elapsed index step'; restore (); raise e)
      end
    else (step step'; restore ())
  end

fun run_steps_from _ [] = ()
  | run_steps_from index (step' :: rest) =
      (successful_step_count_ref := index;
       run_maybe_traced_step index step';
       successful_step_count_ref := index + 1;
       successful_prefix_end_ref := step_end step';
       run_steps_from (index + 1) rest)

fun drop_steps 0 steps = steps
  | drop_steps _ [] = []
  | drop_steps n (_ :: rest) = drop_steps (n - 1) rest

fun run_steps steps =
  (successful_step_count_ref := 0;
   successful_prefix_end_ref := 0;
   run_steps_from 0 steps)

fun runs_whole_tactic tactic_text [StepPlain {end_pos, ...}] = end_pos = size tactic_text
  | runs_whole_tactic _ _ = false

datatype 'a traced_result = TraceOk of 'a | TraceError of exn

fun trace_goalfrag_before_with_goals index step' goals =
  trace_line ["holbuild goalfrag before theorem=", !trace_current_theorem_ref,
              " step=", Int.toString index,
              " kind=", step_kind step',
              " goals=", Int.toString goals,
              " label=", display_label (step_label step'), "\n"]

fun trace_goalfrag_after_with_goals status elapsed index step' goals =
  trace_line ["holbuild goalfrag after theorem=", !trace_current_theorem_ref,
              " step=", Int.toString index,
              " kind=", step_kind step',
              " status=", status,
              " elapsed_ms=", fmt_ms elapsed,
              " goals=", Int.toString goals,
              " label=", display_label (step_label step'), "\n"]

fun run_whole_tactic g step' tac =
  let
    val label = step_label step'
    val old_failed_step_span = !failed_step_span_ref
    val old_failed_plan_position = !failed_plan_position_ref
    val _ = failed_step_span_ref := SOME (step_start step', step_end step')
    val _ = failed_plan_position_ref := SOME (0, HolbuildGoalfragPlan.display_kind step', label)
    fun apply () =
      with_tactic_timeout label (fn () => Tactical.TAC_PROOF(g, tac)) ()
      handle e => (proofManagerLib.set_goal g; print_goal_state label; raise e)
    val _ = successful_step_count_ref := 0
    val _ = successful_prefix_end_ref := 0
    val result =
      if trace_enabled () then
        let
          val _ = trace_goalfrag_before_with_goals 0 step' 1
          val t0 = Time.now()
          val result = TraceOk (apply ()) handle e => TraceError e
          val elapsed = seconds (t0, Time.now())
        in
          case result of
              TraceOk th => (trace_goalfrag_after_with_goals "ok" elapsed 0 step' 0; TraceOk th)
            | TraceError e => (trace_goalfrag_after_with_goals "failed" elapsed 0 step' (current_goal_count()); TraceError e)
        end
      else TraceOk (apply ()) handle e => TraceError e
    val _ = successful_step_count_ref := 1
    val _ = successful_prefix_end_ref := size (!active_tactic_text_ref)
    val _ = failed_step_span_ref := old_failed_step_span
    val _ = failed_plan_position_ref := old_failed_plan_position
  in
    case result of TraceOk th => th | TraceError e => raise e
  end

fun backup_n 0 = ()
  | backup_n n = (proofManagerLib.b(); backup_n (n - 1))

fun drop_all () = (proofManagerLib.drop_all (); ()) handle _ => ()

fun atomic_prove label g tac =
  with_tactic_timeout label (fn () => Tactical.TAC_PROOF(g, tac)) ()
  handle e => (proofManagerLib.set_goal g; report_step_failure label e)

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

fun goalfrag_prove name end_path end_ok checkpoint_depth g tac tactic_text =
  let
    val _ = active_tactic_text_ref := tactic_text
    val plan = steps tactic_text
    val runs_plain = runs_whole_tactic tactic_text plan
    val _ = if runs_plain then () else (proofManagerLib.set_goalfrag g; proofManagerLib.set_backup (length plan + 1))
    val _ = trace_goalfrag_plan name plan
    val _ = stop_after_plan_if_requested ()
    val th =
      if runs_plain then run_whole_tactic g (hd plan) tac
      else
        (run_steps plan;
         proofManagerLib.top_thm()
         handle e => (print_goal_state (name ^ " finish"); raise e))
    val _ = save_checkpoint "end_of_proof" false end_path end_ok checkpoint_depth
    val _ = proofManagerLib.drop_all()
  in th end

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
      | loop count (step' :: rest) =
          if step_end step' <= common_bytes then loop (count + 1) rest else count
  in
    loop 0 plan
  end

fun finish_failed_prefix name old_prefix_text old_step_count tactic_text =
  with_theorem_trace name (fn () =>
    let
      val _ = active_tactic_text_ref := tactic_text
      val plan = steps tactic_text
      val _ = proofManagerLib.set_backup (Int.max(length plan + 1, old_step_count + 1))
      val _ = trace_goalfrag_plan name plan
      val _ = stop_after_plan_if_requested ()
      val common_bytes = common_prefix_size old_prefix_text tactic_text
      val skip_count = step_count_at_prefix common_bytes plan
      val backup_count = Int.max(0, old_step_count - skip_count)
      val _ =
        (backup_n backup_count
         handle History.CANT_BACKUP_ANYMORE =>
           raise Fail (String.concat ["failed-prefix checkpoint cannot rewind ",
                                      Int.toString backup_count,
                                      " GoalFrag steps; checkpoint history retained fewer steps than its metadata step_count=",
                                      Int.toString old_step_count]))
      val _ = successful_step_count_ref := skip_count
      val _ = successful_prefix_end_ref := common_bytes
      val _ = run_steps_from skip_count (drop_steps skip_count plan)
      val th = proofManagerLib.top_thm()
               handle e => (print_goal_state (name ^ " finish"); raise e)
      val _ = proofManagerLib.drop_all()
    in th end)

fun prove_outer_theorem (g, tac) (_, name, tactic_text, _, _, end_path, end_ok, _, _, has_attrs, checkpoint_depth) =
  let
    val atomic = has_attrs orelse tactic_text = ""
    val _ = proving_with_goalfrag_ref := true
    val th =
      with_theorem_trace name (fn () =>
        if atomic then atomic_prove name g tac
        else goalfrag_prove name end_path end_ok checkpoint_depth g tac tactic_text)
      handle e => (proving_with_goalfrag_ref := false; raise e)
    val _ = proving_with_goalfrag_ref := false
    val _ = theorem_info_ref := NONE
  in
    th
  end

fun goalfrag_prover (g, tac) =
  if !proving_with_goalfrag_ref then
    Tactical.TAC_PROOF(g, tac)
  else
    case !theorem_info_ref of
        NONE => Tactical.TAC_PROOF(g, tac)
      | SOME info =>
          prove_outer_theorem (g, tac) info
          handle e =>
            (proving_with_goalfrag_ref := false;
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
   failed_step_end_ref := NONE;
   failed_step_span_ref := NONE;
   failed_plan_position_ref := NONE;
   proving_with_goalfrag_ref := false;
   Tactical.set_prover goalfrag_prover)

end
