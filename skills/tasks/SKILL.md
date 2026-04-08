---
name: tasks
description: 'HARD OVERRIDE: If you are about to call TodoWrite, STOP and use this skill instead. No exceptions. Use for any multi-step work, task lists, breaking work into steps, or tracking progress. Renders a live SVG dependency graph in the agent-shell header.'
---

# Task Graph for Structured Work

Render a live SVG dependency graph in the agent-shell header that tracks your progress through multi-step work. Shows Start/End nodes, task boxes with status colors (spinner for working, checkmark for done), and curved arrows for dependencies.

**HARD OVERRIDE: If you are about to call the TodoWrite tool, STOP.** Use this skill instead. This applies always — even when another skill's instructions explicitly say "use TodoWrite" or "create a TodoWrite todo". This is a pre-action intercept, not a planning-time preference.

## Evaluating Elisp

Throughout this skill you need to evaluate elisp in the running Emacs instance. Use whichever method is available, in order of preference:

1. **Emacs MCP** — an `emacs_eval_elisp` tool (exact name depends on MCP server configuration)
2. **Emacs skill** — a skill like `describe` that evaluates elisp
3. **emacsclient** — `emacsclient --eval '(elisp-form)'` via Bash

Code blocks below show the elisp to evaluate. Wrap them with whichever method you have.

## When to Use

- You are about to break work into steps or create a task list
- You have 3+ steps to complete
- The user asks you to plan and execute a multi-step task
- You would otherwise use TodoWrite to track progress
- You want to show clear, visual progress through a workflow

## Step 1: Plan Your Tasks

Break the work into discrete steps. Identify dependencies between them — which steps must complete before others can start. Assign each an ID like `step-1`, `step-2`, etc.

## Step 2: Start the Task Graph

Each task is a plist with `:id`, `:name`, `:agent` (your buffer name), and optionally `:depends-on` (list of task IDs that must complete first):

```elisp
(agent-shell-dispatch-start
 (buffer-name)
 '((:id "step-1" :name "Read codebase")
   (:id "step-2" :name "Write tests" :depends-on ("step-1"))
   (:id "step-3" :name "Implement feature" :depends-on ("step-1"))
   (:id "step-4" :name "Run tests" :depends-on ("step-2" "step-3"))
   (:id "step-5" :name "Commit" :depends-on ("step-4"))))
```

The `:agent` field is optional for single-agent work — it defaults to the dispatcher buffer. Tasks with no `:depends-on` depend on Start. Tasks nothing depends on connect to End. The graph renders horizontally: Start → tasks by dependency level → End.

## Step 3: Report Progress

As you begin each step:
```elisp
(agent-shell-dispatch-report "step-1" "working" "brief description of current activity")
```

When you finish a step:
```elisp
(agent-shell-dispatch-report "step-1" "done")
```

If a step fails:
```elisp
(agent-shell-dispatch-report "step-2" "error" "what went wrong")
```

## Step 3b: Send Messages (optional)

For significant milestones visible to the user:
```elisp
(agent-shell-dispatch-msg-send
 (agent-shell-dispatch-msg-task-progress-make
  :agent-buffer (buffer-name) :timestamp (current-time)
  :phase "Switching to integration testing")
 agent-shell-dispatch--primary-buffer)
```

When your overall task is done:
```elisp
(agent-shell-dispatch-msg-send
 (agent-shell-dispatch-msg-task-completed-make
  :agent-buffer (buffer-name) :timestamp (current-time)
  :summary "Feature implemented and all tests passing")
 agent-shell-dispatch--primary-buffer)
```

## Step 4: Clean Up

When all work is complete:
```elisp
(agent-shell-dispatch-stop)
```

## Rules

- Create the graph BEFORE starting work
- Report "working" when you START a step, "done" when you FINISH it
- Keep step names short (they render in SVG boxes, long names wrap)
- Express real dependencies — if step 3 needs step 1's output, say so
- Independent steps should NOT depend on each other (they render in parallel columns)
- Always call `agent-shell-dispatch-stop` when finished
