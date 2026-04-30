structure HolbuildStatus =
struct

datatype outcome = Built | UpToDate | Restored

type active_node = {key : string, label : string}

type t = {
  enabled : bool,
  total : int,
  finished : int ref,
  built : int ref,
  up_to_date : int ref,
  restored : int ref,
  active : active_node list ref,
  ended : bool ref,
  mutex : Thread.Mutex.mutex
}

val clear_to_eol = "\027[0K"

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
  case env_status () of
      SOME b => b
    | NONE => ansi_stdout ()

fun positive_int s =
  case Int.fromString s of
      SOME n => if n > 0 then SOME n else NONE
    | NONE => NONE

fun terminal_width () =
  case OS.Process.getEnv "COLUMNS" of
      SOME s => Option.getOpt (positive_int s, 80)
    | NONE => 80

fun outcome_text Built = "built"
  | outcome_text UpToDate = "is up to date"
  | outcome_text Restored = "restored from cache"

fun count_outcome ({built, up_to_date, restored, ...} : t) outcome =
  case outcome of
      Built => built := !built + 1
    | UpToDate => up_to_date := !up_to_date + 1
    | Restored => restored := !restored + 1

fun remove_active key active = List.filter (fn {key = k, ...} => k <> key) active

fun active_labels active = map (fn {label, ...} => label) active

fun line ({total, finished, built, up_to_date, restored, active, ...} : t) =
  let
    val running = active_labels (!active)
    val prefix =
      String.concat
        ["holbuild [", Int.toString (!finished), "/", Int.toString total, "] ",
         "active=", Int.toString (length running),
         " built=", Int.toString (!built),
         " cache=", Int.toString (!restored),
         " up=", Int.toString (!up_to_date)]
  in
    case running of
        [] => prefix
      | _ => prefix ^ " :: " ^ String.concatWith ", " running
  end

fun fit width s =
  if size s <= width then s
  else if width <= 1 then ""
  else String.substring (s, 0, width - 1)

fun redraw (status as {enabled, ended, ...} : t) =
  if not enabled orelse !ended then ()
  else
    (TextIO.output (TextIO.stdOut, "\r" ^ fit (terminal_width ()) (line status) ^ clear_to_eol);
     TextIO.flushOut TextIO.stdOut)

fun with_lock ({mutex, ...} : t) f =
  (Thread.Mutex.lock mutex; f () before Thread.Mutex.unlock mutex)
  handle e => (Thread.Mutex.unlock mutex; raise e)

fun create total =
  {enabled = enabled_by_default (),
   total = total,
   finished = ref 0,
   built = ref 0,
   up_to_date = ref 0,
   restored = ref 0,
   active = ref [],
   ended = ref false,
   mutex = Thread.Mutex.mutex ()}

fun start_node status key label =
  with_lock status
    (fn () =>
        let val {enabled, active, ended, ...} = status
        in
          if !ended then ()
          else if enabled then
            (active := {key = key, label = label} :: remove_active key (!active);
             redraw status)
          else ()
        end)

fun finish_node status key label outcome =
  with_lock status
    (fn () =>
        let val {enabled, finished, active, ended, ...} = status
        in
          if !ended then ()
          else
            (finished := !finished + 1;
             count_outcome status outcome;
             active := remove_active key (!active);
             if enabled then redraw status
             else if outcome = Built then ()
             else print (label ^ " " ^ outcome_text outcome ^ "\n"))
        end)

fun finish status =
  with_lock status
    (fn () =>
        let val {enabled, ended, ...} = status
        in
          if !ended then ()
          else
            (if enabled then (redraw status; TextIO.output (TextIO.stdOut, "\n"); TextIO.flushOut TextIO.stdOut) else ();
             ended := true)
        end)

fun fail status key label msg =
  with_lock status
    (fn () =>
        let val {enabled, active, ended, ...} = status
        in
          if !ended then ()
          else
            (active := remove_active key (!active);
             if enabled then
               (TextIO.output (TextIO.stdOut,
                  "\r" ^ fit (terminal_width ())
                    (line status ^ " failed " ^ label ^ ": " ^ msg) ^ clear_to_eol ^ "\n");
                TextIO.flushOut TextIO.stdOut)
             else ();
             ended := true)
        end)

end
