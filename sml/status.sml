structure HolbuildStatus =
struct

datatype outcome = Built | UpToDate | Restored | Inspected

type active_node = {key : string, label : string, started_at : Time.time}

type t = {
  enabled : bool,
  total : int,
  jobs : int,
  width : int option ref,
  width_checked_at : Time.time ref,
  finished : int ref,
  built : int ref,
  up_to_date : int ref,
  restored : int ref,
  active : active_node list ref,
  started_at : Time.time,
  ended : bool ref,
  mutex : Mutex.mutex
}

val current_status : t option ref = ref NONE
val json_mode_ref = ref false
val verbose_mode_ref = ref false
val json_mutex = Mutex.mutex ()

val clear_to_eol = "\027[0K"

fun set_json_mode enabled = json_mode_ref := enabled
fun json_mode () = !json_mode_ref
fun set_verbose_mode enabled = verbose_mode_ref := enabled
fun verbose_mode () = !verbose_mode_ref

fun hex_digit n =
  String.sub("0123456789abcdef", n)

fun unicode_escape code =
  String.implode [#"\\", #"u", #"0", #"0", hex_digit (code div 16), hex_digit (code mod 16)]

fun json_escape s =
  String.translate
    (fn #"\\" => "\\\\"
      | #"\"" => "\\\""
      | #"\n" => "\\n"
      | #"\r" => "\\r"
      | #"\t" => "\\t"
      | #"\b" => "\\b"
      | #"\f" => "\\f"
      | c => if Char.ord c < 32 then unicode_escape (Char.ord c) else String.str c)
    s

fun json_string_field name value =
  "\"" ^ name ^ "\":\"" ^ json_escape value ^ "\""

fun json_int_field name value =
  "\"" ^ name ^ "\":" ^ Int.toString value

fun json_optional_string_field name value =
  case value of
      NONE => []
    | SOME text => [json_string_field name text]

fun short_hash text = String.substring(HolbuildHash.string_sha1 text, 0, 12)

fun json_node_key key label = label ^ "#" ^ short_hash key

fun json_node_metadata key =
  case String.fields (fn c => c = #"\000") key of
      [package, source, _] =>
        json_optional_string_field "package" (SOME package) @
        json_optional_string_field "source" (SOME source)
    | _ => []

fun json_node_fields key label =
  [json_string_field "key" (json_node_key key label),
   json_string_field "target" label] @
  json_node_metadata key

val instrumented_log_prefix = "instrumented log: "

fun line_suffix prefix line =
  if String.isPrefix prefix line then
    SOME (String.extract(line, size prefix, NONE))
  else NONE

fun first_log_path lines =
  case lines of
      [] => NONE
    | line :: rest =>
        (case line_suffix instrumented_log_prefix line of
             SOME path => SOME path
           | NONE => first_log_path rest)

fun log_path_from_message message =
  first_log_path (String.fields (fn c => c = #"\n") message)

fun json_log_field message = json_optional_string_field "log" (log_path_from_message message)

fun json_fields fields = "{" ^ String.concatWith "," fields ^ "}\n"

fun emit_json stream event fields =
  (Mutex.lock json_mutex;
   (TextIO.output(stream, json_fields (json_string_field "event" event :: fields));
    TextIO.flushOut stream)
   before Mutex.unlock json_mutex)
  handle e => (Mutex.unlock json_mutex; raise e)

fun json_message stream_name stream text =
  emit_json stream "message"
    [json_string_field "stream" stream_name,
     json_string_field "message" text]

fun error msg =
  emit_json TextIO.stdErr "error" (json_string_field "message" msg :: json_log_field msg)

fun env_truthy s = s = "1" orelse s = "true" orelse s = "yes" orelse s = "on"
fun env_falsey s = s = "0" orelse s = "false" orelse s = "no" orelse s = "off"

fun env_status () =
  case OS.Process.getEnv "HOLBUILD_STATUS" of
      NONE => NONE
    | SOME s =>
        let val lower = String.map Char.toLower s
        in
          if env_truthy lower then SOME true
          else if env_falsey lower then SOME false
          else NONE
        end

fun ansi_stdout () = terminal_primitives.strmIsTTY TextIO.stdOut andalso terminal_primitives.TERM_isANSI ()

fun enabled_by_default () =
  if json_mode () then false
  else
    case env_status () of
        SOME b => b
      | NONE => ansi_stdout ()

fun positive_int s =
  case Int.fromString s of
      SOME n => if n > 0 then SOME n else NONE
    | NONE => NONE

fun shell_output command =
  let
    val proc = Unix.execute ("/bin/sh", ["-c", command])
    val output = TextIO.inputAll (Unix.textInstreamOf proc)
  in
    if OS.Process.isSuccess (Unix.reap proc) then SOME output else NONE
  end
  handle OS.SysErr _ => NONE

fun first_positive_int text =
  let
    fun first words =
      case words of
          [] => NONE
        | word :: rest =>
            (case positive_int word of
                 SOME n => SOME n
               | NONE => first rest)
  in
    first (String.tokens Char.isSpace text)
  end

fun stty_width () =
  Option.mapPartial first_positive_int
    (shell_output "stty size < /dev/tty 2>/dev/null | awk '{print $2}'")

fun tput_width () =
  Option.mapPartial first_positive_int (shell_output "tput cols 2>/dev/null")

fun env_width () = Option.mapPartial positive_int (OS.Process.getEnv "COLUMNS")

fun terminal_width () =
  if terminal_primitives.strmIsTTY TextIO.stdOut then
    case stty_width () of
        SOME width => SOME width
      | NONE => (case tput_width () of SOME width => SOME width | NONE => env_width ())
  else
    env_width ()

fun outcome_text Built = "built"
  | outcome_text UpToDate = "is up to date"
  | outcome_text Restored = "restored from cache"
  | outcome_text Inspected = "inspected"

fun count_outcome ({built, up_to_date, restored, ...} : t) outcome =
  case outcome of
      Built => built := !built + 1
    | UpToDate => up_to_date := !up_to_date + 1
    | Restored => restored := !restored + 1
    | Inspected => ()

fun elapsed ({started_at, ...} : t) = Time.-(Time.now (), started_at)

fun elapsed_seconds_text status = Real.fmt (StringCvt.FIX (SOME 3)) (Time.toReal (elapsed status)) ^ "s"

fun elapsed_ms status = Real.round (Time.toReal (elapsed status) * 1000.0)

fun remove_active key active = List.filter (fn {key = k, ...} => k <> key) active

fun find_active key active = List.find (fn {key = k, ...} => k = key) active

fun active_labels active = map (fn {label, ...} => label) active

fun active_elapsed_text NONE = ""
  | active_elapsed_text (SOME {started_at, ...}) =
      " in " ^ Real.fmt (StringCvt.FIX (SOME 3))
        (Time.toReal (Time.-(Time.now (), started_at))) ^ "s"

fun line ({total, jobs, finished, built, up_to_date, restored, active, ...} : t) =
  let
    val running = active_labels (!active)
    val prefix =
      String.concat
        ["holbuild done=", Int.toString (!finished), "/", Int.toString total,
         " running=", Int.toString (length running), "/", Int.toString jobs,
         " built=", Int.toString (!built),
         " from_cache=", Int.toString (!restored),
         " unchanged=", Int.toString (!up_to_date)]
  in
    case running of
        [] => prefix
      | _ => prefix ^ " :: " ^ String.concatWith ", " running
  end

fun final_line status = line status ^ " elapsed=" ^ elapsed_seconds_text status

fun finish_text status = "holbuild finished in " ^ elapsed_seconds_text status ^ "\n"

fun fit width s =
  case width of
      NONE => s
    | SOME columns =>
        if size s <= columns then s
        else if columns <= 3 then ""
        else String.substring (s, 0, columns - 3) ^ "..."

val width_refresh_seconds = 0.5

fun refresh_width_if_stale ({width, width_checked_at, ...} : t) =
  let
    val now = Time.now ()
    val age = Time.toReal (Time.-(now, !width_checked_at))
  in
    if age >= width_refresh_seconds then
      (width := terminal_width (); width_checked_at := now)
    else ()
  end

fun redraw (status as {enabled, ended, width, ...} : t) =
  if not enabled orelse !ended then ()
  else
    (refresh_width_if_stale status;
     TextIO.output (TextIO.stdOut, "\r" ^ fit (!width) (line status) ^ clear_to_eol);
     TextIO.flushOut TextIO.stdOut)

fun with_lock ({mutex, ...} : t) f =
  (Mutex.lock mutex; f () before Mutex.unlock mutex)
  handle e => (Mutex.unlock mutex; raise e)

fun create {total, jobs} =
  let
    val status =
      {enabled = enabled_by_default (),
       total = total,
       jobs = jobs,
       width = ref (terminal_width ()),
       width_checked_at = ref (Time.now ()),
       finished = ref 0,
       built = ref 0,
       up_to_date = ref 0,
       restored = ref 0,
       active = ref [],
       started_at = Time.now (),
       ended = ref false,
       mutex = Mutex.mutex ()}
  in
    current_status := SOME status;
    status
  end

fun start_node status key label =
  with_lock status
    (fn () =>
        let val {enabled, active, ended, ...} = status
        in
          if !ended then ()
          else
            (active := {key = key, label = label, started_at = Time.now ()} :: remove_active key (!active);
             if json_mode () then
               emit_json TextIO.stdOut "node_started" (json_node_fields key label)
             else if enabled then redraw status
             else if verbose_mode () then
               (TextIO.output (TextIO.stdOut, label ^ " started\n");
                TextIO.flushOut TextIO.stdOut)
             else ())
        end)

fun finish_node status key label outcome =
  with_lock status
    (fn () =>
        let
          val {enabled, total, finished, active, ended, ...} = status
          val elapsed = active_elapsed_text (find_active key (!active))
        in
          if !ended then ()
          else
            (finished := !finished + 1;
             count_outcome status outcome;
             active := remove_active key (!active);
             if json_mode () then
               emit_json TextIO.stdOut "node_finished"
                 (json_node_fields key label @
                  [json_string_field "outcome" (outcome_text outcome),
                   json_int_field "finished" (!finished),
                   json_int_field "total" total])
             else if enabled then redraw status
             else
               (TextIO.output (TextIO.stdOut,
                  label ^ " " ^ outcome_text outcome ^
                  (if verbose_mode () then elapsed else "") ^ "\n");
                TextIO.flushOut TextIO.stdOut))
        end)

fun finish status =
  (with_lock status
     (fn () =>
         let val {enabled, ended, total, finished, built, restored, up_to_date, ...} = status
         in
           if !ended then ()
           else
             (if json_mode () then
                emit_json TextIO.stdOut "build_finished"
                  [json_int_field "elapsed_ms" (elapsed_ms status),
                   json_int_field "total" total,
                   json_int_field "built" (!built),
                   json_int_field "from_cache" (!restored),
                   json_int_field "unchanged" (!up_to_date)]
              else if enabled then
                (TextIO.output (TextIO.stdOut, "\r" ^ fit (!(#width status)) (final_line status) ^ clear_to_eol ^ "\n");
                 TextIO.flushOut TextIO.stdOut)
              else if !finished = total then
                (TextIO.output (TextIO.stdOut, finish_text status); TextIO.flushOut TextIO.stdOut)
              else ();
              ended := true)
         end);
   current_status := NONE)

fun message_to stream_name stream text =
  if json_mode () then json_message stream_name stream text
  else
    case !current_status of
        NONE => (TextIO.output (stream, text); TextIO.flushOut stream)
      | SOME status =>
          with_lock status
            (fn () =>
                let val {enabled, ended, ...} = status
                in
                  if enabled andalso not (!ended) then
                    (TextIO.output (TextIO.stdOut, "\r" ^ clear_to_eol);
                     TextIO.flushOut TextIO.stdOut;
                     TextIO.output (stream, text);
                     TextIO.flushOut stream;
                     redraw status)
                  else
                    (TextIO.output (stream, text); TextIO.flushOut stream)
                end)

fun message_stdout text = message_to "stdout" TextIO.stdOut text
fun message_stderr text = message_to "stderr" TextIO.stdErr text
fun message stream text = message_to "stdout" stream text

fun fail status key label msg =
  (with_lock status
     (fn () =>
         let val {enabled, active, ended, ...} = status
         in
           if !ended then ()
           else
             (active := remove_active key (!active);
              if json_mode () then
                emit_json TextIO.stdOut "node_failed"
                  (json_node_fields key label @ json_log_field msg)
              else if enabled then
                (TextIO.output (TextIO.stdOut, "\r" ^ clear_to_eol);
                 TextIO.flushOut TextIO.stdOut)
              else ();
              ended := true)
         end);
   current_status := NONE)

end
