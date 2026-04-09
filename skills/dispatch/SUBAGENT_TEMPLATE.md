## Your Task: TASK_NAME (id: TASK_ID)

TASK_DESCRIPTION

## Evaluating Elisp

You need to evaluate elisp in the running Emacs instance for status reporting and messaging. Use whichever method is available, in order of preference:

1. **Emacs MCP** — an `emacs_eval_elisp` tool (exact name depends on MCP server configuration)
2. **Emacs skill** — a skill like `describe` that evaluates elisp
3. **emacsclient** — `emacsclient --eval '(elisp-form)'` via Bash

## Instructions
- Work in the project directory
- **Do NOT call `agent-shell-dispatch-report` or `agent-shell-dispatch-start`** — the dispatcher manages all task graph updates. Calling these yourself will corrupt the shared dispatch state.
- Communicate with the dispatcher via messages only (see below).

## Messaging (to dispatcher buffer)

All messages are sent to the dispatcher buffer. The dispatcher manages the task graph based on your messages.

When finished, send a completion message:
  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-task-completed-make
    :agent-buffer "EXACT-AGENT-BUFFER-NAME" :timestamp (current-time)
    :task-id "TASK_ID" :summary "Brief summary of what was done")
   agent-shell-dispatch--primary-buffer)

Report significant milestones (phase completions, not individual steps):
  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-batch-progress-make
    :agent-buffer "EXACT-AGENT-BUFFER-NAME" :timestamp (current-time)
    :phase "Phase 1: Unit tests" :completed 1 :total 3)
   agent-shell-dispatch--primary-buffer)

Report errors:
  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-error-make
    :agent-buffer "EXACT-AGENT-BUFFER-NAME" :timestamp (current-time)
    :task-id "TASK_ID" :description "Build failed" :context "Missing dependency X")
   agent-shell-dispatch--primary-buffer)

Ask the dispatcher a question (queues automatically):
  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-input-needed-make
    :agent-buffer "EXACT-AGENT-BUFFER-NAME" :timestamp (current-time)
    :question "Should I split this into two PRs?"
    :context "Changes touch both frontend and backend")
   agent-shell-dispatch--primary-buffer)

- If you're unsure about a design decision, implementation approach, or
  requirement — ASK. Send an input-needed message with enough context
  for the dispatcher to answer: what task you're working on, what you've
  tried, what the options are, and what you need decided.

## Acceptance Criteria
CRITERIA
