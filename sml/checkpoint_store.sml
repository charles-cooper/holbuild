structure HolbuildCheckpointStore =
struct

structure FS = OS.FileSys

fun ok_path path = path ^ ".ok"

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

fun file_exists path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun rename_file old new = FS.rename {old = old, new = new}

fun read_text path =
  let
    val input = TextIO.openIn path
    fun close () = TextIO.closeIn input handle _ => ()
    fun loop acc =
      case TextIO.inputLine input of
          NONE => String.concat (rev acc)
        | SOME line => loop (line :: acc)
  in
    (loop [] before close ()) handle e => (close (); raise e)
  end

fun current_metadata path = SOME (read_text path) handle IO.Io _ => NONE

fun remove_checkpoint path =
  (remove_file (ok_path path ^ ".tmp");
   remove_file (path ^ ".tmp");
   remove_file (ok_path path ^ ".bak");
   remove_file (path ^ ".bak");
   remove_file (ok_path path);
   remove_file (path ^ ".meta");
   remove_file (path ^ ".prefix");
   remove_file path)

fun ok_v1 () = "holbuild-checkpoint-ok-v1\n"

fun ok_text kind fields =
  String.concatWith "\n" (["holbuild-checkpoint-ok-v2", "kind=" ^ kind] @
                          map (fn (key, value) => key ^ "=" ^ value) fields) ^ "\n"

fun metadata_lines text = String.tokens (fn c => c = #"\n") text

fun first_some f values =
  case values of
      [] => NONE
    | x :: xs =>
        case f x of
            SOME y => SOME y
          | NONE => first_some f xs

fun metadata_value key lines =
  let val prefix = key ^ "="
  in
    first_some (fn line =>
                  if String.isPrefix prefix line then
                    SOME (String.extract(line, size prefix, NONE))
                  else NONE)
               lines
  end

fun save_backup_path path = path ^ ".bak"
fun ok_backup_path path = ok_path path ^ ".bak"

fun discard_checkpoint_backup path =
  (remove_file (save_backup_path path); remove_file (ok_backup_path path))

fun restore_backup_pair warn message path =
  let
    val ok = ok_path path
    val save_bak = save_backup_path path
    val ok_bak = ok_backup_path path
    val has_save_bak = file_exists save_bak
  in
    warn (message ^ path);
    if has_save_bak then (remove_file path; rename_file save_bak path) else remove_file path;
    remove_file ok;
    rename_file ok_bak ok
  end

(* Checkpoint saves publish .ok last. If an interrupt lands after the old
   checkpoint was moved to .bak but before the new .ok was published, validation
   must prefer the last complete checkpoint over a partial replacement. *)
fun restore_checkpoint_backup warn path =
  let
    val ok = ok_path path
    val ok_bak = ok_backup_path path
    val should_restore =
      file_exists ok_bak andalso (not (file_exists ok) orelse not (file_exists path))
  in
    if should_restore then
      restore_backup_pair warn "checkpoint save was interrupted; restoring previous checkpoint: " path
    else ()
  end
  handle OS.SysErr _ => ()

fun remove_incomplete_residue warn path =
  if file_exists (ok_path path) andalso not (file_exists path) then
    (warn ("checkpoint metadata exists without checkpoint file; discarding metadata: " ^ path);
     remove_file (ok_path path);
     remove_file (path ^ ".meta");
     remove_file (path ^ ".prefix"))
  else ()

fun metadata_matches_fields fields text =
  let val lines = metadata_lines text
  in
    List.exists (fn line => line = "holbuild-checkpoint-ok-v2") lines andalso
    List.all (fn (key, value) => metadata_value key lines = SOME value) fields
  end

fun checkpoint_matches warn path metadata_matches =
  let
    fun current_matches () =
      file_exists path andalso
      (case current_metadata (ok_path path) of
           SOME text => metadata_matches text
         | NONE => false)
  in
    restore_checkpoint_backup warn path;
    remove_incomplete_residue warn path;
    if current_matches () then (discard_checkpoint_backup path; true)
    else if file_exists (ok_backup_path path) then
      ((restore_backup_pair warn "checkpoint metadata publish was interrupted; restoring previous checkpoint: " path;
        remove_incomplete_residue warn path;
        current_matches ())
       handle OS.SysErr _ => false)
    else false
  end

fun ok_text_matches warn path expected_text =
  checkpoint_matches warn path (fn text => text = expected_text)

fun ok_matches warn path fields =
  checkpoint_matches warn path (metadata_matches_fields fields)

end
