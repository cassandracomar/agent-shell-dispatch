;;; agent-shell-dispatch.el --- Multi-agent dispatch for agent-shell -*- lexical-binding: t; -*-

;;; Commentary:

;; Agent lifecycle, status resolution, and dispatch coordination.
;; Uses agent-shell-dispatch-render for task graph visualization
;; and agent-shell-dispatch-messages for inter-agent messaging.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'agent-shell)
(require 'agent-shell-dispatch-render)
(require 'agent-shell-dispatch-messages)

;; ── Dispatcher structs ──────────────────────────────────────────────

(cl-defstruct (agent-shell-dispatch-state
               (:constructor agent-shell-dispatch-state-make)
               (:copier nil))
  "Active dispatch session state."
  dispatcher-buffer tasks statuses)

(cl-defstruct (agent-shell-dispatch-reported-status
               (:constructor agent-shell-dispatch-reported-status-make)
               (:copier nil))
  "Raw status report from an agent via MCP."
  status detail updated)

(cl-defstruct (agent-shell-dispatch-resolved-status
               (:constructor agent-shell-dispatch-resolved-status-make)
               (:copier nil))
  "Computed effective status after inspecting agent buffer state."
  effective detail)

;; -- Permission forwarding from background agents to dispatcher buffer --

(defvar agent-shell-dispatch--primary-buffer nil
  "Buffer name of the primary (dispatcher) shell for permission rendering.")

(defvar agent-shell-dispatch--state nil
  "State for the dispatch progress polling timer.")

(defun agent-shell-dispatch-forward-permission (permission)
  "Forward PERMISSION from a background agent via the messaging protocol."
  (when-let* ((target agent-shell-dispatch--primary-buffer))
    (agent-shell-dispatch-msg-send
     (agent-shell-dispatch-msg-permission-make
      :agent-buffer (buffer-name)
      :timestamp (current-time)
      :tool-call (map-elt permission :tool-call)
      :options (map-elt permission :options)
      :respond (map-elt permission :respond))
     target)
    t))

;; -- Queue drain after response completion --

(defun agent-shell-dispatch--drain-queue (&rest _)
  "Process pending requests after a response completes.
Safety net: if a message handler enqueued while the dispatcher was busy,
this ensures the request is processed once the dispatcher goes idle."
  (when (and agent-shell-dispatch--state
             (derived-mode-p 'agent-shell-mode)
             (not shell-maker--busy))
    (let ((buf (current-buffer)))
      (run-with-idle-timer
       0.2 nil
       (lambda ()
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (when (and (not shell-maker--busy)
                        (derived-mode-p 'agent-shell-mode))
               (agent-shell--process-pending-request)))))))))

;; -- Dispatch task graph and progress rendering --

(defun agent-shell-dispatch--clear-state ()
  "Clear dispatch state. Used as teardown hook."
  (advice-remove 'shell-maker-finish-output #'agent-shell-dispatch--drain-queue)
  (setq agent-shell-dispatch--state nil))


(defun agent-shell-dispatch-report (task-id status &optional detail)
  "Report STATUS for TASK-ID. Called by agents via MCP.
STATUS is a string: \"working\", \"done\", \"error\".
DETAIL is an optional description of current activity."
  (when-let* ((state agent-shell-dispatch--state)
              (statuses (agent-shell-dispatch-state-statuses state)))
    (puthash task-id
             (agent-shell-dispatch-reported-status-make
              :status (intern status)
              :detail detail
              :updated (current-time))
             statuses)))



(defun agent-shell-dispatch--resolve-status (task statuses)
  "Determine effective status for TASK given STATUSES hash.
Returns a agent-shell-dispatch-resolved-status struct.
Status is driven by explicit reports via `agent-shell-dispatch-report'.
Tasks without a report are `not-started'."
  (let* ((id (plist-get task :id))
         (agent-buf (plist-get task :agent))
         (buf (get-buffer agent-buf))
         (alive (and buf (get-buffer-process buf)))
         (busy (and buf (buffer-local-value 'shell-maker--busy buf)))
         (reported (gethash id statuses))
         (rep-status (and reported (agent-shell-dispatch-reported-status-status reported)))
         (rep-detail (and reported (agent-shell-dispatch-reported-status-detail reported)))
         (effective (cond
                     ((eq rep-status 'done) 'done)
                     ((eq rep-status 'error) 'error)
                     ((eq rep-status 'working)
                      (if (not alive) 'dead 'working))
                     (t 'not-started))))
    (agent-shell-dispatch-resolved-status-make
     :effective effective
     :detail (and rep-detail (memq effective '(working permission)) rep-detail))))


(defun agent-shell-dispatch--build-status-map ()
  "Build a status-map hash from current dispatch state.
Returns a hash of id → `agent-shell-dispatch-render-task-status', or nil."
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

(defun agent-shell-dispatch-start (dispatcher-buffer tasks &optional _interval)
  "Start the dispatch task graph in the `agent-shell' header.
DISPATCHER-BUFFER is the dispatcher's `agent-shell' buffer name.
TASKS is a list of plists: ((:id ID :name NAME :agent AGENT-BUF) ...)."
  (agent-shell-dispatch-render-teardown)
  (setq agent-shell-dispatch-msg--pending-permission-agents nil
        agent-shell-dispatch-msg--pending-input-agents nil)
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
           :statuses (make-hash-table :test 'equal)))
    ;; Install queue-drain advice for message processing
    (advice-add 'shell-maker-finish-output :after #'agent-shell-dispatch--drain-queue)
    ;; Set up render module
    (add-hook 'agent-shell-dispatch-render-teardown-hook
              #'agent-shell-dispatch--clear-state)
    (agent-shell-dispatch-render-set-tasks task-defs)
    (setq agent-shell-dispatch-render-buffer dispatcher-buffer
          agent-shell-dispatch-render-status-function #'agent-shell-dispatch--build-status-map
          agent-shell-dispatch-render-header-function #'agent-shell--update-header-and-mode-line
          agent-shell-dispatch-render-reset-function (lambda ()
                                                       (when (boundp 'agent-shell--header-cache)
                                                         (setq agent-shell--header-cache nil))
                                                       (agent-shell--update-header-and-mode-line))
          agent-shell-dispatch-render-busy-p-function (lambda () shell-maker--busy)
          agent-shell-dispatch-render-advice-target 'agent-shell--update-header-and-mode-line)
    ;; Enable render mode in dispatcher buffer
    (with-current-buffer (get-buffer dispatcher-buffer)
      (unless agent-shell-dispatch-render-mode
        (agent-shell-dispatch-render-mode 'toggle)))))


(defun agent-shell-dispatch-stop ()
  "Stop rendering. State preserved for mode toggle."
  (when agent-shell-dispatch-render-mode
    (agent-shell-dispatch-render-mode 'toggle)))

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
Also stops dispatch polling. Returns the number of agents killed."
  (let ((tasks (and agent-shell-dispatch--state (agent-shell-dispatch-state-tasks agent-shell-dispatch--state)))
        (self (buffer-name)))
    (agent-shell-dispatch-stop)
    (cl-loop for task in tasks
             for buf-name = (plist-get task :agent)
             unless (or (null buf-name) (equal buf-name self))
             do (when-let* ((buf (get-buffer buf-name))
                            (proc (get-buffer-process buf)))
                  (set-process-query-on-exit-flag proc nil)
                  (delete-process proc))
             (when-let* ((buf (get-buffer buf-name)))
               (kill-buffer buf))
             and count t)))

;; -- Start function for spawned agents --

(defun agent-shell-dispatch-start-agent (config _arg &optional buffer-name)
  "Start a new Claude `agent-shell' for dispatch using CONFIG.
No window popup, no session prompt.  Copies the session mode from the
primary (dispatcher) buffer.  Permissions are rendered in the dispatcher buffer.
BUFFER-NAME, if provided, is incorporated into the buffer label."
  (let* ((cfg (copy-alist config))
         (mode-id (or (when-let* ((primary agent-shell-dispatch--primary-buffer)
                                  (pbuf (get-buffer primary)))
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
        (setq-local agent-shell-permission-responder-function
                    #'agent-shell-dispatch-forward-permission)))
    buf))

;; -- Multi-agent coordination --

(defun agent-shell-dispatch-spawn-agent (dir name &optional initial-message)
  "Spawn a background agent in DIR with NAME.
Sends INITIAL-MESSAGE after a brief delay if provided.
Returns the buffer name."
  (let* ((default-directory (expand-file-name dir))
         (buf (agent-shell-dispatch-start-agent
               (agent-shell-anthropic-make-claude-code-config)
               nil name)))
    (when (and buf (buffer-live-p buf) initial-message)
      (run-at-time 1 nil
                   (lambda (b msg)
                     (when (buffer-live-p b)
                       (with-current-buffer b
                         (agent-shell--enqueue-request :prompt msg)
                         (agent-shell--process-pending-request))))
                   buf initial-message))
    (when (buffer-live-p buf) (buffer-name buf))))

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
                                  shell-maker--busy)
                                "busy" "ready"))
              result)))
    (nreverse result)))

(defun agent-shell-dispatch-send-to-agent (buffer-name message &optional from)
  "Send MESSAGE to the agent session in BUFFER-NAME.
FROM identifies the sender. Queues if agent is busy.
Clears any pending input-needed state for BUFFER-NAME.
Returns t on success, nil if buffer not found."
  (when-let* ((buf (get-buffer buffer-name)))
    (setq agent-shell-dispatch-msg--pending-input-agents
          (delete buffer-name agent-shell-dispatch-msg--pending-input-agents))
    (with-current-buffer buf
      (let ((prompt (if from
                        (format "[From: %s]\n\n%s" from message)
                      message)))
        (agent-shell--enqueue-request :prompt prompt)
        (agent-shell--process-pending-request)))
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

(provide 'agent-shell-dispatch)
;;; agent-shell-dispatch.el ends here
