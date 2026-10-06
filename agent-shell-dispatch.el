;;; agent-shell-dispatch.el --- Multi-agent dispatch for agent-shell -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1") (agent-shell "0.84.2"))

;;; Commentary:

;; Agent lifecycle, status resolution, and dispatch coordination.
;; Uses agent-shell-dispatch-render for task graph visualization
;; and agent-shell-dispatch-messages for inter-agent messaging.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'project)
(require 'agent-shell)
(require 'agent-shell-prompt-queue)
(require 'agent-shell-dispatch-state)
(require 'agent-shell-dispatch-render)
(require 'agent-shell-dispatch-messages)

;; Private API declarations — these symbols still exist in agent-shell v0.73.4
;; but are not part of the public contract. Pin to a known-good version and
;; re-verify on upstream updates.
(declare-function agent-shell--start "agent-shell")
(declare-function agent-shell--update-header-and-mode-line "agent-shell")
(declare-function agent-shell--make-permission-button "agent-shell")
(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell--prompt-queue-process-next "agent-shell-prompt-queue")
(defvar agent-shell--state)
(defvar agent-shell--header-cache)

;; Forward declaration — defined by `define-globalized-minor-mode' below
(defvar agent-shell-dispatch-global-mode)

;; Dummy buffer-local minor mode variable/function for `define-globalized-minor-mode'
(defvar agent-shell-dispatch--global-dummy nil)
(defun agent-shell-dispatch--global-dummy (&rest _)
  "No-op turn-on function for the globalized minor mode.")

(defgroup agent-shell-dispatch nil
  "Multi-agent dispatch for agent-shell."
  :group 'agent-shell)

(defcustom agent-shell-dispatch-track-subagents t
  "When non-nil, show the dispatcher's Claude Code subagents in the task graph.
Each Agent tool call becomes a node whose status follows the tool call."
  :type 'boolean
  :group 'agent-shell-dispatch)

(defcustom agent-shell-dispatch-auto-graph t
  "When non-nil, a shell's first Claude Code subagent starts its task graph.
Without it, subagents only appear in a graph started explicitly, e.g. by
`agent-shell-dispatch-start' or a wayfinder effort.  Needs
`agent-shell-dispatch-global-mode' and `agent-shell-dispatch-track-subagents'."
  :type 'boolean
  :group 'agent-shell-dispatch)


;; -- Permission forwarding from background agents to dispatcher buffer --

(defun agent-shell-dispatch-forward-permission (permission)
  "Forward PERMISSION from a background agent via the messaging protocol.
Returns t if the permission is fully handled (rendered in the dispatcher).
Returns nil to let agent-shell show its native permission UI in the
subagent buffer -- the SVG status icon still updates either way."
  (when-let* ((target agent-shell-dispatch--primary-buffer))
    (agent-shell-dispatch-msg-send
     (agent-shell-dispatch-msg-permission-make
      :agent-buffer (buffer-name)
      :timestamp (current-time)
      :tool-call (map-elt permission :tool-call)
      :options (map-elt permission :options)
      :respond (map-elt permission :respond))
     target)
    agent-shell-dispatch-msg-show-permissions-in-dispatcher))

;; -- Queue drain after response completion --

(defun agent-shell-dispatch--prune-stale-permissions ()
  "Remove entries from the pending permission list for idle agents.
An agent blocked on permission is still busy (its turn is suspended).
Answered permissions clear themselves, so this is a safety net for
entries whose agent buffer went away first."
  (setq agent-shell-dispatch-msg--pending-permission-agents
        (seq-filter
         (lambda (agent-buf)
           (when-let* ((buf (get-buffer agent-buf)))
             (with-current-buffer buf (shell-maker-busy))))
         agent-shell-dispatch-msg--pending-permission-agents)))

(defun agent-shell-dispatch--drain-queue (&rest _)
  "Process pending requests after a response completes.
Flushes deferred permissions first, then processes the prompt queue."
  (when (and agent-shell-dispatch--state
             (derived-mode-p 'agent-shell-mode)
             (not (shell-maker-busy)))
    (agent-shell-dispatch-msg-flush-deferred-permissions)
    (agent-shell-dispatch--prune-stale-permissions)
    (let ((buf (current-buffer)))
      (run-with-idle-timer
       0.2 nil
       (lambda ()
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (when (and (not (shell-maker-busy))
                        (derived-mode-p 'agent-shell-mode))
               (agent-shell--prompt-queue-process-next)))))))))

;; -- Session mode propagation --

(defun agent-shell-dispatch--propagate-mode-to-agents ()
  "Propagate the current buffer's session mode to all dispatch subagents.
Call from any buffer with active dispatch state."
  (when-let* ((state agent-shell-dispatch--state)
              (agents (agent-shell-dispatch-state-agents state))
              (mode-id (cdr (assq :mode-id (map-elt agent-shell--state :session)))))
    (maphash (lambda (_name info)
               (when-let* ((abuf (get-buffer (agent-shell-dispatch-agent-info-buffer info))))
                 (with-current-buffer abuf
                   (when-let* ((session (map-elt agent-shell--state :session)))
                     (map-put! session :mode-id mode-id)
                     (agent-shell--update-header-and-mode-line)))))
             agents)))

(defun agent-shell-dispatch--propagate-session-mode (orig-fn &rest args)
  "Propagate session mode changes to subagents.
:around advice for cycle/set session mode."
  (if agent-shell-dispatch--state
      (let ((on-success (car args)))
        (funcall orig-fn
                 (lambda ()
                   (when on-success (funcall on-success))
                   (agent-shell-dispatch--propagate-mode-to-agents))))
    (apply orig-fn args)))


;; -- Dispatch task graph and progress rendering --

(defun agent-shell-dispatch--agent-shell-buffer-p (buf &optional require-dispatch)
  "Return non-nil when BUF is an `agent-shell-mode' buffer.
With REQUIRE-DISPATCH, require BUF to have active dispatch state."
  (and (buffer-live-p buf)
       (with-current-buffer buf
         (and (derived-mode-p 'agent-shell-mode)
              (or (not require-dispatch)
                  agent-shell-dispatch--state)))))

(defun agent-shell-dispatch--agent-shell-buffers (&optional require-dispatch visible-only)
  "Return candidate `agent-shell-mode' buffers.
With REQUIRE-DISPATCH, only include buffers with active dispatch state.
With VISIBLE-ONLY, only include buffers visible in a live window."
  (let ((buffers (if visible-only
                     (delete-dups (mapcar #'window-buffer (window-list nil 'no-minibuf)))
                   (buffer-list))))
    (cl-remove-if-not
     (lambda (buf)
       (agent-shell-dispatch--agent-shell-buffer-p buf require-dispatch))
     buffers)))

(defun agent-shell-dispatch--project-root (&optional dir)
  "Return the project root containing DIR (default `default-directory').
Falls back to DIR itself when it is not inside a project."
  (let ((default-directory (file-name-as-directory
                            (expand-file-name (or dir default-directory)))))
    (or (when-let* ((proj (project-current)))
          (expand-file-name (project-root proj)))
        default-directory)))

(defun agent-shell-dispatch--project-dispatcher-buffer (require-dispatch)
  "Return the single dispatcher shell rooted in the caller's project, or nil.
A dispatcher is an `agent-shell-mode' buffer that was not spawned by
dispatch.  This lets emacsclient callers, whose `default-directory' is
their shell's working directory, find their own session rather than
whichever shell happens to be in the selected window.  REQUIRE-DISPATCH
is as in `agent-shell-dispatch--resolve-agent-shell-buffer'."
  (let* ((root (agent-shell-dispatch--project-root))
         (matches (cl-remove-if-not
                   (lambda (buf)
                     (with-current-buffer buf
                       (and (null agent-shell-dispatch--primary-buffer)
                            (file-equal-p (agent-shell-dispatch--project-root) root))))
                   (agent-shell-dispatch--agent-shell-buffers require-dispatch))))
    (when (= (length matches) 1)
      (car matches))))

(defun agent-shell-dispatch--resolve-agent-shell-buffer (&optional buffer require-dispatch)
  "Resolve the `agent-shell-mode' buffer associated with this request.
BUFFER may be a buffer or buffer name and wins when supplied.  Otherwise,
prefer the current buffer, then the single dispatcher shell rooted in the
caller's project, then the selected window's buffer, then a single visible
candidate, then a single live candidate.  With REQUIRE-DISPATCH, only
consider buffers with active dispatch state."
  (let ((explicit (and buffer (get-buffer buffer))))
    (cond
     ((and buffer (null explicit))
      (error "No such buffer: %S" buffer))
     ((and explicit
           (agent-shell-dispatch--agent-shell-buffer-p explicit require-dispatch))
      explicit)
     (explicit
      (error "Buffer is not an active agent-shell buffer: %s" (buffer-name explicit)))
     ((agent-shell-dispatch--agent-shell-buffer-p (current-buffer) require-dispatch)
      (current-buffer))
     ((agent-shell-dispatch--project-dispatcher-buffer require-dispatch))
     ((agent-shell-dispatch--agent-shell-buffer-p (window-buffer (selected-window))
                                                  require-dispatch)
      (window-buffer (selected-window)))
     (t
      (let ((visible (agent-shell-dispatch--agent-shell-buffers require-dispatch t)))
        (cond
         ((= (length visible) 1) (car visible))
         (t
          (let ((all (agent-shell-dispatch--agent-shell-buffers require-dispatch)))
            (cond
             ((= (length all) 1) (car all))
             (all
              (error "Ambiguous agent-shell buffers; pass one explicitly: %s"
                     (mapconcat #'buffer-name all ", ")))
             (t
              (error "No agent-shell buffer found")))))))))))

(defun agent-shell-dispatch-current-agent-buffer (&optional buffer)
  "Return the `agent-shell-mode' buffer associated with this request.
BUFFER may be a buffer or buffer name and is returned after validation.
This is intended for MCP/eval callers where `current-buffer' may be an
approval or control buffer rather than the shell that initiated the request."
  (agent-shell-dispatch--resolve-agent-shell-buffer buffer))

(defun agent-shell-dispatch-current-agent-buffer-name (&optional buffer)
  "Return the name of `agent-shell-dispatch-current-agent-buffer'."
  (buffer-name (agent-shell-dispatch-current-agent-buffer buffer)))


(defun agent-shell-dispatch-report (task-id status &optional detail)
  "Report STATUS for TASK-ID. Called by agents via MCP.
STATUS is a string: \"working\", \"done\", \"error\".
DETAIL is an optional description of current activity."
  (if agent-shell-dispatch--state
      (agent-shell-dispatch--record-report task-id status detail)
    (with-current-buffer (agent-shell-dispatch--resolve-agent-shell-buffer nil t)
      (agent-shell-dispatch--record-report task-id status detail))))





(defun agent-shell-dispatch--build-status-map ()
  "Build a status-map hash from current dispatch state.
Returns a hash of id → `agent-shell-dispatch-render-task-status', or nil."
  (agent-shell-dispatch--prune-stale-permissions)
  (when-let* ((state agent-shell-dispatch--state)
              (tasks (agent-shell-dispatch-state-tasks state))
              (statuses (agent-shell-dispatch-state-statuses state)))
    (let ((sm (make-hash-table :test 'equal)))
      (dolist (task tasks)
        (let* ((resolved (agent-shell-dispatch--resolve-status task statuses))
               (id (plist-get task :id)))
          (puthash id (agent-shell-dispatch-render-task-status-make
                       :status (agent-shell-dispatch-resolved-status-effective resolved)
                       :detail (agent-shell-dispatch-resolved-status-detail resolved))
                   sm)))
      ;; Post-pass: for each blocked agent buffer, mark only the active
      ;; (most recently reported working) task as 'permission'.
      (let ((blocked-bufs (seq-uniq
                           (append agent-shell-dispatch-msg--pending-permission-agents
                                   agent-shell-dispatch-msg--pending-input-agents))))
        (dolist (agent-buf blocked-bufs)
          (let (active-id active-time)
            (dolist (task tasks)
              (when (equal (plist-get task :agent) agent-buf)
                (let* ((id (plist-get task :id))
                       (reported (gethash id statuses))
                       (rep-status (and reported (agent-shell-dispatch-reported-status-status reported)))
                       (updated (and reported (agent-shell-dispatch-reported-status-updated reported))))
                  (when (and (eq rep-status 'working)
                             (or (null active-time) (time-less-p active-time updated)))
                    (setq active-id id active-time updated)))))
            (when active-id
              (let ((ts (gethash active-id sm)))
                (setf (agent-shell-dispatch-render-task-status-status ts) 'permission))))))
      sm)))

(defun agent-shell-dispatch--render-agents ()
  "Return a list of `agent-shell-dispatch-render-agent' structs for the renderer.
Translates internal agent-info to the renderer's protocol type."
  (when-let* ((agents (agent-shell-dispatch--get-agents)))
    (let (result)
      (maphash (lambda (_name info)
                 (push (agent-shell-dispatch-render-agent-make
                        :name (agent-shell-dispatch-agent-info-name info)
                        :busy (agent-shell-dispatch-agent-info-busy info))
                       result))
               agents)
      result)))

(defun agent-shell-dispatch--forget-blocked-agents (dispatcher-buffer)
  "Drop DISPATCHER-BUFFER's agents from the pending permission and input lists.
Agents of other dispatchers keep their entries, so restarting one graph
does not hide another graph's blocked agents."
  (let ((foreign-p (lambda (agent-buf)
                     (when-let* ((buf (get-buffer agent-buf)))
                       (not (equal dispatcher-buffer
                                   (buffer-local-value 'agent-shell-dispatch--primary-buffer
                                                       buf)))))))
    (setq agent-shell-dispatch-msg--pending-permission-agents
          (seq-filter foreign-p agent-shell-dispatch-msg--pending-permission-agents)
          agent-shell-dispatch-msg--pending-input-agents
          (seq-filter foreign-p agent-shell-dispatch-msg--pending-input-agents))))

(defun agent-shell-dispatch-start (dispatcher-buffer tasks &optional _interval)
  "Start the dispatch task graph in the `agent-shell' header.
DISPATCHER-BUFFER is the dispatcher's `agent-shell' buffer name.
TASKS is a list of plists: ((:id ID :name NAME :agent AGENT-BUF) ...).
The graph and its state belong to DISPATCHER-BUFFER, so each shell can
show its own graph."
  (with-current-buffer (get-buffer dispatcher-buffer)
    (agent-shell-dispatch-render-teardown)
    ;; A new graph starts with no dismiss handlers from the previous one
    (kill-local-variable 'agent-shell-dispatch-dismiss-hook)
    (agent-shell-dispatch--forget-blocked-agents dispatcher-buffer)
    ;; Normalize :agent — default to dispatcher buffer if missing or not a string
    (let* ((normalized (mapcar (lambda (task)
                                 (let ((agent (plist-get task :agent)))
                                   (if (stringp agent) task
                                     (plist-put (copy-sequence task) :agent dispatcher-buffer))))
                               tasks))
           (task-defs (mapcar (lambda (task)
                                (agent-shell-dispatch-render-task-make
                                 :id (plist-get task :id)
                                 :name (plist-get task :name)
                                 :depends-on (plist-get task :depends-on)))
                              normalized)))
      (setq agent-shell-dispatch--state
            (agent-shell-dispatch-state-make
             :dispatcher-buffer dispatcher-buffer
             :tasks normalized
             :statuses (make-hash-table :test 'equal)
             :agents (make-hash-table :test 'equal)
             :subagents (make-hash-table :test 'equal)
             :subscriptions (agent-shell-dispatch--subscribe (current-buffer))))
      (agent-shell-dispatch--watch-subagents)
      ;; Auto-enable global mode if not already on
      (unless agent-shell-dispatch-global-mode
        (agent-shell-dispatch-global-mode 1))
      ;; Set up render module
      (add-hook 'agent-shell-dispatch-render-teardown-hook
                #'agent-shell-dispatch--clear-state)
      (agent-shell-dispatch-render-set-tasks task-defs)
      (setq agent-shell-dispatch-render-buffer dispatcher-buffer
            agent-shell-dispatch-render-status-function #'agent-shell-dispatch--build-status-map
            agent-shell-dispatch-render-agent-activity-function #'agent-shell-dispatch--render-agents
            agent-shell-dispatch-render-header-function #'agent-shell--update-header-and-mode-line
            agent-shell-dispatch-render-reset-function (lambda ()
                                                         (when (boundp 'agent-shell--header-cache)
                                                           (setq agent-shell--header-cache nil))
                                                         (agent-shell--update-header-and-mode-line))
            agent-shell-dispatch-render-busy-p-function #'shell-maker-busy
            agent-shell-dispatch-render-dismiss-function #'agent-shell-dispatch-dismiss
            agent-shell-dispatch-render-advice-target 'agent-shell--update-header-and-mode-line)
      ;; Ensure render advice is installed — the global mode body may have run
      ;; before the advice target was set (e.g. at package load time).
      (advice-add 'agent-shell--update-header-and-mode-line
                  :after #'agent-shell-dispatch-render--extend-header)
      (unless agent-shell-dispatch-render-mode
        (agent-shell-dispatch-render-mode 'toggle)))))

(defun agent-shell-dispatch-start-current (tasks &optional buffer interval)
  "Start the dispatch task graph in the current request's agent shell.
TASKS is forwarded to `agent-shell-dispatch-start'.  BUFFER may be a buffer or
buffer name and should be supplied when multiple agent-shell buffers are open
and none is selected."
  (let ((buf (agent-shell-dispatch-current-agent-buffer buffer)))
    (with-current-buffer buf
      (agent-shell-dispatch-start (buffer-name buf) tasks interval))))

;; ── Incremental graph mutation ─────────────────────────────────────────

(defun agent-shell-dispatch--rebuild-render-ctx ()
  "Rebuild the render context from current task list.
An empty task list renders an empty graph.
Preserves all dispatch state (subscriptions, statuses, agents)."
  (when-let* ((state agent-shell-dispatch--state)
              (dispatcher-buffer (agent-shell-dispatch-state-dispatcher-buffer state)))
    (let ((task-defs (mapcar (lambda (task)
                               (agent-shell-dispatch-render-task-make
                                :id (plist-get task :id)
                                :name (plist-get task :name)
                                :depends-on (plist-get task :depends-on)))
                             (agent-shell-dispatch-state-tasks state))))
      (with-current-buffer (get-buffer dispatcher-buffer)
        (agent-shell-dispatch-render-set-tasks task-defs)))))

(defun agent-shell-dispatch-add-task (task)
  "Add TASK to the active dispatch graph without restarting.
TASK is a plist (:id ID :name NAME :depends-on (ID ...) :agent BUF).
If a task with the same :id already exists, it is replaced.
Returns non-nil on success."
  (when-let* ((state agent-shell-dispatch--state))
    (let* ((dispatcher-buffer (agent-shell-dispatch-state-dispatcher-buffer state))
           (id (plist-get task :id))
           (normalized (let ((agent (plist-get task :agent)))
                         (if (stringp agent) task
                           (plist-put (copy-sequence task) :agent dispatcher-buffer))))
           (existing (agent-shell-dispatch-state-tasks state))
           (filtered (cl-remove-if (lambda (t_) (equal (plist-get t_ :id) id)) existing)))
      (setf (agent-shell-dispatch-state-tasks state) (append filtered (list normalized)))
      (agent-shell-dispatch--rebuild-render-ctx)
      t)))

(defun agent-shell-dispatch-add-tasks (tasks)
  "Add multiple TASKS to the active dispatch graph at once.
Each element of TASKS follows the same format as `agent-shell-dispatch-add-task'.
More efficient than calling add-task in a loop — rebuilds the render context once."
  (when-let* ((state agent-shell-dispatch--state))
    (let* ((dispatcher-buffer (agent-shell-dispatch-state-dispatcher-buffer state))
           (existing (agent-shell-dispatch-state-tasks state))
           (new-ids (mapcar (lambda (task) (plist-get task :id)) tasks))
           (filtered (cl-remove-if (lambda (t_) (member (plist-get t_ :id) new-ids)) existing))
           (normalized (mapcar (lambda (task)
                                 (let ((agent (plist-get task :agent)))
                                   (if (stringp agent) task
                                     (plist-put (copy-sequence task) :agent dispatcher-buffer))))
                               tasks)))
      (setf (agent-shell-dispatch-state-tasks state) (append filtered normalized))
      (agent-shell-dispatch--rebuild-render-ctx)
      t)))

(defun agent-shell-dispatch-remove-task (task-id)
  "Remove the task with TASK-ID from the active dispatch graph.
Also removes it from other tasks' :depends-on lists and clears its status.
Returns non-nil if a task was removed."
  (when-let* ((state agent-shell-dispatch--state))
    (let* ((existing (agent-shell-dispatch-state-tasks state))
           (found (cl-find-if (lambda (t_) (equal (plist-get t_ :id) task-id)) existing)))
      (when found
        (setf (agent-shell-dispatch-state-tasks state)
              (mapcar (lambda (t_)
                        (let ((deps (plist-get t_ :depends-on)))
                          (if (member task-id deps)
                              (plist-put (copy-sequence t_) :depends-on (remove task-id deps))
                            t_)))
                      (cl-remove-if (lambda (t_) (equal (plist-get t_ :id) task-id)) existing)))
        (remhash task-id (agent-shell-dispatch-state-statuses state))
        (agent-shell-dispatch--rebuild-render-ctx)
        t))))

;; ── Claude Code subagent tracking ──────────────────────────────────────
;;
;; Subagents run inside the dispatcher's own session, so dispatch observes
;; them through agent-shell's `tool-call-update' event rather than spawning
;; them.  Verified against claude-agent-acp 0.70.0.

(defconst agent-shell-dispatch--ticket-reference-regexp
  (rx (or (seq word-boundary "ticket" (* space) (? "#") (group-n 1 (+ digit)))
          (seq "#" (group-n 1 (+ digit)))
          ;; Local wayfinder ticket file names, e.g. 03-do-the-thing.md
          (seq word-boundary (group-n 1 (+ digit)) "-" (+ (any alnum "-")) ".md")))
  "Regexp matching a wayfinder ticket reference; group 1 is the ID.")

(defun agent-shell-dispatch--subagent-call-p (tool-call)
  "Return non-nil when TOOL-CALL is a Claude Code Agent (subagent) call.
claude-agent-acp titles Agent calls by their description rather than the
tool name, so they are recognized by kind \"think\" plus a prompt in the
raw input.  The task-list tools share the kind but carry no prompt."
  (and (equal (map-elt tool-call :kind) "think")
       (map-elt (map-elt tool-call :raw-input) 'prompt)))

(defun agent-shell-dispatch--referenced-ticket (texts task-ids)
  "Return the first of TASK-IDS that one of TEXTS references as a ticket.
Bare numbers are not references; see
`agent-shell-dispatch--ticket-reference-regexp'."
  (let ((case-fold-search t))
    (cl-loop for text in texts
             thereis
             (and (stringp text)
                  (let ((pos 0) found)
                    (while (and (not found)
                                (string-match agent-shell-dispatch--ticket-reference-regexp
                                              text pos))
                      (let ((id (number-to-string
                                 (string-to-number (match-string 1 text)))))
                        (when (member id task-ids)
                          (setq found id)))
                      (setq pos (match-end 0)))
                    found)))))

(defun agent-shell-dispatch--subagent-status (tool-status background)
  "Map ACP TOOL-STATUS to a dispatch status string.
A BACKGROUND call completes as soon as the subagent launches, so it
stays working until the dispatcher's turn completes."
  (pcase tool-status
    ("failed" "error")
    ("completed" (if background "working" "done"))
    (_ "working")))

(defun agent-shell-dispatch--subagent-task (tool-call-id tool-call)
  "Return the graph task for the subagent in TOOL-CALL, keyed by TOOL-CALL-ID."
  (list :id tool-call-id
        :name (or (map-elt (map-elt tool-call :raw-input) 'description)
                  (map-elt tool-call :title))))

(defun agent-shell-dispatch--track-subagent (tool-call-id tool-call)
  "Return the tracking plist for TOOL-CALL-ID, registering it on first sight.
A subagent that references a ticket already in the graph reports to that
ticket.  Otherwise TOOL-CALL is added as a new task keyed by TOOL-CALL-ID."
  (let* ((state agent-shell-dispatch--state)
         (subagents (agent-shell-dispatch-state-subagents state)))
    (or (gethash tool-call-id subagents)
        (let* ((raw (map-elt tool-call :raw-input))
               (ticket (agent-shell-dispatch--referenced-ticket
                        (list (map-elt raw 'description) (map-elt raw 'prompt))
                        (mapcar (lambda (task) (plist-get task :id))
                                (agent-shell-dispatch-state-tasks state)))))
          (unless ticket
            (agent-shell-dispatch-add-task
             (agent-shell-dispatch--subagent-task tool-call-id tool-call)))
          (puthash tool-call-id
                   (list :task-id (or ticket tool-call-id)
                         :background (and (map-elt raw 'run_in_background) t))
                   subagents)))))

(defun agent-shell-dispatch--ensure-subagent-graph (tool-call-id tool-call)
  "Return the current shell's dispatch state, auto-starting a graph if allowed.
An auto-started graph begins with the subagent in TOOL-CALL (keyed by
TOOL-CALL-ID).  Shells spawned by dispatch never get a graph of their own."
  (or agent-shell-dispatch--state
      (when (and agent-shell-dispatch-auto-graph
                 (null agent-shell-dispatch--primary-buffer))
        (agent-shell-dispatch-start
         (buffer-name) (list (agent-shell-dispatch--subagent-task tool-call-id tool-call)))
        agent-shell-dispatch--state)))

(defun agent-shell-dispatch--on-tool-call-update (event)
  "Reflect an Agent tool call in EVENT as a dispatch task status.
The first subagent in a shell without a graph may start one; see
`agent-shell-dispatch-auto-graph'.  A subagent stops being tracked once it
reaches a final status."
  (when-let* ((agent-shell-dispatch-track-subagents)
              (data (map-elt event :data))
              (tool-call-id (map-elt data :tool-call-id))
              (tool-call (map-elt data :tool-call))
              ((agent-shell-dispatch--subagent-call-p tool-call))
              ((agent-shell-dispatch--ensure-subagent-graph tool-call-id tool-call)))
    (let* ((info (agent-shell-dispatch--track-subagent tool-call-id tool-call))
           (status (agent-shell-dispatch--subagent-status
                    (map-elt tool-call :status) (plist-get info :background))))
      (agent-shell-dispatch--record-report (plist-get info :task-id) status)
      (unless (equal status "working")
        (remhash tool-call-id
                 (agent-shell-dispatch-state-subagents agent-shell-dispatch--state))))))

(defun agent-shell-dispatch--settle-background-subagents ()
  "Mark background subagents that are still working as done.
claude-agent-acp holds the prompt turn open until the background subagents
it spawned finish, so the dispatcher's turn completion is their completion
signal.  Settled subagents stop being tracked."
  (when-let* ((state agent-shell-dispatch--state))
    (let ((subagents (agent-shell-dispatch-state-subagents state))
          (statuses (agent-shell-dispatch-state-statuses state)))
      (maphash (lambda (tool-call-id info)
                 (when (plist-get info :background)
                   (let* ((task-id (plist-get info :task-id))
                          (reported (gethash task-id statuses)))
                     (when (and reported
                                (eq 'working (agent-shell-dispatch-reported-status-status
                                              reported)))
                       (agent-shell-dispatch--record-report task-id "done")))
                   (remhash tool-call-id subagents)))
               subagents))))

(defun agent-shell-dispatch--subscribe (dispatcher-buffer)
  "Subscribe to DISPATCHER-BUFFER's graph events; return the subscription tokens.
Tool calls are watched separately, for the shell's whole life; see
`agent-shell-dispatch--watch-subagents'."
  (list (agent-shell-subscribe-to
         :shell-buffer dispatcher-buffer
         :event 'turn-complete
         :on-event (lambda (_event)
                     (agent-shell-dispatch--settle-background-subagents)
                     (agent-shell-dispatch--drain-queue)))))

(defvar-local agent-shell-dispatch--subagent-watch nil
  "Subscription token for this shell's `tool-call-update' watcher.")

(defun agent-shell-dispatch--watch-subagents ()
  "Watch the current shell's tool calls for Claude Code subagents.
The watcher outlives any one graph, so a dismissed graph can be followed
by a new one.  Idempotent."
  (unless agent-shell-dispatch--subagent-watch
    (setq agent-shell-dispatch--subagent-watch
          (agent-shell-subscribe-to
           :shell-buffer (current-buffer)
           :event 'tool-call-update
           :on-event #'agent-shell-dispatch--on-tool-call-update))))

(defun agent-shell-dispatch--unwatch-subagents ()
  "Stop watching the current shell's tool calls."
  (when agent-shell-dispatch--subagent-watch
    (ignore-errors (agent-shell-unsubscribe :subscription agent-shell-dispatch--subagent-watch))
    (setq agent-shell-dispatch--subagent-watch nil)))

(defvar agent-shell-dispatch-dismiss-hook nil
  "Hook run in a shell when its graph is dismissed, before the graph is removed.
Extensions that own a graph add to it buffer-locally to clean up after
themselves; `agent-shell-dispatch-start' clears it for each new graph.")

(defun agent-shell-dispatch-dismiss ()
  "Dismiss the current shell's task graph and forget its dispatch state.
Runs `agent-shell-dispatch-dismiss-hook' first.  Spawned agents keep running.
Called by the graph's close button."
  (run-hooks 'agent-shell-dispatch-dismiss-hook)
  (agent-shell-dispatch-render-teardown))

(defun agent-shell-dispatch-stop ()
  "Stop rendering. State preserved for mode toggle."
  (let ((buf (if agent-shell-dispatch--state
                 (current-buffer)
               (ignore-errors
                 (agent-shell-dispatch--resolve-agent-shell-buffer nil t)))))
    (when buf
      (with-current-buffer buf
        (when agent-shell-dispatch-render-mode
          (agent-shell-dispatch-render-mode 'toggle))
        ;; Safety net: clear ctx and reset header even if mode was already off
        (when agent-shell-dispatch-render--ctx
          (setq agent-shell-dispatch-render--ctx nil)
          (when agent-shell-dispatch-render-reset-function
            (ignore-errors (funcall agent-shell-dispatch-render-reset-function))))))))

;; Backward-compat aliases for old skill API
(defun agent-shell-dispatch-start-progress-polling (dispatcher-buffer agents &optional interval)
  "Backward-compat wrapper converting AGENTS alist to task plists.
DISPATCHER-BUFFER and INTERVAL are forwarded to `agent-shell-dispatch-start'."
  (agent-shell-dispatch-start dispatcher-buffer
                              (cl-loop for agent in agents
                                       for i from 1
                                       collect (list :id (format "task-%d" i)
                                                     :name (cdr agent)
                                                     :agent (car agent)))
                              interval))

(defun agent-shell-dispatch-kill-agents ()
  "Kill all dispatched agent buffers.
Also stops dispatch rendering. Returns the number of agents killed."
  (let ((agents (and agent-shell-dispatch--state
                     (agent-shell-dispatch-state-agents agent-shell-dispatch--state))))
    (agent-shell-dispatch-stop)
    (let ((kill-buffer-query-functions nil)
          (confirm-kill-processes nil)
          (count 0))
      (when agents
        (maphash (lambda (_name info)
                   (when-let* ((buf (get-buffer (agent-shell-dispatch-agent-info-buffer info))))
                     (when-let* ((proc (get-buffer-process buf)))
                       (set-process-query-on-exit-flag proc nil)
                       (delete-process proc))
                     (kill-buffer buf)
                     (cl-incf count)))
                 agents))
      count)))

;; -- Start function for spawned agents --

(defun agent-shell-dispatch-start-agent (config _arg &optional buffer-name)
  "Start a new Claude `agent-shell' for dispatch using CONFIG.
No window popup, no session prompt.  Copies the session mode from the
primary (dispatcher) buffer.  Permissions are rendered in the dispatcher buffer.
The agent shows as blocked on a permission until agent-shell reports it
answered, however that happens.
BUFFER-NAME, if provided, is incorporated into the buffer label."
  (let* ((cfg (copy-alist config))
         (primary (or agent-shell-dispatch--primary-buffer (buffer-name)))
         (mode-id (or (when-let* ((pbuf (and primary (get-buffer primary))))
                        (with-current-buffer pbuf
                          (map-nested-elt agent-shell--state '(:session :mode-id))))
                      "default"))
         (buf nil))
    (setf (map-elt cfg :default-session-mode-id)
          (lambda () mode-id))
    (setf (map-elt cfg :buffer-name)
          (if buffer-name
              (format "[agent:%s]" buffer-name)
            "[agent]"))
    (setq buf (agent-shell--start :config cfg
                                  :no-focus t
                                  :new-session t
                                  :session-strategy 'new))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq-local agent-shell-dispatch--primary-buffer primary
                    agent-shell-permission-responder-function
                    #'agent-shell-dispatch-forward-permission)
        (agent-shell-dispatch--clear-permission-lock)
        (agent-shell-subscribe-to
         :shell-buffer buf
         :event 'permission-response
         :on-event (lambda (_event) (agent-shell-dispatch--clear-permission-lock)))))
    buf))

(defun agent-shell-dispatch--clear-permission-lock ()
  "Stop showing the current agent as blocked on a permission."
  (setq agent-shell-dispatch-msg--pending-permission-agents
        (delete (buffer-name) agent-shell-dispatch-msg--pending-permission-agents)))

;; -- Multi-agent coordination --

(defun agent-shell-dispatch-spawn-agent (dir name &optional initial-message)
  "Spawn a background agent in DIR with NAME.
Submits INITIAL-MESSAGE, if provided, once the agent's session is ready.
Returns the buffer name."
  (let* ((default-directory (expand-file-name dir))
         (buf (agent-shell-dispatch-start-agent
               (agent-shell-anthropic-make-claude-code-config)
               nil name)))
    (when (and buf (buffer-live-p buf) initial-message)
      ;; Insert from the agent's own buffer so a viewport preference
      ;; doesn't redirect it; agent-shell waits for the session to be ready.
      (with-current-buffer buf
        (agent-shell-insert :text initial-message :submit t :no-focus t
                            :shell-buffer buf)))
    (when (buffer-live-p buf)
      ;; Register in dispatcher's agent set (keyed by display name)
      (when-let* ((state agent-shell-dispatch--state)
                  (agents (agent-shell-dispatch-state-agents state)))
        (puthash name
                 (agent-shell-dispatch-agent-info-make
                  :buffer (buffer-name buf)
                  :name name
                  :busy nil)
                 agents))
      (buffer-name buf))))

(defun agent-shell-dispatch-list-agents ()
  "List active `agent-shell' dispatch buffers.
Returns list of plists with :buffer and :status."
  (let (result)
    (dolist (buf (buffer-list))
      (when (and (buffer-live-p buf)
                 (with-current-buffer buf
                   (derived-mode-p 'agent-shell-mode))
                 (string-match-p "\\[agent:" (buffer-name buf)))
        (push (list :buffer (buffer-name buf)
                    :status (if (with-current-buffer buf
                                  (shell-maker-busy))
                                "busy" "ready"))
              result)))
    (nreverse result)))

(defun agent-shell-dispatch-send-to-agent (buffer-name message &optional from)
  "Send MESSAGE to the agent session in BUFFER-NAME.
FROM identifies the sender. Queues if agent is busy.
Clears any pending input-needed state for BUFFER-NAME.
Returns t on success, nil if buffer not found."
  (when (get-buffer buffer-name)
    (setq agent-shell-dispatch-msg--pending-input-agents
          (delete buffer-name agent-shell-dispatch-msg--pending-input-agents))
    (agent-shell-dispatch-msg-queue-prompt
     buffer-name
     (if from (format "[From: %s]\n\n%s" from message) message))
    t))

(defun agent-shell-dispatch-view-agent (buffer-name &optional num-lines)
  "Return the last NUM-LINES (default 100) from BUFFER-NAME."
  (when-let* ((buf (get-buffer buffer-name)))
    (with-current-buffer buf
      (let ((lines (or num-lines 100)))
        (save-excursion
          (goto-char (point-max))
          (forward-line (- lines))
          (buffer-substring-no-properties (point) (point-max)))))))

(defun agent-shell-dispatch-view-all-agents (&optional num-chars)
  "View recent output from all dispatch agents.
Returns formatted summary with last NUM-CHARS (default 500) per agent."
  (let ((chars (or num-chars 500))
        (agents (agent-shell-dispatch-list-agents)))
    (mapconcat
     (lambda (agent)
       (let* ((name (plist-get agent :buffer))
              (status (plist-get agent :status))
              (output (when-let* ((buf (get-buffer name)))
                        (with-current-buffer buf
                          (let ((s (buffer-substring-no-properties
                                    (max (point-min) (- (point-max) chars))
                                    (point-max))))
                            (string-trim s))))))
         (format "═══ %s [%s] ═══\n%s\n" name status (or output "(empty)"))))
     agents "\n")))

(defun agent-shell-dispatch-interrupt-agent (buffer-name)
  "Interrupt the agent session in BUFFER-NAME.
Returns t on success, nil if buffer not found."
  (when-let* ((buf (get-buffer buffer-name)))
    (with-current-buffer buf
      (agent-shell-interrupt t))
    t))

;; -- Global minor mode --

(define-globalized-minor-mode agent-shell-dispatch-global-mode
  agent-shell-dispatch--global-dummy
  agent-shell-dispatch--global-dummy
  "Global minor mode for agent-shell-dispatch.
Installs advice for header rendering, queue draining, session mode
propagation, and a theme change hook.  All are no-ops in buffers
without active dispatch state (buffer-local).  Also watches every
`agent-shell' buffer for Claude Code subagents; see
`agent-shell-dispatch-auto-graph'.
Enable in your config: (agent-shell-dispatch-global-mode 1)"
  :group 'agent-shell-dispatch
  (if agent-shell-dispatch-global-mode
      (progn
        (when agent-shell-dispatch-render-advice-target
          (advice-add agent-shell-dispatch-render-advice-target
                      :after #'agent-shell-dispatch-render--extend-header))
        (advice-add 'agent-shell-cycle-session-mode
                    :around #'agent-shell-dispatch--propagate-session-mode)
        (advice-add 'agent-shell-set-session-mode
                    :around #'agent-shell-dispatch--propagate-session-mode)
        (add-hook 'enable-theme-functions
                  #'agent-shell-dispatch-render--on-theme-change)
        (add-hook 'agent-shell-mode-hook #'agent-shell-dispatch--watch-subagents)
        (dolist (buf (agent-shell-dispatch--agent-shell-buffers))
          (with-current-buffer buf (agent-shell-dispatch--watch-subagents))))
    (when agent-shell-dispatch-render-advice-target
      (advice-remove agent-shell-dispatch-render-advice-target
                     #'agent-shell-dispatch-render--extend-header))
    (advice-remove 'agent-shell-cycle-session-mode
                   #'agent-shell-dispatch--propagate-session-mode)
    (advice-remove 'agent-shell-set-session-mode
                   #'agent-shell-dispatch--propagate-session-mode)
    (remove-hook 'enable-theme-functions
                 #'agent-shell-dispatch-render--on-theme-change)
    (remove-hook 'agent-shell-mode-hook #'agent-shell-dispatch--watch-subagents)
    (dolist (buf (agent-shell-dispatch--agent-shell-buffers))
      (with-current-buffer buf (agent-shell-dispatch--unwatch-subagents)))))

(provide 'agent-shell-dispatch)
;;; agent-shell-dispatch.el ends here
