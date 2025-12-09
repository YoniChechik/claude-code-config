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
# FORMAT: Task tool
# ============================================================
def format_task:
    C_MAGENTA + "[Task]" + C_RESET + " " +
    (.input.subagent_type // "agent") + ": " +
    (.input.description // (.input.prompt // "")[0:60] // "...") +
    "\n    " + (.input | @json);

# ============================================================
# FORMAT: Bash tool
# ============================================================
def format_bash:
    C_YELLOW + "[Bash]" + C_RESET + " " +
    (.input.description // "command") +
    "\n    $ " + (.input.command // "?") +
    "\n    " + (.input | @json);

# ============================================================
# FORMAT: Generic tool
# ============================================================
def format_tool_generic:
    (.name | tool_color) + "[" + .name + "]" + C_RESET + " " + (.input | @json);

# ============================================================
# FORMAT: Tool dispatcher
# ============================================================
def format_tool:
    if   .name == "Task" then format_task
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
# ASSISTANT: Text response (only from subagents)
# Main thread text is handled via streaming (content_block_delta)
# so we skip it here to avoid duplicate output
# ---------------------------------------------------------
elif .type == "assistant" and
     ([.message.content[] | select(.type == "text")] | length > 0) and
     $is_sub
then
    [.message.content[] | select(.type == "text") | .text] |
    join("\n") |
    # Subagent text response - color and prefix each line
    color_each_line(C_CYAN) | prefix_lines("SUB:")

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
# RESULT: Final result (optional - shows summary)
# ---------------------------------------------------------
elif .type == "result" then
    # Could show cost/duration here if desired
    empty

# ---------------------------------------------------------
# SYSTEM: Init (could show session info)
# ---------------------------------------------------------
elif .type == "system" then
    empty

# ---------------------------------------------------------
# DEFAULT: Ignore
# ---------------------------------------------------------
else
    empty
end
