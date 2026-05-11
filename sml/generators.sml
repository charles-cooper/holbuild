structure HolbuildGenerators =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

fun die msg = raise Error msg

fun member x xs = List.exists (fn y => x = y) xs

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if FS.access(path, []) handle OS.SysErr _ => false then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun ensure_parent path = ensure_dir (Path.dir path)

fun readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun read_text path =
  let
    val input = TextIO.openIn path
    fun loop acc =
      case TextIO.inputLine input of
          NONE => String.concat (rev acc) before TextIO.closeIn input
        | SOME line => loop (line :: acc)
  in
    loop [] handle e => (TextIO.closeIn input; raise e)
  end

fun read_lines path = String.tokens (fn c => c = #"\n") (read_text path)

fun write_text path text =
  let val _ = ensure_parent path
      val output = TextIO.openOut path
  in
    TextIO.output(output, text);
    TextIO.closeOut output
  end
  handle e => die ("could not write " ^ path ^ ": " ^ General.exnMessage e)

fun file_hash label path =
  if readable path then HolbuildHash.file_sha1 path
  else die (label ^ " not found: " ^ path)

fun output_hash path = file_hash "generator output" path

fun hash_text text = HolbuildHash.string_sha1 text

fun abs_under root rel = HolbuildProject.abs_under root rel

fun generator_state_dir package =
  Path.concat(HolbuildProject.package_artifact_root package, "generate")

fun generator_stem package generator =
  let
    val key = hash_text (HolbuildProject.package_name package ^ ":" ^ HolbuildProject.generator_name generator)
  in
    Path.concat(generator_state_dir package, key)
  end

fun metadata_path package generator = generator_stem package generator ^ ".key"
fun log_path package generator = generator_stem package generator ^ ".log"

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

fun command_output_path package generator =
  if HolbuildStatus.json_mode () then FS.tmpName () else log_path package generator

fun generator_output_detail output =
  if HolbuildStatus.json_mode () then
    let val text = read_text output handle _ => ""
    in
      if text = "" then ""
      else "\n--- generator output ---\n" ^ text ^ "--- end generator output ---\n"
    end
  else
    "; log: " ^ output

fun cleanup_command_output output =
  if HolbuildStatus.json_mode () then remove_file output else ()

fun dependency_result deps name =
  case List.find (fn (dep_name, _) => dep_name = name) deps of
      SOME (_, result) => result
    | NONE => die ("internal missing generator dependency result: " ^ name)

fun input_line root generator rel =
  let val path = abs_under root rel
  in "input=" ^ rel ^ "@" ^ file_hash ("generator " ^ HolbuildProject.generator_name generator ^ " input") path end

fun command_arg_line arg = "command_arg_sha1=" ^ hash_text arg

fun dependency_line dep_results dep =
  "dep=" ^ dep ^ "@" ^ dependency_result dep_results dep

fun input_key package dep_results generator =
  let
    val root = HolbuildProject.package_root package
    val lines =
      ["holbuild-generate-v1",
       "package=" ^ HolbuildProject.package_name package,
       "name=" ^ HolbuildProject.generator_name generator] @
      map command_arg_line (HolbuildProject.generator_command generator) @
      map (input_line root generator) (HolbuildProject.generator_inputs generator) @
      map (dependency_line dep_results) (HolbuildProject.generator_deps generator)
  in
    hash_text (String.concatWith "\n" lines ^ "\n")
  end

fun output_line root rel =
  let val path = abs_under root rel
  in "output=" ^ rel ^ "@" ^ output_hash path end

fun metadata_text package generator key =
  let
    val root = HolbuildProject.package_root package
    val output_lines = map (output_line root) (HolbuildProject.generator_outputs generator)
  in
    String.concatWith "\n" (["holbuild-generate-result-v1", "input_key=" ^ key] @ output_lines) ^ "\n"
  end

fun line_present line lines = List.exists (fn existing => existing = line) lines

fun output_metadata_matches package rel lines =
  let val expected = output_line (HolbuildProject.package_root package) rel
  in line_present expected lines end
  handle Error _ => false

fun metadata_up_to_date package generator key =
  let val path = metadata_path package generator
  in
    if not (readable path) then false
    else
      let val lines = read_lines path
      in
        line_present "holbuild-generate-result-v1" lines andalso
        line_present ("input_key=" ^ key) lines andalso
        List.all (fn rel => output_metadata_matches package rel lines)
                 (HolbuildProject.generator_outputs generator)
      end
  end
  handle _ => false

fun ensure_output_parents package generator =
  let val root = HolbuildProject.package_root package
  in List.app (fn rel => ensure_parent (abs_under root rel)) (HolbuildProject.generator_outputs generator) end

fun run_command package generator =
  let
    val output = command_output_path package generator
    val _ = ensure_parent output
    val _ = ensure_output_parents package generator
    val status = HolbuildToolchain.run_in_dir_to_file
                   (HolbuildProject.package_root package)
                   (HolbuildProject.generator_command generator)
                   output
  in
    if HolbuildToolchain.success status then
      cleanup_command_output output
    else
      let val detail = generator_output_detail output
          val _ = cleanup_command_output output
      in
        die ("generator " ^ HolbuildProject.generator_name generator ^ " failed" ^ detail)
      end
  end

fun verify_outputs package generator =
  let
    val root = HolbuildProject.package_root package
    fun verify rel =
      let val path = abs_under root rel
      in if readable path then ()
         else die ("generator " ^ HolbuildProject.generator_name generator ^ " did not produce declared output: " ^ rel)
      end
  in
    List.app verify (HolbuildProject.generator_outputs generator)
  end

fun run_one package dep_results generator =
  let
    val key = input_key package dep_results generator
    val _ =
      if metadata_up_to_date package generator key then ()
      else (run_command package generator;
            verify_outputs package generator;
            write_text (metadata_path package generator) (metadata_text package generator key))
    val result = hash_text (read_text (metadata_path package generator))
  in
    (HolbuildProject.generator_name generator, result)
  end

fun duplicate_name names =
  case names of
      [] => NONE
    | name :: rest => if member name rest then SOME name else duplicate_name rest

fun duplicate_output generators =
  let
    fun outputs generator = map (fn output => (output, HolbuildProject.generator_name generator))
                                (HolbuildProject.generator_outputs generator)
    fun loop [] = NONE
      | loop ((output, owner) :: rest) =
          case List.find (fn (other, _) => other = output) rest of
              SOME (_, other_owner) => SOME (output, owner, other_owner)
            | NONE => loop rest
  in
    loop (List.concat (map outputs generators))
  end

fun generator_named generators name =
  List.find (fn generator => HolbuildProject.generator_name generator = name) generators

fun validate_generators generators =
  let
    val names = map HolbuildProject.generator_name generators
    val _ =
      case duplicate_name names of
          NONE => ()
        | SOME name => die ("duplicate generator name: " ^ name)
    val _ =
      case duplicate_output generators of
          NONE => ()
        | SOME (output, first, second) =>
            die ("generator output " ^ output ^ " is produced by both " ^ first ^ " and " ^ second)
    fun validate_dep generator dep =
      case generator_named generators dep of
          SOME _ => ()
        | NONE => die ("generator " ^ HolbuildProject.generator_name generator ^ " depends on unknown generator " ^ dep)
    val _ = List.app (fn generator => List.app (validate_dep generator) (HolbuildProject.generator_deps generator)) generators
  in
    ()
  end

fun topo_sort generators =
  let
    val _ = validate_generators generators
    fun ready done generator = List.all (fn dep => member dep done) (HolbuildProject.generator_deps generator)
    fun partition_ready done remaining =
      List.partition (ready done) remaining
    fun loop done ordered remaining =
      case remaining of
          [] => rev ordered
        | _ =>
            let val (ready_now, blocked) = partition_ready done remaining
            in
              if null ready_now then die "generator dependency cycle"
              else loop (map HolbuildProject.generator_name ready_now @ done)
                        (rev ready_now @ ordered)
                        blocked
            end
  in
    loop [] [] generators
  end

fun run_package package =
  let val generators = HolbuildProject.package_generators package
  in
    if null generators then ()
    else
      let
        val ordered = topo_sort generators
        fun run (generator, dep_results) = run_one package dep_results generator :: dep_results
      in
        ignore (List.foldl run [] ordered)
      end
  end

end
