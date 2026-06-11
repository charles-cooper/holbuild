structure HolbuildAnalyserMain =
struct

structure P = HolbuildAnalysisProtocol
structure D = HolbuildAnalyserDependencyExtract

exception Error of string

type file_req = {id : string, path : string, wants : string list}

fun die msg = raise Error msg

fun read_all path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun write_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun member x xs = List.exists (fn y => x = y) xs

fun parse_request path =
  let
    val lines = String.tokens (fn c => c = #"\n") (read_all path)
    fun loop lines files =
      case lines of
          [] => die "request missing end"
        | line :: rest =>
            (case P.split line of
                 ["version", v] => if v = P.protocol_version then loop rest files else die ("unsupported protocol version: " ^ v)
               | ["command", "analyse"] => loop rest files
               | "file" :: id :: file :: wants => loop rest ({id = id, path = file, wants = wants} :: files)
               | ["end"] => rev files
               | [] => loop rest files
               | fields => die ("bad request line: " ^ line))
  in
    loop lines []
  end

fun emit_deps ({loads, uses, extra_deps, holdep_mentions} : D.t) =
  map (fn x => P.join ["load", x]) loads @
  map (fn x => P.join ["use", x]) uses @
  map (fn x => P.join ["extra-dep", x]) extra_deps @
  map (fn x => P.join ["mention", x]) holdep_mentions

fun analyse_file ({id, path, wants} : file_req) =
  let
    val deps_lines = if null wants orelse member "deps" wants then emit_deps (D.extract path) else []
  in
    P.join ["begin-file", id] :: deps_lines @ [P.join ["end-file", id]]
  end

fun response files =
  String.concatWith "\n" ([P.join ["version", P.protocol_version], P.join ["ok"]] @
                          List.concat (map analyse_file files) @
                          [P.join ["end"]]) ^ "\n"

fun arg_value flag args =
  case args of
      [] => NONE
    | x :: y :: rest => if x = flag then SOME y else arg_value flag (y :: rest)
    | _ :: rest => arg_value flag rest

fun main args =
  if member "--version" args then (print ("holbuild-hol-analyser " ^ P.analyser_format_version ^ "\n"); OS.Process.success)
  else
    case (arg_value "--request" args, arg_value "--response" args) of
        (SOME req, SOME resp) =>
          ((write_file resp (response (parse_request req)); OS.Process.success)
           handle Error msg => (TextIO.output(TextIO.stdErr, msg ^ "\n"); OS.Process.failure)
                | D.Error msg => (TextIO.output(TextIO.stdErr, msg ^ "\n"); OS.Process.failure)
                | e => (TextIO.output(TextIO.stdErr, General.exnMessage e ^ "\n"); OS.Process.failure))
      | _ => (TextIO.output(TextIO.stdErr, "usage: holbuild-hol-analyser --request FILE --response FILE\n"); OS.Process.failure)

end
