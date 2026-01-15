# Claude CLI Event Ordering Analysis

## Question
Can we remove the buffering logic in claude-client.ts and just stream events directly?

## Answer
**NO** - Buffering is necessary for parallel tool calls, but the current implementation is correct.

## Evidence

### Test 1: Sequential Tool Calls (Agents with children)
**File**: output.log

When an agent spawns and executes child tools sequentially:
```
1. Task tool_use (agent starts)
2. Bash tool_use (child tool)
3. Bash tool_result (child completes)
4. Task tool_result (agent reports done)
```

✅ **Result**: Perfectly ordered. No buffering needed.

### Test 2: Parallel Tool Calls
**File**: parallel-test.log

When Claude makes 3 parallel Glob calls:
```
CLI Output:
1. Glob tool_use #1
2. Glob tool_use #2  
3. Glob tool_use #3
4. Glob tool_result #1
5. Glob tool_result #2
6. Glob tool_result #3
```

❌ **Problem**: All tool_use events arrive first, then all tool_result events.

**Desired UI ordering**:
```
1. Glob tool_use #1
2. Glob tool_result #1
3. Glob tool_use #2
4. Glob tool_result #2
5. Glob tool_use #3
6. Glob tool_result #3
```

This requires buffering to pair each tool_use with its tool_result.

## Current Implementation (CORRECT)

The current code in `claude-client.ts`:

1. **Non-Task tools**: Buffered until both tool_use and tool_result arrive, then emitted as a pair
2. **Task tools**: Emitted immediately when they arrive (no buffering)

This is the right approach because:
- **Parallel non-Task tools** need reordering for UI clarity
- **Task tools (agents)** must NOT be buffered because child events arrive between tool_use and tool_result

## Conclusion

❌ **Do NOT simplify** - the current buffering logic is necessary and correct.

The complexity is justified:
- Handles parallel tool scrambling
- Preserves agent causality  
- Both requirements are real and validated

## Git History

- `180cb6e`: Added buffering for parallel tools (Jan 13)
- `9dcf7d9`: Fixed Task tools to not buffer (Jan 15)
- Both changes were necessary and correct
