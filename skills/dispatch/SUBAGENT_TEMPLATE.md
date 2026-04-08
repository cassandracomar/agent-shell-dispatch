## Your Task: TASK_NAME (id: TASK_ID)

TASK_DESCRIPTION

## Evaluating Elisp

You need to evaluate elisp in the running Emacs instance for status reporting and messaging. Use whichever method is available, in order of preference:

1. **Emacs MCP** — an `emacs_eval_elisp` tool (exact name depends on MCP server configuration)
2. **Emacs skill** — a skill like `describe` that evaluates elisp
3. **emacsclient** — `emacsclient --eval '(elisp-form)'` via Bash

## Instructions
- Work in the project directory
- Report progress:
  (agent-shell-dispatch-report "TASK_ID" "working" "description of what you're doing")
- When finished:
  (agent-shell-dispatch-report "TASK_ID" "done")
- If you hit an error:
  (agent-shell-dispatch-report "TASK_ID" "error" "what went wrong")

## Messaging (to dispatcher buffer)
Report significant milestones (phase completions, not individual steps):
  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-batch-progress-make
    :agent-buffer (buffer-name) :timestamp (current-time)
    :phase "Phase 1: Unit tests" :completed 1 :total 3)
   agent-shell-dispatch--primary-buffer)

Report batch completion:
  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-batch-completed-make
    :agent-buffer (buffer-name) :timestamp (current-time)
    :summary "All 3 phases complete, 47 tests passing")
   agent-shell-dispatch--primary-buffer)

Report errors:
  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-error-make
    :agent-buffer (buffer-name) :timestamp (current-time)
    :description "Build failed" :context "Missing dependency X")
   agent-shell-dispatch--primary-buffer)

Ask the dispatcher a question (queues automatically):
  (agent-shell-dispatch-msg-send
   (agent-shell-dispatch-msg-input-needed-make
    :agent-buffer (buffer-name) :timestamp (current-time)
    :question "Should I split this into two PRs?"
    :context "Changes touch both frontend and backend")
   agent-shell-dispatch--primary-buffer)

- If you're unsure about a design decision, implementation approach, or
  requirement — ASK. Send an input-needed message with enough context
  for the dispatcher to answer: what task you're working on, what you've
  tried, what the options are, and what you need decided.

## Acceptance Criteria
CRITERIA
