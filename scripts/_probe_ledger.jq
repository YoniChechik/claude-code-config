include "_probe_common";
include "_hook_input";

def mcp_tool: split("__") | last;

def plain_tools: ["Bash", "Read", "Grep", "Glob", "WebFetch", "WebSearch", "BashOutput", "TaskOutput"];

def recorded: . as $t | (plain_tools | index($t)) != null or startswith("mcp__");

def masked: gsub("'[^']*'"; "''") | gsub("\"[^\"$`\\\\]*\""; "\"\"");

def redirects_removed: gsub("[0-9]*>&[0-9]+"; "") | gsub("(&|[0-9]*)>>?\\s*/dev/null"; "");

def first_bins: ["ls", "cat", "head", "tail", "wc", "rg", "grep", "jq", "yq", "stat", "file", "find", "test", "dig", "nslookup", "ps", "lsof", "date", "which", "gh", "git", "curl", "tar", "unzip", "zipinfo", "strings", "du", "df", "realpath", "readlink", "type", "nl", "column", "basename", "dirname", "pwd", "xxd", "sed", "cut", "tr", "sort", "uniq"];

def filter_bins: ["head", "tail", "wc", "jq", "grep", "rg", "sort", "uniq", "cut", "tr", "sed", "nl", "column", "strings", "xxd"];

def git_ro: ["status", "log", "show", "diff", "rev-parse", "merge-base", "ls-files", "blame", "describe"];

def gh_ro: ["pr view", "pr checks", "pr list", "pr diff", "run view", "run list", "issue view", "repo view"];

def tar_write_long: "^--(create|extract|get|append|update|catenate|concatenate|delete|to-command|use-compress-program|checkpoint-action|info-script|new-volume-script|rsh-command|rmt-command|to-stdout|overwrite|unlink|remove-files|files-from)";

def xxd_value_opts: ["-c", "-cols", "-g", "-groupsize", "-l", "-len", "-s", "-seek", "-o", "-offset", "-n", "-name"];

def any_word($w; $re): any($w[]; test($re));

def flag_value_not_get($w; $names):
  any(range(0; $w | length) as $i | $w[$i] | . as $x | select(($names | index($x)) != null) | $i; ($w[. + 1] // "") | ascii_upcase != "GET");

def tar_letters($w):
  ((if (($w[1] // "") | test("^[A-Za-z]+$")) then [$w[1]] else [] end) + [$w[1:][] | select(test("^-[A-Za-z]+$")) | ltrimstr("-")])
  | join("");

def tar_reason($w):
  tar_letters($w) as $l
  | if ($l | test("t")) or any_word($w; "^--list$") | not then "`tar`: not list mode (`t` or `--list`)"
    elif $l | test("[cxruAIF]") then "`tar`: a create, extract or program mode flag"
    elif any_word($w; tar_write_long) then "`tar`: a write or program option"
    elif any_word($w[1:]; ":") then "`tar`: a `:` archive name runs a remote shell"
    else null end;

def xxd_positionals($w):
  reduce $w[1:][] as $x ({skip: false, n: 0};
    if .skip then .skip = false
    elif (xxd_value_opts | index($x)) != null then .skip = true
    elif ($x | is_flag) then .
    else .n += 1 end)
  | .n;

def xxd_reason($w):
  if any_word($w[1:]; "^-r") then "`xxd`: `-r` writes binary"
  elif xxd_positionals($w) > 1 then "`xxd`: a second file argument is an output file"
  else null end;

def sed_reason($w):
  [$w[1:][] | select(is_flag)] as $f
  | [$w[1:][] | select(is_flag | not)] as $p
  | if ($f | length) == 0 or any($f[]; . != "-n" and . != "--quiet" and . != "--silent") then "`sed`: only `sed -n` with a `Np` or `N,Mp` script"
    elif (($p[0] // "") | test("^[0-9]+(,[0-9]+)?p$") | not) then "`sed`: only `sed -n` with a `Np` or `N,Mp` script"
    else null end;

def stage_words: words | map(gsub("['\"\\\\]"; "")) | strip_prefix;

def stage_reason($first):
  stage_words as $w
  | (($w[0] // "") | basename) as $b
  | if ($w | length) == 0 then "an empty pipe stage"
    elif $first | not then
      if (filter_bins | index($b)) == null then "`\($b)`: not a read-only pipe filter"
      elif $b == "sort" and any_word($w; "^(-o|--output)") then "`sort`: `-o` writes a file"
      elif $b == "uniq" and ([$w[1:][] | select(is_flag | not)] | length) >= 2 then "`uniq`: a second file argument is an output file"
      elif $b == "rg" and any_word($w; "^--pre") then "`rg`: `--pre` runs a program"
      elif $b == "sed" then sed_reason($w)
      elif $b == "xxd" then xxd_reason($w)
      else null end
    elif (first_bins | index($b)) == null then "`\($b)`: not in read-only allowlist"
    elif $b == "find" then (if any_word($w; "^-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)$") then "`find`: an action that runs or writes" else null end)
    elif $b == "rg" then (if any_word($w; "^--pre") then "`rg`: `--pre` runs a program" else null end)
    elif $b == "yq" then (if any_word($w; "^(-i|--inplace)") then "`yq`: `-i` writes in place" else null end)
    elif $b == "date" then (if any_word($w; "^(-s|--set)") then "`date`: `-s` sets the clock" else null end)
    elif $b == "sort" then (if any_word($w; "^(-o|--output)") then "`sort`: `-o` writes a file" else null end)
    elif $b == "uniq" then (if ([$w[1:][] | select(is_flag | not)] | length) >= 2 then "`uniq`: a second file argument is an output file" else null end)
    elif $b == "tar" then tar_reason($w)
    elif $b == "unzip" then (if (($w[1] // "") | test("^-[lZ]")) then null else "`unzip`: only `unzip -l` or `unzip -Z`" end)
    elif $b == "xxd" then xxd_reason($w)
    elif $b == "sed" then sed_reason($w)
    elif $b == "git" then
      if any_word($w[1:]; "^(-C|-c|--git-dir|--work-tree|--exec-path|--output)") then "`git`: a global option that changes the repo or config"
      elif (git_ro | index([$w[1:][] | select(is_flag | not)][0] // "")) == null then "`git \([$w[1:][] | select(is_flag | not)][0] // "")`: not a read-only git subcommand"
      else null end
    elif $b == "gh" then
      ([$w[1:][] | select(is_flag | not)]) as $pos
      | if (gh_ro | index(($pos[0:2] | join(" ")))) != null then null
        elif $pos[0] == "api"
          and (any_word($w; "^(-f|-F|--field|--raw-field|--input)") | not)
          and (flag_value_not_get($w; ["-X", "--method"]) | not)
          and (any_word($w; "^(-X.+|--method=.+)$") and (any_word($w; "^(-XGET|--method=GET)$") | not) | not) then null
        else "`gh \($pos[0:2] | join(" "))`: not a read-only gh command" end
    elif $b == "curl" then
      if (any_word($w; "^-[A-Za-z]*[oOTdFK][A-Za-z]*$"))
        or (any_word($w; "^--(data|output|upload-file|form|remote-name|config)"))
        or (flag_value_not_get($w; ["-X", "--request"]))
        or (any_word($w; "^(-X.+|--request=.+)$") and (any_word($w; "^(-XGET|--request=GET)$") | not)) then "`curl`: a write, upload or non-GET option"
      else null end
    else null end;

def bash_ro_reason($raw):
  if ($raw | test("\\$\\(|`|<\\(|>\\(")) then "contains command substitution"
  elif ($raw | test("\\n")) then "contains a newline"
  else
    ($raw | masked | redirects_removed) as $m
    | if ($m | test(";")) then "contains `;`"
      elif ($m | test("&")) then "contains `&`"
      elif ($m | test("\\|\\|")) then "contains `||`"
      elif ($m | test("[<>]")) then "contains a redirect"
      else
        ($raw | stages) as $s
        | ([range(0; $s | length) as $i | $s[$i] | stage_reason($i == 0) | select(. != null)] | first) // null
      end
  end;

def mcp_reason($t): if ($t | mcp_tool | test("^(get|list|read|search|query|find|view|fetch|describe)")) then null else "`\($t | mcp_tool)`: not a read verb" end;

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
  | (if $t == "Bash" then bash_ro_reason($raw) elif ($t | startswith("mcp__")) then mcp_reason($t) else null end) as $reason
  | {
      kind: "probe",
      tool: $t,
      bin: (if $t == "Bash" then bash_bin($raw) else $t end),
      cmd: (if $t == "Bash" then bash_cmd($raw) else ("\($t) \(primary($t; $i))" | collapse) end),
      exit: exit_code,
      ro: ($reason == null),
      tool_use_id: (.tool_use_id // ""),
      ts_ms: $ts_ms
    }
  + (if $reason != null then {ro_reason: $reason} else {} end)
  + (out_text | excerpt)
  + (if .is_interrupt == true then {interrupt: true} else {} end)
  + (if (.prompt_id // "") != "" then {prompt_id: .prompt_id} else {} end)
  + (if (.agent_id // "") != "" then {agent_id: .agent_id} else {} end)
  + linear_fact;

if type != "object" then empty
elif $op == "hash" then out_text
elif ((.hook_event_name // "") | test("^PostToolUse(Failure)?$")) and ((.tool_name // "") | recorded) and ((.session_id // "") | tostring) != "" then
  (.session_id | tostring), "\u0000", (unwrap_bash_timeout | record | tojson), "\u0000"
else empty end
