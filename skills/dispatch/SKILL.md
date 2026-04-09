---
name: dispatch
description: 'Execute a plan with parallel agents. You become the dispatcher: spawn impl/review agents, coordinate work, and track progress with a live UI fragment.'
---

# Dispatch Plan Execution

You (the primary agent) become the dispatcher. Use elisp evaluation to call agent-shell-dispatch functions for spawning agents, sending messages, and checking status. The dispatch renderer runs as `agent-shell-dispatch-render-mode` — a minor mode that shows " Dispatch" in the mode line and can be toggled by the user.

## Evaluating Elisp

Throughout this skill you need to evaluate elisp in the running Emacs instance. Use whichever method is available, in order of preference:

1. **Emacs MCP** — an `emacs_eval_elisp` tool (exact name depends on MCP server configuration)
2. **Emacs skill** — a skill like `describe` that evaluates elisp
3. **emacsclient** — `emacsclient --eval '(elisp-form)'` via Bash

Code blocks below show the elisp to evaluate. Wrap them with whichever method you have.

## When to Use

- User has a plan (or discussed in conversation)
- Work can be split across 2-3 independent implementation agents
- User wants parallel execution with review

## Step 1: Gather Context

1. **Plan**: Read the plan file, or summarize from conversation
2. **Task list**: Extract independent tasks with clear boundaries
3. **Project state**: Current branch, recent commits, key files
4. **User parameters** (ask if not specified):
   - Number of impl agents (default: 2, max: 3)
   - Review policy: `per-task`, `batch`, or `none`

## Step 2: Register as Dispatcher and Spawn Agents

First, register your buffer as the dispatcher so permission requests render here:

```elisp
(setq agent-shell-dispatch--primary-buffer (buffer-name))
```

Then spawn agents. They run in the background (no popup, no prompts, acceptEdits mode). Non-edit permissions (bash, etc.) render as button dialogs in YOUR buffer — the user handles them directly. You do NOT handle permissions.

```elisp
(agent-shell-dispatch-spawn-agent
 default-directory
 "Impl-1"
 "You are implementation agent 1. Wait for your task assignment.")
```

Repeat for each agent. Then verify:

```elisp
(agent-shell-dispatch-list-agents)
```

Note exact buffer names.

## Step 3: Assign Tasks and Start Task Graph

Send each agent its task using the subagent template. Read `SUBAGENT_TEMPLATE.md` (in the same directory as this skill) and customize it per task — replace TASK_NAME, TASK_ID, TASK_DESCRIPTION, and CRITERIA with the actual values. Then send via:

```elisp
(agent-shell-dispatch-send-to-agent
 "EXACT-BUFFER-NAME"
 "CUSTOMIZED-TEMPLATE-CONTENT"
 "dispatcher")
```

**After sending each task, mark it as working** — you own all task graph updates:
```elisp
(agent-shell-dispatch-report "TASK-ID" "working")
```

After sending ALL tasks, start the task graph renderer. It enables `agent-shell-dispatch-render-mode` in the dispatcher buffer, rendering a live SVG dependency graph in the header. Pass a list of task plists:

```elisp
(agent-shell-dispatch-start
 (buffer-name)
 '((:id "impl-1" :name "Task 1 description" :agent "Claude Agent @ doom-config<N>")
   (:id "impl-2" :name "Task 2 description" :agent "Claude Agent @ doom-config<M>")))
```

The header graph updates at ~100ms with spinners and status colors. Geometry is cached; only status colors redraw per frame. You do NOT need to poll or check statuses.

## Step 4: Wait for User

Tell the user:

> Dispatch running. The progress fragment updates automatically. Tell me when:
> - All tasks show complete (✓) and you want me to gather results
> - An agent needs guidance and you want me to intervene
> - You want to stop (`stop`)

**Do NOT poll statuses yourself.** The elisp timer handles progress updates. Wait for the user to tell you what to do next.

### Task graph updates:
**You own all task graph updates.** Subagents do NOT call `agent-shell-dispatch-report` — they communicate via messages only. You will receive queued prompts for:
- `[Task Complete: agent (task: ID)]` — subagent finished. If reviews are required (see review policy from Step 1), do NOT mark the task done yet — spawn or send a reviewer first. Only mark done after the review passes:
  ```elisp
  (agent-shell-dispatch-report "TASK-ID" "done")
  ```
- `[Task Error: agent (task: ID)]` — subagent hit an error. Investigate, then:
  ```elisp
  (agent-shell-dispatch-report "TASK-ID" "error" "reason")
  ```

### Review flow:
When the review policy requires reviews:
1. On `[Task Complete]`, send a reviewer to check the implementer's work
2. If the reviewer passes → mark the task done
3. If the reviewer requests changes → send the feedback directly to the implementer via `agent-shell-dispatch-send-to-agent`. The implementer fixes and sends a new `[Task Complete]`. Re-review.
4. Repeat until the reviewer passes

**Fix-loop shortcut:** For efficiency, instruct the reviewer to send change requests directly to the implementer using `agent-shell-dispatch-send-to-agent`, and have the implementer message the reviewer back when fixed. The dispatcher only gets notified of the final pass/fail outcome — no need to relay every round-trip.

**Multi-stage reviews:** If a task requires multiple review stages (e.g. correctness → style → integration), define all stages upfront in the reviewer's assignment. Each stage reports its outcome. If all stages pass in one go, a single `[Task Complete]` suffices.

### Shared code changes:
If a reviewer flags an issue in shared code (used by multiple tasks), do NOT bundle the fix with the triggering task's review. Instead:
1. Create a separate mini-task for the shared fix
2. Assign it to an implementer
3. Review the shared fix independently
4. Only then continue the original task's review

### Permissions:
Permission requests from background agents render as button dialogs in your
buffer with all available options. Edit permissions with diffs include a
View (v) button that opens an ediff session. The user handles permissions
directly — you do NOT accept or reject on their behalf.

### If user says "stop":
```elisp
(progn
  (agent-shell-dispatch-stop)
  (agent-shell-dispatch-kill-agents))
```

### If user says an agent needs help:
View that agent's output and send it guidance:
```elisp
(agent-shell-dispatch-view-agent "BUFFER-NAME" 200)
```

## Step 5: Completion

**All dispatch functions must be evaluated in YOUR buffer (the dispatcher).** Dispatch state is buffer-local — calling these from a subagent buffer is a no-op.

When the user tells you all tasks are complete:

1. **Stop the task graph**:
```elisp
(agent-shell-dispatch-stop)
```

2. **Gather results**:
```elisp
(agent-shell-dispatch-view-all-agents 3000)
```

3. **Report**: completed tasks, commits, issues, next steps.

4. **Clean up agents**:
```elisp
(agent-shell-dispatch-kill-agents)
```

## Agent Communication Reference

| Action | Function |
|--------|----------|
| Spawn agent | `(agent-shell-dispatch-spawn-agent DIR NAME MSG)` |
| Send message | `(agent-shell-dispatch-send-to-agent BUF MSG FROM)` |
| List agents | `(agent-shell-dispatch-list-agents)` |
| View output | `(agent-shell-dispatch-view-agent BUF LINES)` |
| View all | `(agent-shell-dispatch-view-all-agents NUM-CHARS)` |
| Start task graph | `(agent-shell-dispatch-start BUF TASKS)` — enables `agent-shell-dispatch-render-mode` |
| Report status | `(agent-shell-dispatch-report TASK-ID STATUS DETAIL)` |
| Send msg to dispatcher | `(agent-shell-dispatch-msg-send MSG TARGET)` |
| Stop task graph | `(agent-shell-dispatch-stop)` — disables `agent-shell-dispatch-render-mode` |
| Interrupt one | `(agent-shell-dispatch-interrupt-agent BUF)` |
| Stop ALL | `(agent-shell-dispatch-kill-agents)` — also stops task graph |

## Rules

- You ARE the dispatcher. Don't start a separate session.
- ALL agent management via elisp evaluation in Emacs.
- Use `agent-shell-dispatch-list-agents` to discover buffer names.
- Assign ONE task per agent at a time.
- Permissions are shown directly to the user — do NOT accept or reject on their behalf.
- Do NOT poll or check statuses in a loop — the elisp timer handles progress.
- Wait for the user to tell you when tasks are done or need intervention.
- When a subagent asks for input (queued as a prompt prefixed with
  "[Input Needed: agent-name]"), answer it using
  `agent-shell-dispatch-send-to-agent`. If the question is ambiguous or you
  lack context to answer confidently, ask the USER for clarification before
  responding to the subagent — don't guess.
- Never implement tasks yourself — coordinate.
- Always clean up agents and stop polling when dispatch is complete.
- The user can manually toggle rendering off with `M-x agent-shell-dispatch-render-mode` if something goes wrong.
