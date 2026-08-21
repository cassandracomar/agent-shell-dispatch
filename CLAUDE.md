## Dispatch commands (agent-shell context)

When running inside `agent-shell` with `agent-shell-dispatch` installed, you can
interact with the dispatch system by evaluating elisp in the host Emacs via
`emacsclient`.

### Connecting to the host Emacs

Find the socket and eval:
```bash
EMACS_SOCK=$(find /var/folders -type s -name "server" 2>/dev/null | head -1)
emacsclient --socket-name="$EMACS_SOCK" -e '(elisp-form-here)'
```

### Wayfinder dispatch commands

When the user says any of the following, evaluate the corresponding elisp:

| User says | Elisp to evaluate |
|-----------|-------------------|
| "start ticket N" / "kick off N" | `(agent-shell-dispatch-wayfinder-start-ticket "N")` |
| "load effort X" / "load X" | `(progn (require 'agent-shell-dispatch-wayfinder) (agent-shell-dispatch-wayfinder-load "X"))` |
| "refresh" / "refresh graph" | `(agent-shell-dispatch-wayfinder-refresh)` |
| "unload" / "stop dispatch" | `(agent-shell-dispatch-wayfinder-unload)` |

### Status reporting

When completing work on a ticket, report status back to dispatch:
```elisp
(agent-shell-dispatch-report "TICKET-ID" "done")
```

Valid statuses: `"working"`, `"done"`, `"error"`.

### Spawning subagents

To spawn a research agent for a ticket:
```elisp
(agent-shell-dispatch-spawn-agent default-directory "AGENT-NAME" "PROMPT")
```

## Agent skills

### Issue tracker

Local markdown under `.scratch/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default label vocabulary. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout. See `docs/agents/domain.md`.
