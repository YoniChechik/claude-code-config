def DYN: "\uFFFD";
def SHELLS: ["bash", "sh", "zsh", "dash", "ksh", "mksh"];
def TERMINATORS: ["exit", "return"];
def GITREPOENV: ["GIT_DIR", "GIT_WORK_TREE"];

def lit: gsub("\\\\\n"; "") | gsub("\\\\(?<c>.)"; "\(.c)"; "s");
def dqlit: gsub("\\\\\n"; "") | gsub("\\\\(?<c>[\"\\\\$`])"; "\(.c)");
def hdlit: gsub("\\\\\n"; "") | gsub("\\\\(?<c>[\\\\$`])"; "\(.c)");
def ansic: gsub("\\\\n"; "\n") | gsub("\\\\t"; "\t") | gsub("\\\\(?<c>['\"\\\\])"; "\(.c)");
def globby: test("(^|[^\\\\])[*?]|(^|[^\\\\])\\[.+\\]") or test("\\{[^{}]*(,|\\.\\.)[^{}]*\\}");
def base: sub("^.*/"; "");

def normpath:
  split("/")
  | reduce .[] as $x ([]; if $x == "" or $x == "." then . elif $x == ".." then .[:-1] else . + [$x] end)
  | "/" + join("/");
def resolve($b): if startswith("/") then normpath else ($b + "/" + .) | normpath end;

def part($dq):
  if .Type == "Lit" then {s: (.Value | if $dq then dqlit else lit end), dyn: (($dq | not) and (.Value | globby))}
  elif .Type == "SglQuoted" then {s: (if .Dollar then (.Value | ansic) else .Value end), dyn: false}
  elif .Type == "DblQuoted" then ([.Parts[]? | part(true)] | {s: (map(.s) | join("")), dyn: (map(.dyn) | any)})
  else {s: DYN, dyn: true} end;

def word:
  if . == null then {s: "", dyn: false}
  else (.Parts // []) as $p
    | ([$p[] | part(false)] | {s: (map(.s) | join("")), dyn: (map(.dyn) | any)}) as $w
    | if ($p | length) > 0 and $p[0].Type == "Lit" and ($p[0].Value | test("^~(/|$)"))
      then $w + {s: ($home + ($w.s | .[1:]))}
      elif ($p | length) > 0 and $p[0].Type == "Lit" and ($p[0].Value | test("^~"))
      then $w + {dyn: true}
      else $w end
  end;

def substs:
  if type == "object" then (if .Type == "CmdSubst" or .Type == "ProcSubst" then . else (.[] | substs) end)
  elif type == "array" then (.[] | substs)
  else empty end;

def mergest($a; $b):
  {cwd: $a.cwd, known: ($a.known and $b.known and $a.cwd == $b.cwd),
   alts: (if $a.alts == null or $b.alts == null then null else ($a.alts + $b.alts | unique) end),
   gitenv: ($a.gitenv or $b.gitenv), cdpath: ($a.cdpath or $b.cdpath),
   funcs: ($a.funcs + $b.funcs | unique)};
def lost: . + {known: false, alts: null};

def skipopts($w; $i; $witharg):
  if $i >= ($w | length) or $w[$i].dyn then $i
  elif $w[$i].s == "--" then $i + 1
  elif ($w[$i].s | startswith("-")) and $w[$i].s != "-" then
    (if ($witharg | any(. == $w[$i].s)) then skipopts($w; $i + 2; $witharg) else skipopts($w; $i + 1; $witharg) end)
  else $i end;

def unwrap($w; $i; $acc):
  def envw($i; $acc):
    if $i >= ($w | length) then $acc + {i: $i}
    elif $w[$i].s | test("^[A-Za-z_][A-Za-z0-9_]*=") then envw($i + 1; $acc | .env += [$w[$i].s])
    elif $w[$i].dyn then $acc + {i: $i}
    elif $w[$i].s == "-u" then envw($i + 2; $acc)
    elif $w[$i].s == "-C" or $w[$i].s == "--chdir" then envw($i + 2; $acc | .chdir = true)
    elif $w[$i].s | startswith("--chdir=") then envw($i + 1; $acc | .chdir = true)
    elif ($w[$i].s | test("^-[a-zA-Z0-9]*S")) or ($w[$i].s | startswith("--split-string")) then $acc + {i: ($w | length), unknown: ($acc.unknown + ["env -S"])}
    elif $w[$i].s == "--" then envw($i + 1; $acc)
    elif $w[$i].s | startswith("-") then envw($i + 1; $acc)
    else unwrap($w; $i; $acc) end;
  if $i >= ($w | length) or $w[$i].dyn then $acc + {i: $i}
  else ($w[$i].s | base) as $b
    | ($w[$i + 1].s // "") as $nx
    | if $b == "rtk" then
        (if $nx == "proxy" or $nx == "run" then unwrap($w; $i + 2; $acc | .wrappers += ["rtk " + $nx])
         else unwrap($w; $i + 1; $acc | .wrappers += ["rtk"]) end)
      elif $b == "env" then envw($i + 1; $acc | .wrappers += ["env"])
      elif $b == "command" then
        (skipopts($w; $i + 1; [])) as $j
        | if ($w[$i + 1:$j] | any(.s | test("^-[a-zA-Z]*[vV]"))) then $acc + {i: $i}
          else unwrap($w; $j; $acc | .wrappers += ["command"]) end
      elif $b == "builtin" or $b == "nohup" then unwrap($w; $i + 1; $acc | .wrappers += [$b])
      elif $b == "exec" then unwrap($w; skipopts($w; $i + 1; ["-a"]); $acc | .wrappers += ["exec"])
      elif $b == "time" then unwrap($w; skipopts($w; $i + 1; ["-f", "-o", "--format", "--output"]); $acc | .wrappers += ["time"])
      elif $b == "nice" then unwrap($w; skipopts($w; $i + 1; ["-n", "--adjustment"]); $acc | .wrappers += ["nice"])
      elif $b == "stdbuf" then unwrap($w; skipopts($w; $i + 1; ["-i", "-o", "-e"]); $acc | .wrappers += ["stdbuf"])
      elif $b == "sudo" then unwrap($w; skipopts($w; $i + 1; ["-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-D", "-R", "-T"]); $acc | .wrappers += ["sudo"])
      elif $b == "timeout" or $b == "gtimeout" then unwrap($w; skipopts($w; $i + 1; ["-s", "-k", "--signal", "--kill-after"]) + 1; $acc | .wrappers += [$b])
      else $acc + {i: $i} end
  end;

def shellmode($a):
  def go($i; $c):
    if $i >= ($a | length) then (if $c then {mode: "c", idx: null} else {mode: "stdin"} end)
    elif $a[$i].dyn then (if $c then {mode: "c", idx: $i} else {mode: "file"} end)
    elif $a[$i].s == "--" or $a[$i].s == "-" then go($i + 1; $c)
    elif ["-o", "+o", "-O", "+O", "--rcfile", "--init-file"] | any(. == $a[$i].s) then go($i + 2; $c)
    elif $a[$i].s | test("^-[a-zA-Z]*c[a-zA-Z]*$") then go($i + 1; true)
    elif $a[$i].s | test("^-[a-zA-Z]*s[a-zA-Z]*$") then go($i + 1; $c)
    elif ($a[$i].s | startswith("-")) or ($a[$i].s | startswith("+")) then go($i + 1; $c)
    elif $c then {mode: "c", idx: $i}
    else {mode: "file"} end;
  go(1; false);

def hdoc_of:
  (.Word | [.Parts[]? | select(.Type != "Lit" or (.Value | test("\\\\")))] | length > 0) as $quoted
  | ([.Hdoc.Parts[]? | select(.Type != "Lit")] | length > 0) as $bdyn
  | (if $quoted then ([.Hdoc.Parts[]?.Value] | join(""))
     elif $bdyn then null
     else ([.Hdoc.Parts[]?.Value] | join("") | hdlit) end) as $body
  | {quoted: $quoted, dash: (.Op == "<<-"), body_dynamic: ($bdyn and ($quoted | not)),
     body: (if $body != null and .Op == "<<-" then ($body | gsub("(?m)^\t+"; "")) else $body end)};

def redir:
  (.Word | word) as $t
  | {op: .Op, fd: (.N.Value // null), target: $t.s, target_dynamic: $t.dyn,
     heredoc: (if .Op == "<<" or .Op == "<<-" then hdoc_of else null end)};

def gitinfo($aw; $s; $segenv):
  def gopts($i; $acc):
    if $i >= ($aw | length) then $acc + {si: null}
    elif $aw[$i].dyn then $acc + {si: $i}
    else $aw[$i].s as $a
      | if $a == "-C" then gopts($i + 2; $acc | .cs += [$aw[$i + 1] // {s: "", dyn: true}])
        elif $a == "-c" or $a == "--config-env" then gopts($i + 2; $acc | .cfg += [($aw[$i + 1] // {s: DYN, dyn: true}) | if .dyn then DYN else .s end])
        elif $a | startswith("--config-env=") then gopts($i + 1; $acc | .cfg += [$a | ltrimstr("--config-env=")])
        elif $a == "--namespace" or $a == "--super-prefix" then gopts($i + 2; $acc)
        elif $a == "--git-dir" or $a == "--work-tree" then gopts($i + 2; $acc | .override = true)
        elif ($a | startswith("--git-dir=")) or ($a | startswith("--work-tree=")) then gopts($i + 1; $acc | .override = true)
        elif $a | startswith("-") then gopts($i + 1; $acc)
        else $acc + {si: $i} end
    end;
  gopts(1; {cs: [], cfg: [], override: false}) as $g
  | (reduce $g.cs[] as $d ({cwd: $s.cwd, known: $s.known, alts: $s.alts, n: 0};
      if $d.dyn then .known = false | .alts = null | .n += 1
      elif $d.s == "" then .
      elif $d.s | startswith("/") then .cwd = ($d.s | normpath) | .known = true | .alts = [.cwd] | .n += 1
      elif .n > 0 then .known = false | .alts = null | .n += 1
      else .cwd as $b | .cwd = ($d.s | resolve($b))
        | .alts = (if .alts == null then null else [.alts[] as $a | $d.s | resolve($a)] | unique end) | .n += 1 end)) as $gc
  | ($g.override or $s.gitenv or ($segenv | any(split("=")[0] as $n | GITREPOENV | any(. == $n)))) as $ov
  | {sub: (if $g.si == null then null elif $aw[$g.si].dyn then DYN else $aw[$g.si].s end),
     sub_dynamic: ($g.si != null and $aw[$g.si].dyn),
     args: (if $g.si == null then [] else [$aw[$g.si + 1:][].s] end),
     config: $g.cfg, cwd: $gc.cwd, cwd_known: ($gc.known and ($ov | not)),
     cwd_alts: (if $ov then null else $gc.alts end), repo_override: $ov};

def is_terminator:
  (.Cmd.Type == "CallExpr" and ((.Cmd.Args // []) | length > 0) and ((.Cmd.Args[0].Parts // []) | length == 1)
    and .Cmd.Args[0].Parts[0].Type == "Lit" and (.Cmd.Args[0].Parts[0].Value as $v | TERMINATORS | any(. == $v)))
  or (.Cmd.Type == "Block" and ((.Cmd.Stmts // []) | length > 0) and (.Cmd.Stmts[-1] | is_terminator));

def segment($c; $s; $f):
  {argv: $f.argv, dynamic: $f.dyn, cmd: $f.cmd, raw_argv: $f.raw, wrappers: $f.wrappers, env: $f.env,
   op_before: $c.op, pipeline_index: $c.pi, pipeline_len: $c.pl, negated: $c.neg, background: $c.bg,
   in_subshell: $c.subsh, in_group: $c.grp, in_substitution: $c.sub, in_compound: $c.comp, in_function: $c.fn,
   redirects: $f.redirects, outer_redirects: $c.outer,
   cwd: $s.cwd, cwd_known: ($s.known and ($f.chdir | not)), cwd_alts: (if $f.chdir then null else $s.alts end),
   git: $f.git, code: $f.code,
   unknown: (($f.reasons | length) > 0), unknown_reasons: $f.reasons,
   exit_code_belongs_to_command: $c.att};

def ev_stmt($c; $s):
def ev_stmts($c; $s):
  . as $l | ($l | length) as $n
  | if $n == 0 then {segs: [], ok: $s, any: $s}
    else reduce range(0; $n) as $k ({segs: [], ok: $s, any: $s, prevbg: false};
        . as $acc
        | ($l[$k] | ev_stmt($c + {att: ($c.att and $k == $n - 1), op: (if $k == 0 then $c.op elif $acc.prevbg then "&" else ";" end)}; $acc.any)) as $r
        | {segs: ($acc.segs + $r.segs), ok: $r.ok, any: $r.any, prevbg: ($l[$k].Background // false)})
      | del(.prevbg)
    end;

def subst_segs($c; $s):
  [substs | .Stmts // [] | ev_stmts($c + {sub: true, att: false, op: null, pi: 0, pl: 1, bg: false, neg: false, outer: []}; $s) | .segs[]];

def pipe_items: if .Cmd.Type == "BinaryCmd" and (.Cmd.Op == "|" or .Cmd.Op == "|&") and ((.Negated // false) | not) and ((.Background // false) | not) and ((.Redirs // []) | length == 0)
  then (.Cmd.X | pipe_items) + [{op: .Cmd.Op, st: .Cmd.Y}] else [{op: null, st: .}] end;

def ev_call($c; $s; $rd):
  . as $ce
  | ((.Args // []) | map(word)) as $w
  | [(.Assigns // [])[] | {n: .Name.Value, v: ((.Value // null) | word)}] as $as
  | ([$ce.Args, $ce.Assigns, $rd] | subst_segs($c; $s)) as $sub
  | if ($w | length) == 0 then
      ($s | .gitenv = (.gitenv or ([$as[].n] | any(. as $n | GITREPOENV | any(. == $n)))) | .cdpath = (.cdpath or ([$as[].n] | any(. == "CDPATH")))) as $s2
      | {segs: $sub, ok: $s2, any: $s2}
    else
      unwrap($w; 0; {wrappers: [], env: [], unknown: [], chdir: false}) as $u
      | ($w[$u.i:]) as $aw
      | ($aw | map(.s)) as $argv
      | ($aw | map(.dyn)) as $dyn
      | (if ($argv | length) > 0 and ($dyn[0] | not) then ($argv[0] | base) else null end) as $cmd
      | ([$rd[] | redir]) as $redirs
      | ([$as[] | .n + "=" + .v.s] + $u.env) as $env
      | (if ($aw | length) > 0 and $dyn[0] then
          (if ([$ce.Args[$u.i].Parts[]? | select(.Type == "CmdSubst")] | length) > 0 then ["substitution as command"] else ["dynamic command name"] end)
         else [] end) as $r0
      | ($u.unknown + $r0
         + (if $cmd == "source" or $cmd == "." then ["source"] else [] end)
         + (if ($cmd == "xargs" or $cmd == "parallel") or ($cmd == "find" and ($argv | any(. == "-exec" or . == "-execdir" or . == "-ok" or . == "-okdir"))) then ["indirect exec"] else [] end)) as $r1
      | (if $cmd == "eval" then
          (if ($aw[1:] | any(.dyn)) then {code: null, r: ["dynamic eval"]}
           else {code: {via: "eval", text: ($argv[1:] | join(" "))}, r: []} end)
         elif ($cmd != null) and (SHELLS | any(. == $cmd)) then
          (shellmode($aw)) as $m
          | if $m.mode == "c" then
              (if $m.idx == null then {code: null, r: []}
               elif $aw[$m.idx].dyn then {code: null, r: ["dynamic shell code"]}
               else {code: {via: ($cmd + " -c"), text: $aw[$m.idx].s}, r: []} end)
            elif $m.mode == "stdin" then
              ([$redirs[] | select((.fd == null or .fd == "0") and (.op == "<<" or .op == "<<-" or .op == "<<<" or .op == "<"))] | last) as $in
              | if $in == null then {code: null, r: ["shell reads stdin"]}
                elif $in.op == "<<<" then
                  (if $in.target_dynamic then {code: null, r: ["dynamic shell heredoc"]} else {code: {via: "herestring", text: $in.target}, r: []} end)
                elif $in.op == "<" then {code: null, r: ["shell reads stdin"]}
                elif $in.heredoc.body == null then {code: null, r: ["dynamic shell heredoc"]}
                else {code: {via: "heredoc", text: $in.heredoc.body}, r: []} end
            else {code: null, r: []} end
         else {code: null, r: []} end) as $nest
      | (if $cmd == "git" then gitinfo($aw; $s; $env) else null end) as $git
      | segment($c; $s; {argv: $argv, dyn: $dyn, cmd: $cmd, raw: [$w[].s], wrappers: $u.wrappers, env: $env,
          redirects: $redirs, chdir: $u.chdir, git: $git, code: $nest.code, reasons: ($r1 + $nest.r)}) as $seg
      | (($u.wrappers - ["builtin", "command"]) | length == 0) as $plain
      | (if $cmd == "cd" and $plain then
          (skipopts($aw; 1; [])) as $j
          | (if $j >= ($aw | length) then {cwd: $home, k: true, alts: [$home]}
             elif $aw[$j].dyn then {cwd: $s.cwd, k: false, alts: null}
             elif $aw[$j].s == "-" then {cwd: $s.cwd, k: false, alts: null}
             elif ($aw[$j].s | test("^(/|\\.)") | not) and $s.cdpath then {cwd: $s.cwd, k: false, alts: null}
             elif $aw[$j].s | startswith("/") then ($aw[$j].s | normpath) as $d | {cwd: $d, k: true, alts: [$d]}
             else $aw[$j].s as $rel
               | {cwd: ($rel | resolve($s.cwd)), k: $s.known,
                  alts: (if $s.alts == null then null else [$s.alts[] as $b | $rel | resolve($b)] | unique end)} end) as $t
          | ($s + {cwd: $t.cwd, known: $t.k, alts: $t.alts}) as $okst
          | {ok: $okst, any: mergest($s; $okst)}
         elif ($cmd == "pushd" or $cmd == "popd") and $plain then {ok: ($s | lost), any: ($s | lost)}
         elif $cmd == "source" or $cmd == "." then ($s | lost | .gitenv = true | .cdpath = true) as $x | {ok: $x, any: $x}
         elif $cmd == "eval" then ($s | lost | .gitenv = true | .cdpath = true) as $x | {ok: $x, any: $x}
         elif $cmd != null and ($s.funcs | any(. == $cmd)) then {ok: ($s | lost), any: ($s | lost)}
         elif $cmd == null and ($aw | length) > 0 then {ok: ($s | lost), any: ($s | lost)}
         else {ok: $s, any: $s} end) as $st
      | {segs: ([$seg] + $sub), ok: $st.ok, any: $st.any}
    end;

def ev_decl($c; $s; $rd):
  . as $d
  | ([$d.Args, $rd] | subst_segs($c; $s)) as $sub
  | [$d.Args[]? | if .Name and (.Naked | not) then {s: (.Name.Value + "=" + ((.Value // null) | word | .s)), dyn: ((.Value // null) | word | .dyn) or (.Array != null)}
                  elif .Name then {s: .Name.Value, dyn: false}
                  else (.Value | word) end] as $aw
  | ([$d.Args[]?.Name.Value // empty]) as $names
  | segment($c; $s; {argv: ([$d.Variant.Value] + [$aw[].s]), dyn: ([false] + [$aw[].dyn]), cmd: $d.Variant.Value, raw: ([$d.Variant.Value] + [$aw[].s]),
      wrappers: [], env: [], redirects: [$rd[] | redir], chdir: false, git: null, code: null, reasons: []}) as $seg
  | ($s | .gitenv = (.gitenv or ($names | any(. as $n | GITREPOENV | any(. == $n)))) | .cdpath = (.cdpath or ($names | any(. == "CDPATH")))) as $s2
  | {segs: ([$seg] + $sub), ok: $s2, any: $s2};

def ev_if($c; $s):
  ($c + {comp: "IfClause", att: false}) as $ic
  | ((.Cond // []) | ev_stmts($ic; $s)) as $cond
  | ((.Then // []) | ev_stmts($ic; $cond.ok)) as $then
  | (if .Else == null then {segs: [], ok: $cond.any, any: $cond.any}
     elif ((.Else.Cond // []) | length) > 0 then (.Else | ev_if($c; $cond.any))
     else ((.Else.Then // []) | ev_stmts($ic; $cond.any)) end) as $el
  | mergest($then.any; $el.any) as $m
  | {segs: ($cond.segs + $then.segs + $el.segs), ok: $m, any: $m};

  . as $st
  | ($st.Negated // false) as $neg
  | ($st.Background // false) as $bg
  | ($c + {neg: ($c.neg or $neg), bg: ($c.bg or $bg), att: ($c.att and ($neg | not) and ($bg | not))}) as $c2
  | ($st.Redirs // []) as $rd
  | ($c2 + {outer: ($c2.outer + [$rd[].Op])}) as $co
  | ($st.Cmd // null) as $cmd
  | (if $cmd == null then {segs: ($rd | subst_segs($c2; $s)), ok: $s, any: $s}
     elif $cmd.Type == "CallExpr" then ($cmd | ev_call($c2; $s; $rd))
     elif $cmd.Type == "DeclClause" then ($cmd | ev_decl($c2; $s; $rd))
     elif $cmd.Type == "BinaryCmd" and ($cmd.Op == "|" or $cmd.Op == "|&") then
       ($st | del(.Negated, .Background, .Redirs) | pipe_items) as $items
       | ($items | length) as $pl
       | {segs: ([range(0; $pl) as $i | $items[$i].st | ev_stmt($co + {pi: $i, pl: $pl, att: ($c2.att and $i == $pl - 1), op: (if $i == 0 then $c2.op else $items[$i].op end)}; $s) | .segs[]]
                 + ($rd | subst_segs($c2; $s))),
          ok: $s, any: $s}
     elif $cmd.Type == "BinaryCmd" and $cmd.Op == "&&" then
       ($cmd.X | ev_stmt($c2 + {att: false}; $s)) as $x
       | ($cmd.Y | ev_stmt($c2 + {op: "&&"}; $x.ok)) as $y
       | {segs: ($x.segs + $y.segs + ($rd | subst_segs($c2; $s))), ok: $y.ok, any: mergest($x.any; $y.any)}
     elif $cmd.Type == "BinaryCmd" and $cmd.Op == "||" then
       ($cmd.X | ev_stmt($c2 + {att: false}; $s)) as $x
       | ($cmd.Y | ev_stmt($c2 + {att: false, op: "||"}; $x.any)) as $y
       | ($rd | subst_segs($c2; $s)) as $rs
       | if ($cmd.Y | is_terminator) then {segs: ($x.segs + $y.segs + $rs), ok: $x.ok, any: $x.ok}
         else {segs: ($x.segs + $y.segs + $rs), ok: mergest($x.ok; $y.ok), any: mergest($x.any; $y.any)} end
     elif $cmd.Type == "Subshell" then
       ($cmd.Stmts // [] | ev_stmts($co + {subsh: true}; $s)) as $r
       | {segs: ($r.segs + ($rd | subst_segs($c2; $s))), ok: $s, any: $s}
     elif $cmd.Type == "File" then ($cmd.Stmts | ev_stmts($c2; $s))
     elif $cmd.Type == "Block" then
       ($cmd.Stmts // [] | ev_stmts($co + {grp: true}; $s)) as $r
       | {segs: ($r.segs + ($rd | subst_segs($c2; $s))), ok: $r.ok, any: $r.any}
     elif $cmd.Type == "IfClause" then
       ($cmd | ev_if($co; $s)) as $r
       | $r + {segs: ($r.segs + ($rd | subst_segs($c2; $s)))}
     elif $cmd.Type == "TimeClause" then
       ($cmd.Stmt | ev_stmt($c2 + {outer: $co.outer}; $s)) as $r
       | $r + {segs: ($r.segs + ($rd | subst_segs($c2; $s)))}
     elif $cmd.Type == "FuncDecl" then
       ($cmd.Body | ev_stmt($co + {fn: $cmd.Name.Value, att: false, op: null}; $s)) as $r
       | ($s | .funcs += [$cmd.Name.Value]) as $s2
       | {segs: ($r.segs + ($rd | subst_segs($c2; $s))), ok: $s2, any: $s2}
     else
       ($co + {comp: $cmd.Type, att: false, bg: ($co.bg or $cmd.Type == "CoprocClause")}) as $cc
       | ([$cmd.Cond, $cmd.Do, ($cmd.Items // [] | map(.Stmts // [])), (if $cmd.Stmt then [$cmd.Stmt] else null end)]
          | map(select(. != null)) | map(if length > 0 and (.[0] | type) == "array" then .[] else . end)) as $lists
       | [$lists[] | ev_stmts($cc; $s)] as $rs
       | ([$cmd | del(.Cond, .Do, .Stmt) | .Items = [(.Items // [])[] | del(.Stmts)]] | subst_segs($cc; $s)) as $ws
       | (reduce $rs[] as $r ($s; mergest(.; $r.any))) as $m
       | {segs: ([$rs[].segs[]] + $ws + ($rd | subst_segs($c2; $s))), ok: $m, any: $m}
     end) as $r
  | if $bg then $r + {ok: $s, any: $s} else $r end;

def flat($cwd; $known):
  ({Cmd: {Type: "File", Stmts: (.Stmts // [])}} | ev_stmt(
    {att: true, sub: false, subsh: false, grp: false, comp: null, fn: null, bg: false, neg: false, op: null, pi: 0, pl: 1, outer: []};
    {cwd: $cwd, known: $known, alts: (if $known then [$cwd] else null end), gitenv: false, cdpath: $cdpath, funcs: []}))
  | [.segs | to_entries[] | .value + {id: .key, depth: 0, via: null, parent: null}];

def splice($n; $f):
  . as $p
  | reduce range(0; $p | length) as $i ([];
      ($i | tostring) as $key
      | ($p[$i] | if $f[$key] then .unknown = true | .unknown_reasons += [$f[$key]] else . end) as $seg
      | length as $ni
      | . + [$seg + {id: $ni}]
      | if $n[$key] then
          ($ni + 1) as $b
          | . + [$n[$key][]
              | .id += $b
              | .parent = (if .parent == null then $ni else .parent + $b end)
              | .depth += $seg.depth + 1
              | .via = (.via // $seg.code.via)
              | .exit_code_belongs_to_command = (.exit_code_belongs_to_command and $seg.exit_code_belongs_to_command)
              | .in_substitution = (.in_substitution or $seg.in_substitution)
              | .in_function = (.in_function // $seg.in_function)
              | .in_compound = (.in_compound // $seg.in_compound)
              | .background = (.background or $seg.background)
              | .negated = (.negated or $seg.negated)
              | .in_subshell = (.in_subshell or $seg.in_subshell or $seg.code.via != "eval")
              | .in_group = (.in_group or $seg.in_group)]
        else . end);

def bit: if . then 1 else 0 end;
def list: length, .[];
def flags:
  [if .in_subshell then "S" else empty end, if .in_group then "G" else empty end,
   if .in_substitution then "X" else empty end, if .in_function != null then "F" else empty end,
   if .in_compound != null then "C" else empty end, if .background then "B" else empty end,
   if .negated then "N" else empty end, if .exit_code_belongs_to_command then "A" else empty end,
   if .unknown then "U" else empty end, if .parent != null then "P" else empty end] | join("");
def records:
  .[] | .id, (.cmd // ""), .cwd, (.cwd_known | bit), (.cwd_alts // [] | list), flags, (.via // ""), (.code.text // ""),
    ([.dynamic[] | bit | tostring] | join("")),
    (.argv | list), (.env | list), (.raw_argv | list), (.unknown_reasons | list),
    (if .git == null then 0
     else 1, (.git.sub // ""), (.git.sub_dynamic | bit), .git.cwd, (.git.cwd_known | bit), (.git.cwd_alts // [] | list),
       (.git.repo_override | bit),
       (.git.args | list), (.git.config | list) end);
def emit($status; $tool; $cmd; $cwd; $file; $segs):
  ($status, $tool, $cmd, $cwd, $file, ($segs | tojson), ($segs | records), "END") | (tostring, "\u0000");
def nul: tostring | contains("\u0000");

$ARGS.named as $o
| if $o.mode == "splice" then
    input as $p | input as $n | input as $f | ($p | splice($n; $f)) as $segs | emit("ok"; ""; ""; ""; ""; $segs)
  elif $o.mode == "hook" then
    input as $h
    | [inputs] as $rest
    | if ($h | type) != "object" or ($h.tool_input | type | IN("object", "null") | not)
        or (($h.tool_input.command // "") | type) != "string" or (($h.cwd // "") | type) != "string"
        or ($h.tool_input.command // "" | nul) or ($h.cwd // "" | nul)
      then emit("badinput"; ""; ""; ""; ""; [])
      else
        ($h.tool_name // "" | tostring) as $tool
        | ($h.tool_input.command // "") as $cmd
        | (if ($h.cwd // "") == "" then $o.pwd else $h.cwd end) as $cwd
        | ($h.tool_input.file_path // $h.tool_input.notebook_path // "" | tostring) as $file
        | if ($rest | last | .bp_shfmt_rc) != 0 or ($rest | length) != 2 then emit("parse"; $tool; $cmd; $cwd; $file; [])
          else ($rest[0] | flat($cwd; $cwd | startswith("/"))) as $segs | emit("ok"; $tool; $cmd; $cwd; $file; $segs) end
      end
  else
    [inputs] as $rest
    | if ($rest | last | .bp_shfmt_rc) != 0 or ($rest | length) != 2 then emit("parse"; ""; ""; $o.cwd; ""; [])
      else ($rest[0] | flat($o.cwd; $o.known == "true")) as $segs | emit("ok"; ""; ""; $o.cwd; ""; $segs) end
  end
