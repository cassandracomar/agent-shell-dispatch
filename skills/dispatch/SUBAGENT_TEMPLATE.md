## Your Task: TASK_NAME (id: TASK_ID)

- **Org TODO file**: TODO_FILE
- **Org TODO heading**: TODO_HEADING

TASK_DESCRIPTION

## Evaluating Elisp

DISPATCHER: Replace this section with the specific method you discovered in Step 1, e.g.:
"Use the `mcp__emacs__emacs_eval_elisp` tool to evaluate all elisp in this template."

Fallback (if dispatcher did not replace this section):
1. **Emacs MCP** — an `emacs_eval_elisp` tool (exact name depends on MCP server configuration)
2. **Emacs skill** — a skill like `describe` that evaluates elisp
3. **emacsclient** — `emacsclient --eval '(elisp-form)'` via Bash

## Org TODO Coordination

Each dispatched task corresponds to an org TODO heading in the project. The dispatcher fills in `TODO_FILE` and `TODO_HEADING` at the top of this template when assigning your task.

### Checking dependencies before starting

If the TODO heading has a `:depends-on` property linking to other TODO items, you MUST verify that all dependent TODOs are already DONE before starting work. Check via:
```
emacsclient --eval '
  (with-current-buffer (find-file-noselect "TODO_FILE" t)
    (goto-char (point-min))
    (re-search-forward "^\\*+ TODO TODO_HEADING")
    (org-entry-get nil "depends-on"))'
```
If any dependency is not DONE, send an `input-needed` message to the dispatcher explaining which dependency is blocking you.

### Marking the TODO as DONE on completion

When you have completed your task, you MUST mark the org TODO as DONE. This is IN ADDITION to sending the `task-completed` elisp message — do both. Mark the TODO first, then send the completion message:
```
emacsclient --eval '
  (with-current-buffer (find-file-noselect "TODO_FILE" t)
    (goto-char (point-min))
    (re-search-forward "^\\*+ TODO TODO_HEADING")
    (org-todo "DONE")
    (save-buffer))'
```

The `org-todo` call will automatically add a LOGBOOK entry recording the state transition from TODO to DONE with a timestamp.

## Instructions
- Work in the project directory
- **Do NOT call `agent-shell-dispatch-report` or `agent-shell-dispatch-start`** — the dispatcher manages all task graph updates. Calling these yourself will corrupt the shared dispatch state.
- **Do NOT use the SendMessage tool** — it does not reach the dispatcher. Use the elisp messaging functions below instead.
- Communicate with the dispatcher via elisp messages only (see below).

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

## Verification

Before marking your task complete, you MUST verify your changes actually work:
- **Org tangling**: If you modified org src blocks, tangle them via `emacsclient --eval` and confirm the output files are correct.
- **Elisp evaluation**: If you wrote or changed elisp, evaluate it via `emacsclient --eval` to confirm it loads without errors.
- **Tests**: If the project has tests relevant to your changes, run them and confirm they pass.
- **Commit and push**: If your changes are to a git repo or fork, stage, commit, and push them as part of completing your task. Do not leave uncommitted changes.

Only send the `task-completed` message after verification passes.

## Acceptance Criteria
CRITERIA
