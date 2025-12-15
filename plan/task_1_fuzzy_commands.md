# Task 1: Add Fuzzy Match Slash Command Suggestions

## Executive Summary

**What**: Suggest correct slash commands when user mistypes.

**Why**: Reduces friction - users don't need to remember exact command names.

**Approach**: Pure bash + awk Levenshtein implementation. Check if input starts with `/`, if command file doesn't exist, find closest match.

**Scope**: Only slash commands in `~/.claude/commands/`. No file path matching.

**Current State**: Unknown slash commands pass through to Claude, which may or may not understand them.

**Target State**: CLI intercepts unknown slash commands and suggests alternatives before sending to Claude.

**Steps**:
1. Add `levenshtein_distance` awk function
2. Add `find_similar_command` function
3. Hook into REPL before `run_claude`
4. Display suggestion to user

**Success Criteria**: `/snc` suggests `/sync`, `/syncc` suggests `/sync`

**Risk**: Low

**Difficulty**: Easy

---

## Implementation Phases

### Phase 1: Levenshtein Function (Easy)

Add awk-based edit distance calculation to `cc`:

```bash
# Returns edit distance between two strings
levenshtein() {
    awk 'BEGIN {
        s1=ARGV[1]; s2=ARGV[2]
        l1=length(s1); l2=length(s2)
        for(i=0;i<=l1;i++) d[i,0]=i
        for(j=0;j<=l2;j++) d[0,j]=j
        for(i=1;i<=l1;i++) {
            for(j=1;j<=l2;j++) {
                c = substr(s1,i,1)!=substr(s2,j,1)
                d[i,j] = d[i-1,j]+1
                if(d[i,j-1]+1 < d[i,j]) d[i,j]=d[i,j-1]+1
                if(d[i-1,j-1]+c < d[i,j]) d[i,j]=d[i-1,j-1]+c
            }
        }
        print d[l1,l2]
    }' "$1" "$2"
}
```

### Phase 2: Command Matcher (Easy)

```bash
find_similar_command() {
    local input="${1#/}"  # Remove leading slash
    local best="" best_dist=999

    for cmd_file in "$CLAUDE_DIR"/commands/*.md; do
        [ -f "$cmd_file" ] || continue
        local cmd=$(basename "$cmd_file" .md)
        local dist=$(levenshtein "$input" "$cmd")
        if [ "$dist" -lt "$best_dist" ] && [ "$dist" -le 3 ]; then
            best="$cmd"
            best_dist="$dist"
        fi
    done

    [ -n "$best" ] && echo "/$best"
}
```

### Phase 3: REPL Integration (Easy)

Modify main loop around line 178-181:

```bash
# Before run_claude "$input"
if [[ "$input" == /* ]]; then
    local cmd="${input%% *}"
    local cmd_name="${cmd#/}"
    if [ ! -f "$CLAUDE_DIR/commands/${cmd_name}.md" ]; then
        local suggestion=$(find_similar_command "$cmd")
        if [ -n "$suggestion" ]; then
            echo -e "\033[33mUnknown command: $cmd\033[0m"
            echo -e "Did you mean: \033[32m$suggestion\033[0m?"
            continue
        fi
    fi
fi
run_claude "$input"
```

---

## Testing Strategy

Manual testing:
- `/snc` -> suggests `/sync`
- `/syn` -> suggests `/sync`
- `/syncc` -> suggests `/sync`
- `/xxxxx` -> no suggestion (too far)
- `/sync` -> works normally (exact match)

---

## Files Changed

| File | Change |
|------|--------|
| `bin/cc` | Add ~40 LOC: levenshtein function, find_similar_command, REPL integration |

---

## Dependencies

None - pure bash/awk implementation.
