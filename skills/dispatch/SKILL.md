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
- Work can be split across 2+ independent implementation agents
- User wants parallel execution with review

There is no hard cap on agent count — parallelism is bounded by coordination overhead and the filesystem isolation story (see "Parallelism and isolation" below), not by an arbitrary number.

## Step 1: Gather Context

1. **Plan**: Read the plan file, or summarize from conversation
2. **Task list**: Extract independent tasks with clear boundaries
3. **Project state**: Current branch, recent commits, key files
4. **Elisp eval method**: Determine which method YOU have for evaluating elisp (see "Evaluating Elisp" above). Test it now — the method that works for you is the one subagents will have too. Record the exact tool name or command so you can bake it into the subagent template (replacing the generic "Evaluating Elisp" section with a concrete instruction like "Use the `mcp__emacs__emacs_eval_elisp` tool to evaluate elisp").
5. **User parameters** (ask if not specified):
   - Number of impl agents (default: 2; no hard max, but see isolation caveats)
   - Review policy: `per-task`, `batch`, or `none`

## Step 2: Register as Dispatcher and Spawn Agents

First, register your buffer as the dispatcher so permission requests render here:

```elisp
(setq agent-shell-dispatch--primary-buffer
      (agent-shell-dispatch-current-agent-buffer-name))
```

Then spawn agents. They run in the background (no popup, no prompts, acceptEdits mode). Non-edit permissions (bash, etc.) render as button dialogs in YOUR buffer — the user handles them directly. You do NOT handle permissions.

**Use short names** (e.g. "Impl-1", "Rev-1") — these appear in the agent activity column in the header, so brevity matters.

```elisp
(agent-shell-dispatch-spawn-agent
 default-directory
 "Impl-1"
 "You are Impl-1. Wait for your task assignment.")
```

`agent-shell-dispatch-spawn-agent` returns the FULL buffer name of the spawned agent (e.g. `"[agent:Impl-1] Agent @ project"`). **Capture and use this string** — do not rely on `(agent-shell-dispatch-agent-buffer "Impl-1")` to resolve it later. The short-name resolver has been unreliable in practice (returns nil). If you respawn an agent with the same short name after killing a prior instance, Emacs adds a `<N>` disambiguation suffix (e.g. `<2>`); always use the exact string returned by `spawn-agent`.

Repeat for each agent. If you need filesystem isolation (parallel impl agents writing to the same repo), see "Parallelism and isolation" below — spawn each agent in its own git worktree directory.

## Step 3: Start Task Graph, Then Assign Tasks

**CRITICAL ORDER:** start the task graph FIRST, then send tasks and report statuses. If you call `agent-shell-dispatch-report` before `agent-shell-dispatch-start`, the report is wiped when start re-initializes state and the graph will render as "not started" indefinitely.

### Step 3a: Start the task graph renderer

This enables `agent-shell-dispatch-render-mode` in the dispatcher buffer and initializes the statuses hash. Pass a list of task plists using the exact agent buffer names returned by `spawn-agent`:

```elisp
(agent-shell-dispatch-start-current
 '((:id "impl-1" :name "Task 1 description" :agent "[agent:Impl-1] Agent @ project")
   (:id "impl-2" :name "Task 2 description" :agent "[agent:Impl-2] Agent @ project")))
```

### Step 3b: Customize and send the subagent template

Read `SUBAGENT_TEMPLATE.md` (in the same directory as this skill) and customize it per task — replace TASK_NAME, TASK_ID, TASK_DESCRIPTION, CRITERIA, and `DISPATCHER_PRIMARY_BUFFER_NAME` with the actual values.

**IMPORTANT:** `agent-shell-dispatch--primary-buffer` is buffer-local to the dispatcher. Subagents evaluating elisp see it as `nil`, which makes their message-send calls fail with "stringp nil". You MUST substitute the literal string value of `(agent-shell-dispatch-current-agent-buffer-name)` (your dispatcher buffer name) into the template everywhere the subagent needs to reference the dispatcher. SUBAGENT_TEMPLATE.md uses `"DISPATCHER_PRIMARY_BUFFER_NAME"` as the placeholder — replace it with e.g. `"Codex Agent @ project"`.

```elisp
(agent-shell-dispatch-send-to-agent
 "[agent:Impl-1] Agent @ project"   ; full buffer name from spawn-agent
 "CUSTOMIZED-TEMPLATE-CONTENT"
 "dispatcher")
```

### Step 3c: Mark each task as working

After sending all tasks, report them as working:
```elisp
(agent-shell-dispatch-report "TASK-ID" "working" "brief current phase")
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
- `[Task Progress: agent (task: ID)]` — subagent announcing start / phase transition. Optional informational signal. The phase label updates in the header automatically.
- `[Task Complete: agent (task: ID)]` — subagent finished. If reviews are required (see review policy from Step 1), do NOT mark the task done yet — spawn or send a reviewer first. Only mark done after the review passes:
  ```elisp
  (agent-shell-dispatch-report "TASK-ID" "done")
  ```
- `[Task Error: agent (task: ID)]` — subagent hit an error. Investigate, then:
  ```elisp
  (agent-shell-dispatch-report "TASK-ID" "error" "reason")
  ```

### Recovery if a subagent's message fails to arrive:
MCP transport errors ("stringp nil", JSON-RPC envelope errors) can cause a subagent's `agent-shell-dispatch-msg-send` call to fail. SUBAGENT_TEMPLATE.md tells subagents to emit a `===DISPATCH-FALLBACK===` block at the end of their work in that case. If an agent's status shows `ready` (idle) but you never got a Task Complete prompt, harvest its output via `agent-shell-dispatch-view-agent` and look for the fallback block. Use it to mark the task done manually.

### Review flow:
When the review policy requires reviews:
1. On `[Task Complete]`, send a reviewer to check the implementer's work
2. If the reviewer passes → mark the task done
3. If the reviewer requests changes → send the feedback directly to the implementer via `agent-shell-dispatch-send-to-agent`. The implementer fixes and sends a new `[Task Complete]`. Re-review.
4. Repeat until the reviewer passes

**Fix-loop shortcut:** For efficiency, instruct the reviewer to send change requests directly to the implementer using `agent-shell-dispatch-send-to-agent`, and have the implementer message the reviewer back when fixed. The dispatcher only gets notified of the final pass/fail outcome — no need to relay every round-trip. When setting up a fix-loop, tell BOTH sides:
- **Reviewer:** "Send change requests directly to the implementer: `(agent-shell-dispatch-send-to-agent (agent-shell-dispatch-agent-buffer \"Impl-1\") MESSAGE)`. Wait for their reply before re-reviewing."
- **Implementer:** "After fixing, notify the reviewer: `(agent-shell-dispatch-send-to-agent (agent-shell-dispatch-agent-buffer \"Rev-1\") MESSAGE)`. Include what you changed."

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
(agent-shell-dispatch-view-agent (agent-shell-dispatch-agent-buffer "Impl-1") 200)
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

Note: killed agents may leave their buffers behind (especially if you respawned agents within the same session — old instances persist as `<N>`-suffixed buffers). Clean them up explicitly if they clutter the buffer list:

```elisp
(dolist (b (buffer-list))
  (when (string-match-p "^\\[agent:" (buffer-name b))
    (kill-buffer b)))
```

5. **Clean up worktrees** (if you created them for isolation — see below):
```bash
git worktree remove --force /tmp/up-log-<name>   # per worktree
git branch -D fix/<name>                          # if the branch is no longer needed
```

## Parallelism and isolation

When multiple impl agents touch the same repository in parallel, they will race on the working tree. Use git worktrees — one per agent — to give each agent its own filesystem.

```bash
git worktree add /tmp/project-impl-1 -b fix/area-1 base-branch
git worktree add /tmp/project-impl-2 -b fix/area-2 base-branch
```

Then spawn each agent with the corresponding directory:

```elisp
(agent-shell-dispatch-spawn-agent "/tmp/project-impl-1" "Impl-1" "You are Impl-1. Wait for task assignment.")
(agent-shell-dispatch-spawn-agent "/tmp/project-impl-2" "Impl-2" "You are Impl-2. Wait for task assignment.")
```

Each agent commits to its own branch. When all agents complete, merge the branches back into the base branch (or let the user do so). Merge conflicts between sibling branches are expected for adjacent code; resolve in the dispatcher before final integration.

Worktree isolation is REQUIRED when:
- Multiple agents edit the same files
- Multiple agents run `cargo test` / `npm test` / etc. concurrently (build artifacts collide)
- You want clean per-task branches for code review or cherry-picking

It's optional when:
- Agents work on fully separate crates/packages AND don't rebuild shared artifacts AND don't touch any shared config

When in doubt, use worktrees.

## Agent Communication Reference

| Action | Function |
|--------|----------|
| Spawn agent | `(agent-shell-dispatch-spawn-agent DIR NAME MSG)` |
| Resolve agent name | `(agent-shell-dispatch-agent-buffer NAME)` → buffer name |
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
- Use the full buffer name returned by `spawn-agent` everywhere (don't rely on `agent-shell-dispatch-agent-buffer` name resolution — it has been unreliable).
- Subagents cannot reference `agent-shell-dispatch--primary-buffer` (it's buffer-local to you). Substitute the literal dispatcher buffer name into their templates.
- Start the task graph (`agent-shell-dispatch-start`) BEFORE reporting statuses (`agent-shell-dispatch-report`). Reports made before start are wiped.
- Assign ONE task per agent at a time.
- For parallel impl agents editing the same repo, use git worktrees.
- Permissions are shown directly to the user — do NOT accept or reject on their behalf.
- Do NOT poll or check statuses in a loop — the elisp timer handles progress.
- Wait for the user to tell you when tasks are done or need intervention.
- When a subagent asks for input (queued as a prompt prefixed with
  "[Input Needed: agent-name]"), answer it using
  `agent-shell-dispatch-send-to-agent`. If the question is ambiguous or you
  lack context to answer confidently, ask the USER for clarification before
  responding to the subagent — don't guess.
- If a subagent's status goes `ready` (idle) without a Task Complete prompt, check its buffer for a `===DISPATCH-FALLBACK===` block — MCP transport errors can silently drop message sends.
- Never implement tasks yourself — coordinate.
- Always clean up agents, worktrees (if any), and stop polling when dispatch is complete.
- The user can manually toggle rendering off with `M-x agent-shell-dispatch-render-mode` if something goes wrong.
