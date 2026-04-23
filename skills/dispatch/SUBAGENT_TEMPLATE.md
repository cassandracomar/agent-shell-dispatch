## Your Task: TASK_NAME (id: TASK_ID)

TASK_DESCRIPTION

## Evaluating Elisp

DISPATCHER: Replace this section with the specific method you discovered in Step 1, e.g.:
"Use the `mcp__emacs__emacs_eval_elisp` tool to evaluate all elisp in this template."

DISPATCHER: Also substitute every literal occurrence of `"DISPATCHER_PRIMARY_BUFFER_NAME"` in this template with the exact string name of your own dispatcher buffer. The variable `agent-shell-dispatch--primary-buffer` is buffer-local to the dispatcher — subagents cannot see its value. Evaluate `(buffer-name)` in your dispatcher buffer once and paste the literal string in its place.

Fallback (if dispatcher did not replace this section):
1. **Emacs MCP** — an `emacs_eval_elisp` tool (exact name depends on MCP server configuration)
2. **Emacs skill** — a skill like `describe` that evaluates elisp
3. **emacsclient** — `emacsclient --eval '(elisp-form)'` via Bash

## Instructions
- Work in the project directory
- **Do NOT call `agent-shell-dispatch-report` or `agent-shell-dispatch-start`** — the dispatcher manages all task graph updates. Calling these yourself will corrupt the shared dispatch state.
- **Do NOT use the SendMessage tool** — it does not reach the dispatcher. Use the elisp messaging functions below instead.
- Communicate with the dispatcher via elisp messages only (see below).

## Messaging (to dispatcher buffer)

All messages are sent to the dispatcher buffer. The dispatcher manages the task graph based on your messages.

### Announce task start (REQUIRED)

As soon as you begin work, send a task-progress message so the dispatcher knows you've accepted the task and which phase you're in:
  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-task-progress-make
    :agent-buffer "EXACT-AGENT-BUFFER-NAME" :timestamp (current-time)
    :phase "Starting — reading task and gathering context")
   "DISPATCHER_PRIMARY_BUFFER_NAME")

### Report phase transitions (REQUIRED at each major phase boundary)

Every time you move to a new major phase of work (e.g. "writing failing tests", "implementing fix", "running verification", "committing"), send another task-progress so the dispatcher can see you're making progress:
  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-task-progress-make
    :agent-buffer "EXACT-AGENT-BUFFER-NAME" :timestamp (current-time)
    :phase "Writing failing test for bug #1")
   "DISPATCHER_PRIMARY_BUFFER_NAME")

Keep `:phase` short (≤60 chars) — it appears in the task graph header.

### Report counted-progress milestones (optional)

For phases with countable sub-steps (e.g. "3 of 5 tests passing"), use batch-progress instead:
  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-batch-progress-make
    :agent-buffer "EXACT-AGENT-BUFFER-NAME" :timestamp (current-time)
    :phase "Phase 1: Unit tests" :completed 1 :total 3)
   "DISPATCHER_PRIMARY_BUFFER_NAME")

### Report completion (REQUIRED at end)

When finished, send a completion message:
  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-task-completed-make
    :agent-buffer "EXACT-AGENT-BUFFER-NAME" :timestamp (current-time)
    :task-id "TASK_ID" :summary "Brief summary of what was done")
   "DISPATCHER_PRIMARY_BUFFER_NAME")

### Report errors

  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-error-make
    :agent-buffer "EXACT-AGENT-BUFFER-NAME" :timestamp (current-time)
    :task-id "TASK_ID" :description "Build failed" :context "Missing dependency X")
   "DISPATCHER_PRIMARY_BUFFER_NAME")

### Ask the dispatcher a question (queues automatically)

  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-input-needed-make
    :agent-buffer "EXACT-AGENT-BUFFER-NAME" :timestamp (current-time)
    :question "Should I split this into two PRs?"
    :context "Changes touch both frontend and backend")
   "DISPATCHER_PRIMARY_BUFFER_NAME")

- If you're unsure about a design decision, implementation approach, or
  requirement — ASK. Send an input-needed message with enough context
  for the dispatcher to answer: what task you're working on, what you've
  tried, what the options are, and what you need decided.

## Fallback if elisp messaging fails

If any of the elisp message-send calls return an error (e.g. MCP transport
error, "Wrong type argument: stringp, nil", JSON-RPC envelope error), do NOT
silently drop the message. Instead, at the very end of your work, print a
clearly-marked fallback summary in your final response so the dispatcher can
recover your status by reading your output buffer. Use this exact format:

```
===DISPATCH-FALLBACK===
TASK_ID: your-task-id-here
STATUS: completed   (or: error)
SUMMARY: one-line summary of what you did
DETAILS:
  - free-form multi-line details follow
  - include the full report / diff / whatever the dispatcher needs
===END-DISPATCH-FALLBACK===
```

The dispatcher will grep for this block in your output if it doesn't receive
your elisp completion message. One fallback block at the very end is enough —
don't emit progress fallbacks throughout.

## Acceptance Criteria
CRITERIA
