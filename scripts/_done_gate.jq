include "_probe_common";

def categories: ["credential", "captcha", "payment", "physical", "destructive-prod-data", "spending-money", "irreversible-external-send", "paradigm-shift"];

def status_kinds: ["COMPLETE", "WAITING", "BLOCKED", "FAILURE", "ANSWER"];

def N_ATTEMPTS: 3;

def N_APPROACHES: 2;

def noop_bins: ["true", "false", "exit", ":", "echo", "printf", "test", "[", "sleep"];

def hedge_re: "\\binferred\\b|\\bI guess(ed)?\\b|\\bguessed\\b|\\bI haven'?t\\b|\\bnot (yet )?verified\\b|\\bI('m| am)? assum(e|ed|ing)\\b|\\bassuming (that|it|the)\\b|\\bunverified\\b";

def offer_re: "\\bI can\\b.*\\bif you (want|like|'d like)\\b|\\bwant me to\\b|\\bshould I\\b|\\bshall I\\b|\\bdo you want\\b|\\blet me know if\\b|\\btell me if\\b";

def partial_re: "\\b(partly|partially|only partly|still open|stays? open|blocked on|untouched|not tried|still 0|not done)\\b";

def surfaces: ["staging", "production", "simulator", "local"];

def contract: "End the final message with exactly one STATUS line as its last line: `STATUS: COMPLETE <evidence>`, `STATUS: WAITING <task-id> <what it waits for>`, `STATUS: BLOCKED <category>: <one-line ask>` (categories: \(categories | join(", "))), `STATUS: FAILURE <what>: <command and observed output>`, or `STATUS: ANSWER VERIFIED <command or path>: <observed output>` for a pure answer (cite the command in backticks and quote its output in backticks). FAILURE is accepted only after \(N_ATTEMPTS) distinct failed attempts across \(N_APPROACHES) different tools in this prompt, quoting one failure's output in backticks. If you cannot verify, end with BLOCKED (human-only) or FAILURE.";

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

def body($msg):
  ($msg | split("\n")) as $l
  | ([range(0; $l | length) | select(($l[.] | clean_line | length) > 0)] | last) as $i
  | if $i != null and ($l[$i] | clean_line | test("^STATUS:"; "i")) then $l[0:$i] | join("\n") else $msg end;

def prose: gsub("```[\\s\\S]*?```"; " ") | gsub("`[^`\\n]*`"; " ") | split("\n") | map(select(test("^\\s*>") | not)) | join("\n");

def last_paragraph: [splits("\\n\\s*\\n") | select(test("\\S"))] | last // "";

def quotes: (if ([scan("`")] | length) % 2 == 1 then . + "`" else . end) | [scan("`([^`]+)`") | .[0] | collapse];

def parse_answer($rest): [$rest | capture("^VERIFIED\\s+(?<src>`[^`]+`|[^:]+?)\\s*:\\s*(?<obs>\\S.*)$"; "i")] | first;

def split_failure($rest): ([$rest | capture("^(?<w>.*?):(?<e>\\s.*|$)")] | first) // {w: "", e: ""};

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

def latest_predicate($R): [$R[] | select(.kind == "predicate")] | sort_by(.ts // 0) | last;

def allowed_surfaces($R; $repo):
  ["staging", "production"]
  + [((latest_predicate($R) // {}).items // [])[] | strings
      | capture("^surface:(?<repo>[^:]+):(?<s>[a-z]+)$") | select(.repo == $repo) | .s];

def target_surface: .surface // "staging";

def verify_ok($allowed):
  . as $v
  | ($v.result == "n/a")
    or ($v.result == "pass"
      and any(($v.targets // [])[]; (.skipped // false) | not)
      and all(($v.targets // [])[]; . as $t
        | ($t.skipped // false)
        or ((($t.observed_sha // "") | length) >= 7
        and ($t.contains_merge == true or (($v.merge_sha // "") | startswith($t.observed_sha)))
        and all(($t.probes // [])[]; .exit == 0 and .matched == true)
        and (($allowed | index($t | target_surface)) != null))));

def bad_surfaces($allowed): [(.targets // [])[] | select((.skipped // false) | not) | target_surface | select(. as $s | ($allowed | index($s)) == null)] | unique;

def surface_note($v; $allowed; $repo):
  if $v == null then ""
  else ($v | bad_surfaces($allowed)) as $b
    | if ($b | length) > 0 then " The verify ran on surface `\($b | join(", "))`, which is not staging or production; add `surface:\($repo):\($b[0])` to the predicate if that surface is the right proof." else "" end
  end;

def merges($R): [$R[] | select(.kind == "merge")] | group_by([(.repo // ""), ident]) | map(max_by(.ts // 0));

def verifies($R; $m): [$R[] | select(.kind == "verify" and same(.; $m) and ((.ts // 0) >= ($m.ts // 0)))];

def acked($R; $m): any($R[]; .kind == "ack" and same(.; $m) and ((.ts // 0) >= ($m.ts // 0)));

def pending($R):
  [merges($R)[] as $m
    | allowed_surfaces($R; $m.repo // "") as $allowed
    | select((any(verifies($R; $m)[]; verify_ok($allowed)) | not) and (acked($R; $m) | not))
    | $m + {last_verify: (verifies($R; $m) | max_by(.ts // 0)), allowed: $allowed}];

def current_prompt_id:
  if ($hookin[0].prompt_id // "") != "" then $hookin[0].prompt_id
  elif (($st.prompt.synthetic // false) | not) then ($st.prompt.id // "")
  else "" end;

def prompt_start:
  if (($st.prompt.synthetic // false) | not) and ($st.prompt.id // "") != "" and ($hookin[0].prompt_id // "") != "" and $st.prompt.id != $hookin[0].prompt_id then null
  else ($st.prompt.ts // null) end;

def in_prompt:
  . as $r
  | ((($hookin[0].prompt_id // "") != "" and ($r.prompt_id // "") == $hookin[0].prompt_id)
    or (prompt_start != null and (($r.ts // 0) >= prompt_start)));

def in_prompt_strict:
  . as $r
  | if ($r.prompt_id // "") != "" then current_prompt_id != "" and $r.prompt_id == current_prompt_id
    elif prompt_start == null then false
    elif ($r.ts_ms | type) == "number" and ($st.prompt.ts_ms | type) == "number" then $r.ts_ms >= $st.prompt.ts_ms
    else ($r.ts // 0) >= prompt_start end;

def order_key: (.ts_ms // ((.ts // 0) * 1000));

def dedupe: group_by(if (.tool_use_id // "") == "" then tojson else .tool_use_id end) | map(first) | sort_by(order_key);

def probes($R): [$R[] | select(.kind == "probe" and in_prompt_strict)] | dedupe;

def failed: (.bin // "") as $b | .exit != 0 and ((.interrupt // false) | not) and ((noop_bins | index($b)) == null);

def failed_probes($R): [probes($R)[] | select(failed)];

def live: . as $s | (["running", "pending", "in_progress", "starting"] | index($s)) != null;

def arr: if type == "array" then . else [] end;

def tasks: ($hookin[0].background_tasks | arr);

def find_task($id): [tasks[] | select((.id | tostring) == $id)] | first;

def find_cron($id): [($hookin[0].session_crons | arr)[] | select((.id | tostring) == $id)] | first;

def wait_tag($t): ([($t.description // "") | capture("\\[wait:(?<tag>[^\\]\\s]+)\\]")] | first | .tag) // null;

def task_ttl($t): (([($t.description // "") | capture("ttl=(?<m>[0-9]+)")] | first | .m) // "120") | tonumber;

def ttl_expired($t): (($st.gate.tasks // {})[$t.id | tostring] // $now) as $first | ($now - $first) > (task_ttl($t) * 60);

def live_waiter($m):
  any(tasks[]; ((.status // "") | live) and ((.command // "") | test("gh_monitor\\.sh\\s+wait"))
    and (mentions(.command // ""; $m.target) or mentions(.command // ""; $m | ident)));

def pending_line:
  "\(pr_label) (merged \(.ts // 0 | todate)) has no passing staging verify result"
  + (if .last_verify then " (last result: \(.last_verify.result)\(if .last_verify.reason then ", " + .last_verify.reason else "" end))" else "" end);

def todo_msg: "G1: a stop with open `# TODO` items. Do the agent-doable items now; a step that waits on the human goes under `# Needs human`, and the turn ends `STATUS: BLOCKED <category>: <ask>` with the done work under `# Done`.";

def g1($s; $msg; $R):
  (body($msg) | prose) as $prose
  | if $s.kind == null then
    [{rule: "G1", msg: "G1: the last line is not a STATUS line (it was: \"\($s.line | .[0:160])\"). \(contract) Do not end on a question or an offer: if the next step is observable or pre-approved (merge on green, push, PR, staging deploy, CI fixes, read-only checks, local cleanup), do it now."}]
  elif (status_kinds | index($s.kind)) == null then
    [{rule: "G1", msg: "G1: `STATUS: \($s.kind)` is not a valid status. \(contract)"}]
  elif $s.kind == "COMPLETE" then
    ([$prose | match(partial_re; "gi") | .string] | first) as $p
    | (if ($s.rest | length) == 0 then [{rule: "G1", msg: "G1: `STATUS: COMPLETE` needs an evidence pointer (command and observed output, a URL, or a path)."}] else [] end)
    + (if section_open($msg; "TODO") then [{rule: "G1", msg: "G1: `STATUS: COMPLETE` with a non-empty `# TODO` section. Do the TODO items now, or end with WAITING, BLOCKED or FAILURE that names the open item."}] else [] end)
    + (if section_open($msg; "Needs human") then [{rule: "G1", msg: "G1: `STATUS: COMPLETE` with a non-empty `# Needs human` section. A real human-only step ends with `STATUS: BLOCKED <category>: <ask>`."}] else [] end)
    + (if $p != null then [{rule: "G1", msg: "G1: `STATUS: COMPLETE` but the message says \"\($p)\". Finish it, or end with BLOCKED <category> (human-only part) or FAILURE, listing the done part under `# Done`."}] else [] end)
  elif $s.kind == "BLOCKED" then
    ([$s.rest | capture("^(?<cat>[A-Za-z-]+)\\s*:\\s*(?<ask>\\S.*)$")] | first) as $b
    | if $b == null then
        [{rule: "G1", msg: "G1: write BLOCKED as `STATUS: BLOCKED <category>: <one-line ask>` with a category from: \(categories | join(", "))."}]
      elif (categories | index($b.cat | ascii_downcase)) == null then
        [{rule: "G1", msg: "G1: `\($b.cat)` is not a human-only category. Allowed: \(categories | join(", ")). Merging on green, pushing, PRs, staging deploys, CI fixes, read-only checks and local cleanup are pre-approved: do the step now and report. If it truly cannot be done, end with `STATUS: FAILURE <what>: <command and observed output>`."}]
      elif section_open($msg; "TODO") then [{rule: "G1", msg: todo_msg}]
      else [] end
  elif $s.kind == "FAILURE" then
    if ($s.rest | test("^[^:]*\\S[^:]*:\\s*\\S")) | not then
      [{rule: "G1", msg: "G1: write FAILURE as `STATUS: FAILURE <what>: <command and observed output, or a path>`. The evidence part after the colon is required."}]
    elif section_open($msg; "TODO") then [{rule: "G1", msg: todo_msg}]
    else [] end
  elif $s.kind == "ANSWER" then
    if any($R[]; (.kind == "merge" or .kind == "push") and in_prompt) then
      [{rule: "G1", msg: "G1: `STATUS: ANSWER` is only for a pure answer, and this prompt merged or pushed. End with COMPLETE (predicate met), WAITING (live watcher) or FAILURE."}]
    elif parse_answer($s.rest) == null then
      [{rule: "G1", msg: "G1: bare `STATUS: ANSWER` is gone: use `STATUS: ANSWER VERIFIED <command or path>: <observed output>` (the command in backticks, a quote of its output in backticks), or BLOCKED/FAILURE."}]
    else
      ([("Open ends", "TODO", "Needs human") | select(section_open($msg; .))] | first) as $open
      | ([$prose | last_paragraph | match(offer_re; "gi") | .string] | first) as $offer
      | ([$prose | match(hedge_re; "gi") | .string] | first) as $hedge
      | (if $open != null then [{rule: "G1", msg: "G1: `STATUS: ANSWER VERIFIED` with a non-empty `# \($open)` section. Do the open items now, or end with BLOCKED (human-only) or FAILURE."}] else [] end)
      + (if $offer != null then [{rule: "G1", msg: "G1: `STATUS: ANSWER VERIFIED` ends on an offer (\"\($offer)\"). Do the step now if it is pre-approved, or drop the offer."}] else [] end)
      + (if $hedge != null then [{rule: "G1", msg: "G1: `STATUS: ANSWER VERIFIED` but the message hedges (\"\($hedge)\"). Run the check and state the observed result, or end with BLOCKED (human-only) or FAILURE."}] else [] end)
    end
  else [] end;

def g2($s; $R):
  reduce pending($R)[] as $m ({v: [], acks: []};
    split_failure($s.rest) as $f
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
          "G2: the staging verify record for \($m | pr_label) does not prove the merge: the observed SHA must contain \($m.last_verify.merge_sha // "the merge commit") and every probe must pass.\(surface_note($m.last_verify; $m.allowed; $m.repo // "")) Re-run the verification or end with `STATUS: FAILURE \($m | pr_label): <observed output>`."
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
            wait_tag($t) as $tag
            | if $tag == null then
                [{rule: "G3", msg: "G3: task `\($tid)` is not a watcher: its description has no `[wait:<tag>]`. A `tail -f` or a bare `sleep` does not wait for anything. Launch a background poll loop that exits on the awaited condition, with `[wait:<tag>]` in its description, and end with `STATUS: WAITING <task-id> <tag>`."}]
              elif (mentions($s.rest; $tag) | not) then
                [{rule: "G3", msg: "G3: the STATUS line must name the watcher tag `\($tag)` of task `\($tid)`."}]
              elif ttl_expired($t) then
                [{rule: "G3", msg: "G3: watcher `\($tid)` has run longer than its TTL of \(task_ttl($t)) min. Diagnose it (read its output), fix or relaunch it, or end with `STATUS: FAILURE \($tag): <observed output>`."}]
              else [] end
          end
      end
  end;

def cite_matches($src; $p):
  ($src | gsub("`"; "") | collapse) as $c
  | ($c | bash_cmd(.)) as $n
  | ($p.cmd // "") as $pc
  | ($pc | ltrimstr(($p.tool // "") + " ")) as $rest
  | ($c != "") and (($pc | contains($c)) or ($pc | contains($n)) or (($rest | length) >= 3 and ($c | contains($rest))));

def g5_answer($s; $R):
  parse_answer($s.rest) as $a
  | [probes($R)[] | select(.ro == true)] as $ro
  | ($a.obs | quotes | map(select(length >= 4))) as $q
  | [$ro[] | select(cite_matches($a.src; .))] as $hits
  | ($ro | map(.cmd) | .[-5:] | map("`" + . + "`") | join(", ")) as $recent
  | if ($hits | length) == 0 then
      [{rule: "G5", msg: "G5: `ANSWER VERIFIED` cites \($a.src), and no read-only command or read in this prompt matches it. Run it read-only (no writes, no `;`/`&&` chains) and cite it as run. Recent read-only probes: \(if $recent == "" then "none" else $recent end)."}]
    elif ($q | length) == 0 then
      [{rule: "G5", msg: "G5: `ANSWER VERIFIED` needs the observed output quoted in backticks (at least 4 characters copied from the output of \($a.src))."}]
    elif any($hits[]; (.out_excerpt // "") as $e | any($q[]; . as $x | $e | contains($x))) then []
    else
      [{rule: "G5", msg: "G5: the quoted observation is not in the output of \($a.src) recorded in this prompt. Quote the output exactly as the command printed it."}]
    end;

def g5_failure($s; $R; $exempt):
  if $exempt != null then []
  else
    failed_probes($R) as $F
    | ($F | map(.cmd) | unique) as $cmds
    | ($F | map(.bin) | unique) as $bins
    | (split_failure($s.rest).e | quotes | map(select(length >= 8))) as $q
    | ($F | map("`\(.cmd)` (exit \(.exit))") | .[-10:] | join(", ")) as $tried
    | if ($cmds | length) < N_ATTEMPTS or ($bins | length) < N_APPROACHES then
        [{rule: "G5", msg: "G5: FAILURE needs \(N_ATTEMPTS) distinct failed attempts across \(N_APPROACHES) different tools in this prompt (seen: \($cmds | length) commands, \($bins | length) tools). Tried so far: \(if $tried == "" then "nothing failed yet" else $tried end). Try a different approach (another tool or binary) and retry; a human-only step ends with BLOCKED."}]
      elif (any($q[]; . as $x | any($F[]; (.out_excerpt // "") | contains($x))) | not) then
        [{rule: "G5", msg: "G5: the FAILURE evidence must quote in backticks at least 8 characters of a failed command's output from this prompt; none of its quotes matches. Tried so far: \($tried)."}]
      elif any($R[]; .kind == "failure" and (.accepted == false) and (.reason != null) and in_prompt_strict and ((.failed_seen // 0) >= ($F | length))) then
        [{rule: "G5", msg: "G5: no new failed attempt since the last rejected FAILURE in this prompt. Try a different approach (another tool or binary) first. Tried so far: \($tried)."}]
      else [] end
  end;

def failure_exempt($s; $g2):
  if $s.kind != "FAILURE" then null
  elif ($g2.acks | length) > 0 then {rule: "G2"}
  else
    (split_failure($s.rest).w | collapse) as $what
    | ([tasks[] | select(wait_tag(.) != null and wait_tag(.) == $what and ttl_expired(.))] | first) as $t
    | if $t != null then {rule: "G3", task: ($t.id | tostring)} else null end
  end;

def g5($s; $R; $exempt):
  if $s.kind == "ANSWER" then g5_answer($s; $R)
  elif $s.kind == "FAILURE" then g5_failure($s; $R; $exempt)
  else [] end;

def g4_shrink($R):
  [$R[] | select(.kind == "predicate" and in_prompt_strict)] | sort_by(order_key) as $P
  | [range(1; $P | length) as $i
      | (($P[$i - 1].items // []) - ($P[$i].items // []))[]
      | {rule: "G4", msg: "G4: the exit predicate dropped `\(.)` during this prompt. Restore it with `/session-name <label> --done ...` (adding items is fine)."}]
  | unique_by(.msg);

def machine_re: "^(cmd|merged|staging|linear):";

def norm_state: ascii_downcase | collapse;

def linear_check($e; $R; $lastchange):
  ([$e.value | capture("^linear:(?<id>[^:]+):(?<state>.+)$")] | first) as $l
  | if $l == null then {rule: "G4", msg: "G4: predicate item `\($e.value)` is not `linear:<ID>:<state>`."}
    else
      ([$R[] | select(.kind == "probe" and ((.bin // "") | test("^mcp__.*linear.*__get_issue$"; "i")) and .exit == 0
          and ((.fact.linear // "") | ascii_downcase) == ($l.id | ascii_downcase)
          and in_prompt_strict and ((.ts // 0) >= $lastchange))] | dedupe | last) as $f
      | if $f != null and (($f.fact.state // "") | norm_state) == ($l.state | norm_state) then empty
        else {rule: "G4", msg: "G4: predicate item `\($e.value)` has no Linear read showing that state after the last change\(if $f != null then " (the latest read shows `\($f.fact.state)`)" else "" end). Read the issue with the Linear MCP `get_issue` (in a subagent) and move it if needed."}
        end
    end;

def g4($s; $R):
  g4_shrink($R) as $shrink
  | if $s.kind != "COMPLETE" then {v: $shrink, plain: [], pred_ack: null, sys: []}
    else
      [$R[] | select(.kind == "merge" or .kind == "push")] as $changes
      | ([$R[] | select(.kind == "predicate")] | sort_by(.ts // 0)) as $P
      | ($P | last) as $p
      | (($changes | map(.ts // 0) | max) // 0) as $lastchange
      | [(($p // {}).items // []) | to_entries[] | select(.value | type == "string")] as $E
      | ($E | map(select(.value | test("^linear:")))) as $linear
      | if ($changes | length) == 0 then
          {v: ($shrink + [$linear[] | linear_check(.; $R; 0)]), plain: [], pred_ack: null, sys: []}
        elif $p == null then
          {v: ($shrink + [{rule: "G4", msg: "G4: this session merged or pushed, and no exit predicate is recorded. State it with `/session-name <label> --done '<item>' [--done '<item>']...`, with at least one `cmd:`, `merged:<owner/repo>#<pr>`, `staging:<owner/repo>` or `linear:<ID>:<state>` item, check it, and finish."}]), plain: [], pred_ack: null, sys: []}
        else
          ($E | map(select(.value | test(machine_re)))) as $machine
          | ($E | map(select(.value | test(machine_re + "|^surface:") | not) | .value)) as $plain
          | (($P | length) >= 2 and ($P[-2].sha256 != $p.sha256) and ($p | in_prompt) and (($st.gate.pred_ack // "") != $p.sha256)) as $changed
          | {
              v: ($shrink
                + (if ($machine | length) == 0 then [{rule: "G4", msg: "G4: the exit predicate has no machine-checkable item. Work that merges or pushes needs at least one `cmd:<command>`, `merged:<owner/repo>#<pr>`, `staging:<owner/repo>` or `linear:<ID>:<state>` item. Record it with `/session-name <label> --done '<item>'`."}] else [] end)
                + [$machine[] as $e
                  | if ($e.value | startswith("cmd:")) then
                      if any($R[]; .kind == "check" and .item == $e.key and .pred_sha == $p.sha256 and .exit == 0 and ((.ts // 0) >= $lastchange)) then empty
                      else {rule: "G4", msg: "G4: predicate item \($e.key) (`\($e.value)`) has no passing check after the last merge or push. Run `bash ~/.claude/scripts/done_gate.sh check \($e.key)` and fix what fails."} end
                    elif ($e.value | startswith("linear:")) then linear_check($e; $R; $lastchange)
                    elif ($e.value | startswith("merged:")) then
                      ($e.value | ltrimstr("merged:") | split("#")) as $parts
                      | {repo: $parts[0], pr: ($parts[1] // "" | ltrimstr("#"))} as $m
                      | allowed_surfaces($R; $m.repo) as $allowed
                      | [$R[] | select(.kind == "verify" and same(.; $m))] as $V
                      | if any($V[]; verify_ok($allowed)) then empty
                        else {rule: "G4", msg: "G4: predicate item `\($e.value)` has no passing staging verify record.\(surface_note($V | last; $allowed; $m.repo)) Wait for the post-merge watcher (`gh_monitor.sh wait \($m.pr) --repo \($m.repo)`) and act on its verdict."} end
                    else
                      ($e.value | ltrimstr("staging:")) as $repo
                      | allowed_surfaces($R; $repo) as $allowed
                      | (([$R[] | select(.kind == "merge" and .repo == $repo) | (.ts // 0)] | max) // 0) as $lm
                      | [$R[] | select(.kind == "verify" and .repo == $repo and ((.ts // 0) >= $lm))] as $V
                      | if any($V[]; verify_ok($allowed)) then empty
                        else {rule: "G4", msg: "G4: predicate item `\($e.value)` has no passing staging verify record after the last merge in \($repo).\(surface_note($V | last; $allowed; $repo))"} end
                    end]
                + (if $changed then [{rule: "G4", msg: "G4: the exit predicate changed during this prompt. Say what changed and why in the final message, then finish against the new predicate."}] else [] end)),
              plain: $plain,
              pred_ack: (if $changed then $p.sha256 else null end),
              sys: (if $changed then ["Exit predicate changed. Old: \($P[-2].items | join(" | ")). New: \($p.items | join(" | "))."] else [] end)
            }
        end
    end;

def skipped_rules: ($ARGS.named.skip // "") | split(",") | map(select(length > 0));

def stop_eval:
  records as $R
  | ($hookin[0].last_assistant_message // "") as $msg
  | parse_status($msg) as $s
  | g1($s; $msg; $R) as $g1
  | g2($s; $R) as $g2
  | failure_exempt($s; $g2) as $exempt
  | (if ($g1 | length) == 0 then g5($s; $R; $exempt) else [] end) as $g5
  | g4($s; $R) as $g4
  | skipped_rules as $skip
  | (reduce (tasks[] | select((.status // "") | live) | (.id | tostring)) as $id ({}; .[$id] = (($st.gate.tasks // {})[$id] // $now))) as $seen
  | failed_probes($R) as $F
  | {
      status: $s,
      violations: ([$g1[], $g2.v[], g3($s)[], $g4.v[], $g5[]] | map(select(.rule as $r | ($skip | index($r)) == null))),
      acks: (if ($g1 | length) == 0 then $g2.acks else [] end),
      plain: $g4.plain,
      sys: $g4.sys,
      gate: {tasks: $seen, pred_ack: ($g4.pred_ack // $st.gate.pred_ack // "")},
      bad_lines: bad_lines,
      ladder: {attempts: N_ATTEMPTS, approaches: N_APPROACHES},
      failure_log: (if $s.kind == "FAILURE" then
        {
          kind: "failure",
          what: (split_failure($s.rest).w | collapse),
          accepted: ((($g1 + $g5) | length) == 0),
          exempt: ($exempt.rule // null),
          failed_seen: ($F | length),
          attempts: ($F | map({cmd, bin, exit, out_excerpt: ((.out_excerpt // "") | .[0:200])}) | .[-20:]),
          reason: ($g5[0].msg // null),
          n_attempts: N_ATTEMPTS,
          n_approaches: N_APPROACHES
        }
        + (if $exempt.task then {exempt_task: $exempt.task} else {} end)
        + (if ($hookin[0].prompt_id // "") != "" then {prompt_id: $hookin[0].prompt_id} else {} end)
      else null end)
    };

def pending_eval: records as $R | {pending: (pending($R) | map(pending_line))};

if $op == "pending" then pending_eval else stop_eval end
