# cc_filter.jq - JSON stream filter for Claude Code output
# ========================================================
#
# Processes claude's --output-format stream-json --verbose output
# into formatted, human-readable output.
#
# OUTPUT PREFIXES (for bash processing):
#   TEXT:...   - Streaming text (no newline added)
#   LINE:...   - Regular line (newline added)
#   SUB:...    - Subagent line (│ prefix + newline)
#

# ============================================================
# COLORS
# ============================================================
def C_RESET:   "\u001b[0m";
def C_GRAY:    "\u001b[90m";
def C_MAGENTA: "\u001b[35m";
def C_YELLOW:  "\u001b[33m";
def C_GREEN:   "\u001b[32m";
def C_BLUE:    "\u001b[34m";
def C_CYAN:    "\u001b[36m";
def C_DIM:     "\u001b[2m";

# Background colors for Edit tool
def C_BG_RED:   "\u001b[41m";
def C_BG_GREEN: "\u001b[42m";
def C_BLACK:    "\u001b[30m";

# ============================================================
# TOOL COLORS
# ============================================================
def tool_color:
    if   . == "Task"                    then C_MAGENTA
    elif . == "Bash"                    then C_YELLOW
    elif . == "Read"                    then C_GREEN
    elif . == "Write" or . == "Edit"    then C_BLUE
    elif . == "Grep" or . == "Glob"     then C_CYAN
    else C_CYAN
    end;

# ============================================================
# FORMAT: Edit tool
# ============================================================
def format_edit:
    C_BLUE + "[Edit]" + C_RESET + " " + (.input.file_path // "?") + "\n" +
    C_BLACK + C_BG_RED + (.input.old_string // "") + C_RESET + "\n" +
    C_BLACK + C_BG_GREEN + (.input.new_string // "") + C_RESET;

# ============================================================
# FORMAT: Write tool
# ============================================================
def format_write:
    C_BLUE + "[Write]" + C_RESET + " " + (.input.file_path // "?");

# ============================================================
# FORMAT: TodoWrite tool
# ============================================================
def format_todowrite:
    def status_icon:
        if . == "pending" then "⏳"
        elif . == "in_progress" then "🔄"
        elif . == "completed" then "✅"
        else "📝"
        end;

    C_MAGENTA + "[TodoWrite]" + C_RESET + " Task list\n" +
    ([.input.todos[] |
        "  " + (.status | status_icon) + " " +
        (if .status == "completed" then C_GRAY + C_DIM else "" end) +
        .content +
        (if .status == "completed" then C_RESET else "" end)
    ] | join("\n"));

# ============================================================
# FORMAT: Task tool
# ============================================================
def format_task:
    C_MAGENTA + "[Task]" + C_RESET + " " +
    (.input.subagent_type // "agent") + ": " +
    (.input.description // (.input.prompt // "")[0:60] // "...");

# ============================================================
# FORMAT: Bash tool
# ============================================================
def format_bash:
    C_YELLOW + "[Bash]" + C_RESET + " " +
    (.input.description // "command") +
    "\n    $ " + (.input.command // "?");

# ============================================================
# FORMAT: Generic tool
# ============================================================
def format_tool_generic:
    (.name | tool_color) + "[" + .name + "]" + C_RESET + " " + (.input | @json);

# ============================================================
# FORMAT: Tool dispatcher
# ============================================================
def format_tool:
    if   .name == "Edit" then format_edit
    elif .name == "Write" then format_write
    elif .name == "TodoWrite" then format_todowrite
    elif .name == "Task" then format_task
    elif .name == "Bash" then format_bash
    else format_tool_generic
    end;

# ============================================================
# FORMAT: Tool result - extract text from content array
# ============================================================
def format_result_content:
    # Input is the raw content (string or pre-parsed array)
    if type == "array" then
        # Already parsed - extract text from content blocks
        [.[] | select(.type == "text") | .text] | join("\n")
    elif type == "string" then
        # Try to parse as JSON, fallback to raw string
        . as $raw |
        try (fromjson |
            if type == "array" then
                [.[] | select(.type == "text") | .text] | join("\n")
            else $raw end
        ) catch $raw
    else
        tostring
    end;

# ============================================================
# ADD PREFIX TO EACH LINE
# ============================================================
def prefix_lines(p):
    split("\n") | map(p + .) | join("\n");

# ============================================================
# COLOR EACH LINE (for multi-line content)
# ============================================================
def color_each_line(c):
    split("\n") | map(c + . + C_RESET) | join("\n");

# ============================================================
# MAIN PROCESSING
# ============================================================

# Capture subagent status (parent_tool_use_id != null means inside subagent)
((.parent_tool_use_id != null) and (.parent_tool_use_id != "null")) as $is_sub |

# ---------------------------------------------------------
# THINKING: Block start
# ---------------------------------------------------------
if .type == "stream_event" and
   .event.type == "content_block_start" and
   .event.content_block.type == "thinking"
then
    "LINE:" + C_DIM + "[Thinking]" + C_RESET + " "

# ---------------------------------------------------------
# THINKING: Streaming delta
# ---------------------------------------------------------
elif .type == "stream_event" and
     .event.type == "content_block_delta" and
     .event.delta.type == "thinking_delta"
then
    "TEXT:" + C_DIM + .event.delta.thinking + C_RESET

# ---------------------------------------------------------
# TEXT: Content block start (for main thread, show separator)
# ---------------------------------------------------------
elif .type == "stream_event" and
     .event.type == "content_block_start" and
     .event.content_block.type == "text" and
     ($is_sub | not)
then
    "LINE:\nLINE:" + C_DIM + "━━━ Claude ━━━" + C_RESET

# ---------------------------------------------------------
# TEXT: Streaming delta (main response)
# Replace newlines with placeholder so bash read doesn't split
# ---------------------------------------------------------
elif .type == "stream_event" and
     .event.type == "content_block_delta" and
     .event.delta.type == "text_delta"
then
    "TEXT:" + (.event.delta.text | gsub("\n"; "@@NEWLINE@@"))

# ---------------------------------------------------------
# ASSISTANT: Tool calls
# ---------------------------------------------------------
elif .type == "assistant" and
     ([.message.content[] | select(.type == "tool_use")] | length > 0)
then
    [.message.content[] | select(.type == "tool_use") | format_tool] |
    if length > 0 then
        join("\n") | prefix_lines(if $is_sub then "SUB:" else "LINE:" end)
    else empty end

# ---------------------------------------------------------
# ASSISTANT: Text response
# For short responses, claude doesn't stream and sends complete text as assistant message
# Handle both main thread (non-streaming fallback) and subagents
# ---------------------------------------------------------
elif .type == "assistant" and
     ([.message.content[] | select(.type == "text")] | length > 0)
then
    [.message.content[] | select(.type == "text") | .text] |
    join("\n") |
    if $is_sub then
        # Subagent text response - color and prefix each line
        color_each_line(C_CYAN) | prefix_lines("SUB:")
    else
        # Main thread non-streaming text - show with separator
        "LINE:\nLINE:" + C_DIM + "━━━ Claude ━━━" + C_RESET + "\n" +
        prefix_lines("LINE:")
    end

# ---------------------------------------------------------
# ASSISTANT: Thinking content (non-streaming)
# ---------------------------------------------------------
elif .type == "assistant" and
     ([.message.content[] | select(.type == "thinking")] | length > 0)
then
    [.message.content[] | select(.type == "thinking") | .thinking] |
    join("\n") |
    C_DIM + "[Thinking] " + . + C_RESET |
    prefix_lines(if $is_sub then "SUB:" else "LINE:" end)

# ---------------------------------------------------------
# ASSISTANT: Unknown/unhandled content types (debugging)
# ---------------------------------------------------------
elif .type == "assistant"
then
    # Show what content types are present for debugging
    (.message.content | map(.type) | unique) as $types |
    if ($types | length) > 0 then
        "LINE:" + C_YELLOW + "[Assistant] unhandled content types: " + C_RESET +
        ($types | join(", ")) + "\n" +
        "LINE:" + C_DIM + "Full content: " + C_RESET + (.message.content | @json)
    else
        # Empty content array
        "LINE:" + C_YELLOW + "[Assistant] empty content" + C_RESET
    end

# ---------------------------------------------------------
# USER: Tool results
# Prefer tool_use_result.content (pre-parsed) over message.content
# ---------------------------------------------------------
elif .type == "user" and
     ([.message.content[] | select(.type == "tool_result")] | length > 0)
then
    # Check if we have tool_use_result with content (cleaner source)
    (if .tool_use_result.content then
        .tool_use_result.content | format_result_content
    else
        # Fallback to message.content parsing
        [.message.content[] | select(.type == "tool_result") |
         (.content // "") | tostring | format_result_content] | join("\n")
    end) |
    # Color each line and add prefix
    color_each_line(C_GRAY) |
    # Add separator after subagent results that return to main thread
    (if $is_sub then
        prefix_lines("SUB:")
    else
        # This is a top-level tool result (from subagent) - add separator before
        "\nLINE:" + C_DIM + "━━━ Response ━━━" + C_RESET + "\n" + prefix_lines("LINE:")
    end)

# ---------------------------------------------------------
# USER: Text input to subagent (prompt passthrough)
# ---------------------------------------------------------
elif .type == "user" and $is_sub and
     ([.message.content[] | select(.type == "text")] | length > 0)
then
    # This is the prompt being passed to subagent - show it dimmed
    [.message.content[] | select(.type == "text") | .text] |
    join("\n") |
    C_DIM + "→ " + . + C_RESET |
    prefix_lines("SUB:")

# ---------------------------------------------------------
# USER: Catch-all for unhandled user events (debug)
# ---------------------------------------------------------
elif .type == "user"
then
    "LINE:" + C_YELLOW + "[Debug] Unhandled user event:" + C_RESET + "\n" +
    "LINE:" + C_DIM + (. | @json) + C_RESET

# ---------------------------------------------------------
# RESULT: Final result - check for errors and structured output
# ---------------------------------------------------------
elif .type == "result" then
    # Check for error conditions indicating bad command
    # A bad slash command typically has .error set to an error message
    if .error then
        # Explicit error field present - this catches bad slash commands
        "LINE:" + C_YELLOW + "⚠ " + C_RESET + (.error | tostring)
    elif .stop_reason == "error" then
        # Stop reason indicates error
        "LINE:" + C_YELLOW + "⚠ Command failed with error" + C_RESET
    elif (.result == "" and .usage.output_tokens == 0) then
        # Silent failure - empty result with no tokens (likely invalid slash command)
        "LINE:" + C_YELLOW + "⚠ No response (possible invalid slash command)" + C_RESET
    elif .structured_output then
        # Output response line by line, then rest of structured_output as JSON
        (if .structured_output.response then
            .structured_output.response | split("\n") | map("LINE:" + .) | join("\n")
        else empty end),
        (.structured_output | del(.response) | "JSON:" + @json)
    else
        empty
    end

# ---------------------------------------------------------
# SYSTEM: Init (could show session info)
# ---------------------------------------------------------
elif .type == "system" then
    empty

# ---------------------------------------------------------
# DEFAULT: Show unknown events for debugging
# ---------------------------------------------------------
else
    # In verbose mode, show unhandled events
    if .type then
        "LINE:" + C_YELLOW + "[Debug] Unhandled event: " + C_RESET + (.type // "unknown") +
        (if .event.type then " / " + .event.type else "" end)
    else
        empty
    end
end
