def unwrap_bash_timeout:
  if (.tool_input.command? | type) == "string" then
    .tool_input.command |= (
      . as $c
      | ([capture("^bash '(?:[^']*/)?hooks/bash-timeout-run\\.sh' [0-9]+ (?:fg|bg) [A-Za-z0-9_-]+ '(?<q>(?:[^']|'\\\\'')*)'$"; "s")] | first) as $m
      | if $m == null then $c else $m.q | gsub("'\\\\''"; "'") end)
  else . end;
