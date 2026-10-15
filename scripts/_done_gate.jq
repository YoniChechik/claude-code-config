def categories: ["credential", "captcha", "payment", "physical", "destructive-prod-data", "spending-money", "irreversible-external-send", "paradigm-shift"];

def status_kinds: ["COMPLETE", "WAITING", "BLOCKED", "FAILURE", "ANSWER"];

def contract: "End the final message with exactly one STATUS line as its last line: `STATUS: COMPLETE <evidence>`, `STATUS: WAITING <task-id> <what it waits for>`, `STATUS: BLOCKED <category>: <one-line ask>` (categories: \(categories | join(", "))), `STATUS: FAILURE <what>: <command and observed output>`, or `STATUS: ANSWER` for a pure answer.";

def parsed_lines: $L | split("\n") | map(select(length > 0) | (fromjson? // null));

def records: parsed_lines | map(select(type == "object")
  | if (.ts | type) == "string" then .ts = ((.ts | fromdateiso8601?) // 0) else . end);

def bad_lines: parsed_lines | map(select(type != "object")) | length;

def clean_line: gsub("^[\\s>*_`]+"; "") | gsub("[\\s*_`]+$"; "");

def parse_status($msg):
  ($msg | split("\n") | map(clean_line) | map(select(length > 0)) | last // "") as $last
  | ([$last | capture("^STATUS:\\s*(?<kind>[A-Za-z]+)(?<rest>.*)$"; "i")] | first) as $c
  | if $c == null then {kind: null, rest: "", line: $last}
    else {kind: ($c.kind | ascii_upcase), rest: ($c.rest | gsub("^\\s+"; "") | gsub("\\s+$"; "")), line: $last}
    end;

def heading: test("^\\s*#{1,6}\\s+\\S");

def section_items($msg; $name):
  reduce ($msg | split("\n"))[] as $l ({on: false, body: []};
    if ($l | heading) then .on = ($l | test("^\\s*#{1,6}\\s+" + $name + "\\b"; "i"))
    elif .on and (($l | clean_line | test("^STATUS:"; "i")) | not) then .body += [$l]
    else . end)
  | .body
  | map(gsub("^[\\s*+•-]+"; "") | gsub("^[0-9]+[.)]\\s*"; "") | gsub("\\s+$"; ""))
  | map(select(length > 0));

def section_open($msg; $name):
  section_items($msg; $name) as $b
  | ($b | length) > 0 and ((($b | length) == 1 and ($b[0] | test("^(none|nothing|n/?a)\\.?$"; "i"))) | not);

def tokens: [scan("[A-Za-z0-9._/+@-]+") | sub("[.]+$"; "")];

def mentions($text; $word): ($word | tostring) as $w | ($w != "") and (($text | tokens) | index($w) != null);

def ident: (if ((.pr // "") | tostring) != "" then .pr else (.target // "") end) | tostring;

def same($a; $b): (($a.repo // "") == ($b.repo // "")) and (($a | ident) == ($b | ident));

def repo_flag: if (.repo // "") != "" then " --repo " + .repo else "" end;

def pr_label: if (.repo // "") != "" then "\(.repo)#\(ident)" else "PR \(ident)" end;

def names_pr($what; $m):
  ($m | ident) as $n
  | ($what | [scan("[^\\s,;]+") | gsub("^[(\\[]+|[).,\\]]+$"; "")]) as $words
  | any($words[]; . as $w
      | $w == $n or $w == "#" + $n
      or (($m.repo // "") != "" and $w == $m.repo + "#" + $n)
      or (($m.repo // "") != "" and $w == "https://github.com/" + $m.repo + "/pull/" + $n));

def verify_ok:
  . as $v
  | ($v.result == "n/a")
    or ($v.result == "pass"
      and any(($v.targets // [])[]; (.skipped // false) | not)
      and all(($v.targets // [])[]; . as $t
        | ($t.skipped // false)
        or ((($t.observed_sha // "") | length) >= 7
        and ($t.contains_merge == true or (($v.merge_sha // "") | startswith($t.observed_sha)))
        and all(($t.probes // [])[]; .exit == 0 and .matched == true))));

def merges($R): [$R[] | select(.kind == "merge")] | group_by([(.repo // ""), ident]) | map(max_by(.ts // 0));

def verifies($R; $m): [$R[] | select(.kind == "verify" and same(.; $m) and ((.ts // 0) >= ($m.ts // 0)))];

def acked($R; $m): any($R[]; .kind == "ack" and same(.; $m) and ((.ts // 0) >= ($m.ts // 0)));

def pending($R):
  [merges($R)[] as $m
    | select((any(verifies($R; $m)[]; verify_ok) | not) and (acked($R; $m) | not))
    | $m + {last_verify: (verifies($R; $m) | max_by(.ts // 0))}];

def prompt_start:
  if (($st.prompt.synthetic // false) | not) and ($st.prompt.id // "") != "" and ($hookin[0].prompt_id // "") != "" and $st.prompt.id != $hookin[0].prompt_id then null
  else ($st.prompt.ts // null) end;

def in_prompt:
  . as $r
  | ((($hookin[0].prompt_id // "") != "" and ($r.prompt_id // "") == $hookin[0].prompt_id)
    or (prompt_start != null and (($r.ts // 0) >= prompt_start)));

def live: . as $s | (["running", "pending", "in_progress", "starting"] | index($s)) != null;

def arr: if type == "array" then . else [] end;

def tasks: ($hookin[0].background_tasks | arr);

def find_task($id): [tasks[] | select((.id | tostring) == $id)] | first;

def find_cron($id): [($hookin[0].session_crons | arr)[] | select((.id | tostring) == $id)] | first;

def live_waiter($m):
  any(tasks[]; ((.status // "") | live) and ((.command // "") | test("gh_monitor\\.sh\\s+wait"))
    and (mentions(.command // ""; $m.target) or mentions(.command // ""; $m | ident)));

def pending_line:
  "\(pr_label) (merged \(.ts // 0 | todate)) has no passing staging verify result"
  + (if .last_verify then " (last result: \(.last_verify.result)\(if .last_verify.reason then ", " + .last_verify.reason else "" end))" else "" end);

def g1($s; $msg; $R):
  if $s.kind == null then
    [{rule: "G1", msg: "G1: the last line is not a STATUS line (it was: \"\($s.line | .[0:160])\"). \(contract) Do not end on a question or an offer: if the next step is observable or pre-approved (merge on green, push, PR, staging deploy, CI fixes, read-only checks, local cleanup), do it now."}]
  elif (status_kinds | index($s.kind)) == null then
    [{rule: "G1", msg: "G1: `STATUS: \($s.kind)` is not a valid status. \(contract)"}]
  elif $s.kind == "COMPLETE" then
    (if ($s.rest | length) == 0 then [{rule: "G1", msg: "G1: `STATUS: COMPLETE` needs an evidence pointer (command and observed output, a URL, or a path)."}] else [] end)
    + (if section_open($msg; "TODO") then [{rule: "G1", msg: "G1: `STATUS: COMPLETE` with a non-empty `# TODO` section. Do the TODO items now, or end with WAITING, BLOCKED or FAILURE that names the open item."}] else [] end)
    + (if section_open($msg; "Needs human") then [{rule: "G1", msg: "G1: `STATUS: COMPLETE` with a non-empty `# Needs human` section. A real human-only step ends with `STATUS: BLOCKED <category>: <ask>`."}] else [] end)
  elif $s.kind == "BLOCKED" then
    ([$s.rest | capture("^(?<cat>[A-Za-z-]+)\\s*:\\s*(?<ask>\\S.*)$")] | first) as $b
    | if $b == null then
        [{rule: "G1", msg: "G1: write BLOCKED as `STATUS: BLOCKED <category>: <one-line ask>` with a category from: \(categories | join(", "))."}]
      elif (categories | index($b.cat | ascii_downcase)) == null then
        [{rule: "G1", msg: "G1: `\($b.cat)` is not a human-only category. Allowed: \(categories | join(", ")). Merging on green, pushing, PRs, staging deploys, CI fixes, read-only checks and local cleanup are pre-approved: do the step now and report. If it truly cannot be done, end with `STATUS: FAILURE <what>: <command and observed output>`."}]
      else [] end
  elif $s.kind == "FAILURE" then
    if ($s.rest | test("^[^:]*\\S[^:]*:\\s*\\S")) then []
    else [{rule: "G1", msg: "G1: write FAILURE as `STATUS: FAILURE <what>: <command and observed output, or a path>`. The evidence part after the colon is required."}] end
  elif $s.kind == "ANSWER" then
    if any($R[]; (.kind == "merge" or .kind == "push") and in_prompt) then
      [{rule: "G1", msg: "G1: `STATUS: ANSWER` is only for a pure answer, and this prompt merged or pushed. End with COMPLETE (predicate met), WAITING (live watcher) or FAILURE."}]
    else [] end
  else [] end;

def g2($s; $R):
  reduce pending($R)[] as $m ({v: [], acks: []};
    (([$s.rest | capture("^(?<w>.*?):(?<e>\\s.*|$)")] | first) // {w: "", e: ""}) as $f
    | $f.w as $what
    | $f.e as $evidence
    | if $s.kind == "FAILURE" and (names_pr($what; $m)
        or (($what | gsub("\\s"; "")) == "no-verify-config" and names_pr($evidence; $m))) then
      .acks += [{kind: "ack", repo: $m.repo, target: $m.target, pr: ($m | ident), reason: $s.rest}]
    elif ($s.kind != "COMPLETE" and $s.kind != "ANSWER") and live_waiter($m) then .
    else
      .v += [{rule: "G2", key: ($m | pr_label), msg: (
        if $m.last_verify == null then
          "G2: \($m | pr_label) is merged and has no staging verify result yet. Run \(if ($m.wait_cmd // "") != "" then "`" + $m.wait_cmd + "`" else "`bash ~/.claude/scripts/gh_monitor.sh wait \($m.target)\($m | repo_flag)`" end) with `run_in_background: true`, then end with `STATUS: WAITING <task-id> deploy \($m | ident)`, or report its verdict if it already finished."
        elif $m.last_verify.result == "no-config" then
          "G2: \($m | pr_label) cannot be verified on staging: \($m.last_verify.reason // "no verify config"). Create the config with `/create-verification-skill` (it applies from the next merge). End this turn with `STATUS: FAILURE no-verify-config: \($m | pr_label)`."
        elif $m.last_verify.result == "pass" then
          "G2: the staging verify record for \($m | pr_label) does not prove the merge: the observed SHA must contain \($m.last_verify.merge_sha // "the merge commit") and every probe must pass. Re-run the verification or end with `STATUS: FAILURE \($m | pr_label): <observed output>`."
        else
          "G2: staging verify for \($m | pr_label) returned \($m.last_verify.result): \($m.last_verify.reason // "no reason recorded"). Fix the cause and ship the fix, or end with `STATUS: FAILURE \($m | pr_label): <command and observed output>`."
        end)}]
    end);

def g3($s):
  if $s.kind != "WAITING" then []
  else
    ($s.rest | split(" ") | map(select(length > 0))) as $w
    | ($w[0] // "") as $tid
    | if ($w | length) < 2 then
        [{rule: "G3", msg: "G3: write WAITING as `STATUS: WAITING <task-id> <what it waits for>`, with the id of a running background task."}]
      else
        find_task($tid) as $t
        | find_cron($tid) as $c
        | if $c != null then []
          elif $t == null then
            [{rule: "G3", msg: "G3: no running background task or cron has id `\($tid)`, so nothing is watching. Diagnose and relaunch the watcher (one background Bash command whose loop polls inside the shell, description tagged `[wait:<tag>]`), then end with `STATUS: WAITING <task-id> <tag>`. Waiting on the user is not a status: do the step or end with FAILURE."}]
          elif (($t.status // "") | live | not) then
            [{rule: "G3", msg: "G3: task `\($tid)` is `\($t.status // "unknown")`, not running. Read its output, diagnose and relaunch the watcher, or report its result."}]
          elif ($t.type // "shell") != "shell" then []
          elif (($t.command // "") | test("gh_monitor\\.sh")) then []
          else
            ([($t.description // "") | capture("\\[wait:(?<tag>[^\\]\\s]+)\\]")] | first) as $tag
            | if $tag == null then
                [{rule: "G3", msg: "G3: task `\($tid)` is not a watcher: its description has no `[wait:<tag>]`. A `tail -f` or a bare `sleep` does not wait for anything. Launch a background poll loop that exits on the awaited condition, with `[wait:<tag>]` in its description, and end with `STATUS: WAITING <task-id> <tag>`."}]
              elif (mentions($s.rest; $tag.tag) | not) then
                [{rule: "G3", msg: "G3: the STATUS line must name the watcher tag `\($tag.tag)` of task `\($tid)`."}]
              else
                ((([($t.description // "") | capture("ttl=(?<m>[0-9]+)")] | first | .m) // "120") | tonumber) as $ttl
                | (($st.gate.tasks // {})[$tid] // $now) as $first
                | if ($now - $first) > ($ttl * 60) then
                    [{rule: "G3", msg: "G3: watcher `\($tid)` has run longer than its TTL of \($ttl) min. Diagnose it (read its output), fix or relaunch it, or end with `STATUS: FAILURE \($tag.tag): <observed output>`."}]
                  else [] end
              end
          end
      end
  end;

def g4($s; $R):
  if $s.kind != "COMPLETE" then {v: [], plain: [], pred_ack: null, sys: []}
  else
    [$R[] | select(.kind == "merge" or .kind == "push")] as $changes
    | if ($changes | length) == 0 then {v: [], plain: [], pred_ack: null, sys: []}
      else
        ([$R[] | select(.kind == "predicate")] | sort_by(.ts // 0)) as $P
        | ($P | last) as $p
        | if $p == null then
            {v: [{rule: "G4", msg: "G4: this session merged or pushed, and no exit predicate is recorded. State it with `/session-name <label> --done '<item>' [--done '<item>']...`, with at least one `cmd:`, `merged:<owner/repo>#<pr>` or `staging:<owner/repo>` item, check it, and finish."}], plain: [], pred_ack: null, sys: []}
          else
            ($changes | map(.ts // 0) | max) as $lastchange
            | [($p.items // []) | to_entries[] | select(.value | type == "string")] as $E
            | ($E | map(select(.value | test("^(cmd|merged|staging):")))) as $machine
            | ($E | map(select(.value | test("^(cmd|merged|staging):") | not) | .value)) as $plain
            | (($P | length) >= 2 and ($P[-2].sha256 != $p.sha256) and ($p | in_prompt) and (($st.gate.pred_ack // "") != $p.sha256)) as $changed
            | {
                v: ((if ($machine | length) == 0 then [{rule: "G4", msg: "G4: the exit predicate has no machine-checkable item. Work that merges or pushes needs at least one `cmd:<command>`, `merged:<owner/repo>#<pr>` or `staging:<owner/repo>` item. Record it with `/session-name <label> --done '<item>'`."}] else [] end)
                  + [$machine[] as $e
                    | if ($e.value | startswith("cmd:")) then
                        if any($R[]; .kind == "check" and .item == $e.key and .pred_sha == $p.sha256 and .exit == 0 and ((.ts // 0) >= $lastchange)) then empty
                        else {rule: "G4", msg: "G4: predicate item \($e.key) (`\($e.value)`) has no passing check after the last merge or push. Run `bash ~/.claude/scripts/done_gate.sh check \($e.key)` and fix what fails."} end
                      elif ($e.value | startswith("merged:")) then
                        ($e.value | ltrimstr("merged:") | split("#")) as $parts
                        | {repo: $parts[0], pr: ($parts[1] // "" | ltrimstr("#"))} as $m
                        | if any($R[]; .kind == "verify" and same(.; $m) and verify_ok) then empty
                          else {rule: "G4", msg: "G4: predicate item `\($e.value)` has no passing staging verify record. Wait for the post-merge watcher (`gh_monitor.sh wait \($m.pr) --repo \($m.repo)`) and act on its verdict."} end
                      else
                        ($e.value | ltrimstr("staging:")) as $repo
                        | (([$R[] | select(.kind == "merge" and .repo == $repo) | (.ts // 0)] | max) // 0) as $lm
                        | if any($R[]; .kind == "verify" and .repo == $repo and verify_ok and ((.ts // 0) >= $lm)) then empty
                          else {rule: "G4", msg: "G4: predicate item `\($e.value)` has no passing staging verify record after the last merge in \($repo)."} end
                      end]
                  + (if $changed then [{rule: "G4", msg: "G4: the exit predicate changed during this prompt. Say what changed and why in the final message, then finish against the new predicate."}] else [] end)),
                plain: $plain,
                pred_ack: (if $changed then $p.sha256 else null end),
                sys: (if $changed then ["Exit predicate changed. Old: \($P[-2].items | join(" | ")). New: \($p.items | join(" | "))."] else [] end)
              }
          end
      end
  end;

def stop_eval:
  records as $R
  | ($hookin[0].last_assistant_message // "") as $msg
  | parse_status($msg) as $s
  | g2($s; $R) as $g2
  | g4($s; $R) as $g4
  | (reduce (tasks[] | select((.status // "") | live) | (.id | tostring)) as $id ({}; .[$id] = (($st.gate.tasks // {})[$id] // $now))) as $seen
  | {
      status: $s,
      violations: (g1($s; $msg; $R) + $g2.v + g3($s) + $g4.v),
      acks: $g2.acks,
      plain: $g4.plain,
      sys: $g4.sys,
      gate: {tasks: $seen, pred_ack: ($g4.pred_ack // $st.gate.pred_ack // "")},
      bad_lines: bad_lines
    };

def pending_eval: records as $R | {pending: (pending($R) | map(pending_line))};

if $op == "pending" then pending_eval else stop_eval end
