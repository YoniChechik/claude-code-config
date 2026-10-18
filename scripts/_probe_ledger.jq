def plain_tools: ["Bash", "Read", "Grep", "Glob", "WebFetch", "WebSearch", "BashOutput", "TaskOutput"];

def recorded: . as $t | (plain_tools | index($t)) != null or startswith("mcp__");

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

def masked: gsub("'[^']*'"; "''") | gsub("\"[^\"$`\\\\]*\""; "\"\"");

def redirects_removed: gsub("[0-9]*>&[0-9]+"; "") | gsub("(&|[0-9]*)>>?\\s*/dev/null"; "");

def first_bins: ["ls", "cat", "head", "tail", "wc", "rg", "grep", "jq", "yq", "stat", "file", "find", "test", "dig", "nslookup", "ps", "lsof", "date", "which", "gh", "git", "curl"];

def filter_bins: ["head", "tail", "wc", "jq", "grep", "rg", "sort", "uniq", "cut", "tr"];

def git_ro: ["status", "log", "show", "diff", "rev-parse", "merge-base", "ls-files", "blame", "describe"];

def gh_ro: ["pr view", "pr checks", "pr list", "pr diff", "run view", "run list", "issue view", "repo view"];

def any_word($w; $re): any($w[]; test($re));

def flag_value_not_get($w; $names):
  any(range(0; $w | length) as $i | $w[$i] | . as $x | select(($names | index($x)) != null) | $i; ($w[. + 1] // "") | ascii_upcase != "GET");

def stage_ok($first):
  (words | strip_prefix) as $w
  | (($w[0] // "") | basename) as $b
  | if ($w | length) == 0 then false
    elif $first | not then
      (filter_bins | index($b)) != null
      and ($b != "sort" or (any_word($w; "^(-o|--output)") | not))
      and ($b != "uniq" or ([$w[1:][] | select(is_flag | not)] | length) < 2)
      and ($b != "rg" or (any_word($w; "^--pre") | not))
    elif (first_bins | index($b)) == null then false
    elif $b == "find" then any_word($w; "^-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)$") | not
    elif $b == "rg" then any_word($w; "^--pre") | not
    elif $b == "yq" then any_word($w; "^(-i|--inplace)") | not
    elif $b == "date" then any_word($w; "^(-s|--set)") | not
    elif $b == "git" then
      (any_word($w[1:]; "^(-C|-c|--git-dir|--work-tree|--exec-path|--output)") | not)
      and ((git_ro | index([$w[1:][] | select(is_flag | not)][0] // "")) != null)
    elif $b == "gh" then
      ([$w[1:][] | select(is_flag | not)]) as $pos
      | ((gh_ro | index(($pos[0:2] | join(" ")))) != null)
        or ($pos[0] == "api"
          and (any_word($w; "^(-f|-F|--field|--raw-field|--input)") | not)
          and (flag_value_not_get($w; ["-X", "--method"]) | not)
          and (any_word($w; "^(-X.+|--method=.+)$") and (any_word($w; "^(-XGET|--method=GET)$") | not) | not))
    elif $b == "curl" then
      (any_word($w; "^-[A-Za-z]*[oOTdFK][A-Za-z]*$") | not)
      and (any_word($w; "^--(data|output|upload-file|form|remote-name|config)") | not)
      and (flag_value_not_get($w; ["-X", "--request"]) | not)
      and (any_word($w; "^(-X.+|--request=.+)$") and (any_word($w; "^(-XGET|--request=GET)$") | not) | not)
    else true end;

def bash_ro($raw):
  if ($raw | test("\\$\\(|`|<\\(|>\\(|\\n")) then false
  else
    ($raw | masked | redirects_removed) as $m
    | if ($m | test("[;&<>]")) then false
      else
        ($m | split("|")) as $stages
        | ($stages | all(.[]; (words | length) > 0))
          and ($stages[0] | stage_ok(true))
          and all($stages[1:][]; stage_ok(false))
      end
  end;

def bash_cmd($raw):
  ($raw | words | strip_prefix) as $w
  | ([$w[] | select(is_flag | not)] + ([$w[] | select(is_flag)] | sort)) | join(" ");

def bash_bin($raw): (($raw | words | strip_prefix)[0] // "") | basename;

def mcp_tool: split("__") | last;

def primary($t; $i):
  if $t == "Read" then $i.file_path // ""
  elif $t == "Grep" or $t == "Glob" then [($i.pattern // ""), ($i.path // "")] | map(select(length > 0)) | join(" ")
  elif $t == "WebFetch" then $i.url // ""
  elif $t == "WebSearch" then $i.query // ""
  elif $t == "BashOutput" then $i.bash_id // $i.shell_id // ""
  elif $t == "TaskOutput" then $i.task_id // $i.id // ""
  else ($i | tojson | .[0:200]) end;

def out_text:
  if .hook_event_name == "PostToolUseFailure" then (.error // "") | tostring
  elif .tool_name == "Bash" then "\(.tool_response.stdout // "")\n\(.tool_response.stderr // "")"
  elif .tool_name == "Read" then (.tool_response.file.content // (.tool_response | tojson)) | tostring
  elif (.tool_response | type) == "string" then .tool_response
  elif (.tool_response | type) == "array" then [.tool_response[] | if type == "object" then (.text // tojson) else tostring end] | join("\n")
  else .tool_response | tojson end;

def redact:
  gsub("(?i)authorization\\s*[=:]\\s*((bearer|basic|token)\\s+)?\\S+"; "<redacted>")
  | gsub("(?i)bearer\\s+\\S+"; "<redacted>")
  | gsub("(?i)(token|secret|password|passwd|api[_-]?key)\\s*[=:]\\s*\\S+"; "<redacted>")
  | gsub("(ghp_|gh[ousr]_|github_pat_)\\S+"; "<redacted>")
  | gsub("sk-[A-Za-z0-9_-]+"; "<redacted>")
  | gsub("AKIA[0-9A-Z]{16}"; "<redacted>")
  | gsub("eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"; "<redacted>");

def excerpt:
  (if length > 8192 then .[0:4096] + " " + .[-4096:] else . end)
  | collapse | redact
  | if length > 2048 then {out_excerpt: (.[0:512] + " … " + .[-1536:]), out_truncated: true} else {out_excerpt: .} end;

def exit_code:
  if .hook_event_name != "PostToolUseFailure" then 0
  elif .is_interrupt == true then -1
  else ((([(.error // "") | tostring | capture("^Exit code (?<n>[0-9]+)")] | first | .n) // "1") | tonumber) end;

def linear_fact:
  if (.tool_name | test("^mcp__.*linear.*__get_issue$"; "i")) and .hook_event_name == "PostToolUse" then
    (out_text) as $t
    | (($t | fromjson?) // null) as $j
    | if ($j | type) == "object" and ($j.id | type) == "string" and ($j.status | type) == "string" then {fact: {linear: $j.id, state: $j.status}}
      else
        ([$t | capture("\"id\"\\s*:\\s*\"(?<id>[A-Z][A-Z0-9]+-[0-9]+)\"")] | first) as $id
        | ([$t | capture("\"status\"\\s*:\\s*\"(?<s>[^\"]+)\"")] | first) as $st
        | if $id != null and $st != null then {fact: {linear: $id.id, state: $st.s}} else {} end
      end
  else {} end;

def record:
  .tool_name as $t
  | (.tool_input // {}) as $i
  | (if $t == "Bash" then ($i.command // "" | tostring) else "" end) as $raw
  | {
      kind: "probe",
      tool: $t,
      bin: (if $t == "Bash" then bash_bin($raw) else $t end),
      cmd: (if $t == "Bash" then bash_cmd($raw) else ("\($t) \(primary($t; $i))" | collapse) end),
      exit: exit_code,
      ro: (if $t == "Bash" then bash_ro($raw)
        elif ($t | startswith("mcp__")) then ($t | mcp_tool | test("^(get|list|read|search|query|find|view|fetch|describe)"))
        else true end),
      tool_use_id: (.tool_use_id // ""),
      ts_ms: $ts_ms
    }
  + (out_text | excerpt)
  + (if .is_interrupt == true then {interrupt: true} else {} end)
  + (if (.prompt_id // "") != "" then {prompt_id: .prompt_id} else {} end)
  + (if (.agent_id // "") != "" then {agent_id: .agent_id} else {} end)
  + linear_fact;

if type != "object" then empty
elif $op == "hash" then out_text
elif ((.hook_event_name // "") | test("^PostToolUse(Failure)?$")) and ((.tool_name // "") | recorded) and ((.session_id // "") | tostring) != "" then
  (.session_id | tostring), "\u0000", (record | tojson), "\u0000"
else empty end
