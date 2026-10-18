def collapse: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");

def words: collapse | split(" ") | map(select(length > 0));

def strip_prefix:
  if length == 0 then .
  elif (.[0] | test("^[A-Za-z_][A-Za-z0-9_]*=")) then .[1:] | strip_prefix
  elif .[0] == "sudo" or .[0] == "command" or .[0] == "env" then .[1:] | strip_prefix
  elif .[0] == "timeout" and ((.[1] // "") | test("^[0-9]")) then .[2:] | strip_prefix
  elif .[0] == "rtk" and .[1] == "proxy" then .[2:] | strip_prefix
  elif .[0] == "rtk" then .[1:] | strip_prefix
  else . end;

def is_flag: test("^-");

def basename: sub("^.*/"; "");

def bash_cmd($raw):
  ($raw | words | strip_prefix) as $w
  | ([$w[] | select(is_flag | not)] + ([$w[] | select(is_flag)] | sort)) | join(" ");

def bash_bin($raw): (($raw | words | strip_prefix)[0] // "") | basename;
