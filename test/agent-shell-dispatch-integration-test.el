;;; agent-shell-dispatch-integration-test.el --- Integration tests -*- lexical-binding: t; -*-

;;; Commentary:

;; End-to-end tests verifying that the dispatch, render, and messages
;; modules integrate correctly.  External dependencies (agent-shell,
;; shell-maker, agent-shell-ui) are stubbed at the boundary.

;;; Code:

(setq load-prefer-newer t)

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;; ── External dependency stubs ─────────────────────────────────────────

(unless (featurep 'shell-maker)
  (defvar shell-maker-busy-val nil)
  (defun shell-maker-busy () shell-maker-busy-val)
  (provide 'shell-maker))

(unless (featurep 'agent-shell)
  (defvar agent-shell--state '((:session (:mode-id . "default"))))
  (defvar agent-shell--header-cache nil)
  (defvar agent-shell-permission-responder-function nil)
  (define-derived-mode agent-shell-mode fundamental-mode "AgentShell")
  (defun agent-shell--start (&rest _) (current-buffer))
  (defun agent-shell--update-header-and-mode-line () nil)
  (defun agent-shell--make-permission-button (&rest args)
    (or (plist-get args :text) "[btn]"))
  ;; Subscriptions are recorded so tests can emit events through the same
  ;; path agent-shell uses.  Each entry is (TOKEN BUFFER EVENT ON-EVENT).
  (defvar agent-shell-test--subscriptions nil)
  (defvar agent-shell-test--subscription-counter 0)
  (cl-defun agent-shell-subscribe-to (&key shell-buffer event on-event)
    (let ((token (cl-incf agent-shell-test--subscription-counter)))
      (push (list token shell-buffer event on-event) agent-shell-test--subscriptions)
      token))
  (cl-defun agent-shell-unsubscribe (&key subscription)
    (setq agent-shell-test--subscriptions
          (cl-remove subscription agent-shell-test--subscriptions :key #'car)))
  (defun agent-shell-interrupt (&optional _) nil)
  (defun agent-shell-diff (&rest _) nil)
  (defun agent-shell-anthropic-make-claude-code-config () nil)
  (defun agent-shell-cycle-session-mode (&optional _on-success) nil)
  (defun agent-shell-set-session-mode (&optional _on-success) nil)
  ;; Insertions are recorded as (CURRENT-BUFFER . ARGS)
  (defvar agent-shell-test--insertions nil)
  (cl-defun agent-shell-insert (&rest args)
    (push (cons (current-buffer) args) agent-shell-test--insertions)
    nil)
  (provide 'agent-shell))

(unless (featurep 'agent-shell-prompt-queue)
  (defvar agent-shell-prompt-queue--entries nil)
  (defun agent-shell--prompt-queue-enqueue (&rest args)
    (push args agent-shell-prompt-queue--entries))
  ;; Counts how often the queue was told to send, keyed by buffer
  (defvar agent-shell-test--queue-sends nil)
  (defun agent-shell--prompt-queue-process-next ()
    (push (current-buffer) agent-shell-test--queue-sends))
  (provide 'agent-shell-prompt-queue))

(unless (featurep 'agent-shell-ui)
  (cl-defun agent-shell-ui-make-fragment-model (&key namespace-id block-id
                                                      label-left label-right body)
    (list :namespace-id namespace-id :block-id block-id
          :label-left label-left :label-right label-right :body body))
  (cl-defun agent-shell-ui-update-fragment (_model &key create-new no-undo)
    (ignore create-new no-undo))
  (provide 'agent-shell-ui))

;; Now load the modules under test
(let ((dir (file-name-directory (or load-file-name (buffer-file-name)))))
  (add-to-list 'load-path (expand-file-name ".." dir)))

(require 'agent-shell-dispatch-render)
(require 'agent-shell-dispatch-messages)
(require 'agent-shell-dispatch)
(require 'agent-shell-dispatch-wayfinder)

;; ── Headless rendering stubs ──────────────────────────────────────────
;;
;; The render module uses `image-size' and `string-pixel-width' which
;; require a window-system frame.  In batch mode we pre-seed the caches
;; and stub pixel measurement so tests exercise the logic without a GUI.

(defun agent-shell-dispatch-test--stub-theme ()
  "Install a synthetic theme cache for headless testing."
  (setq agent-shell-dispatch-render--theme-cache
        (agent-shell-dispatch-render-theme-make
         :bg "#1e1e2e" :fg "#cdd6f4" :name-fg "#89b4fa" :dim "#6c7086"
         :arrow "#45475a" :font "monospace"
         :px-per-pt 1.0 :svg-text-correction 1.0
         :ascent-ratio 0.8 :descent-ratio 0.2
         :status
         (list (cons 'done       (agent-shell-dispatch-render-status-style-make :bg "#2e3a2e" :fg "#b6e63e" :icon "✓"))
               (cons 'working    (agent-shell-dispatch-render-status-style-make :bg "#3a3a2e" :fg "#e2c770" :icon "⠹"))
               (cons 'permission (agent-shell-dispatch-render-status-style-make :bg "#3a2e2e" :fg "#e74c3c" :icon "🔒"))
               (cons 'claimed    (agent-shell-dispatch-render-status-style-make :bg "#2e2e2e" :fg "#e2c770" :icon "◑"))
               (cons 'waiting    (agent-shell-dispatch-render-status-style-make :bg "#2e2e2e" :fg "#6c7086" :icon "◦"))
               (cons 'error      (agent-shell-dispatch-render-status-style-make :bg "#3a2e2e" :fg "#e74c3c" :icon "✗"))
               (cons 'not-started (agent-shell-dispatch-render-status-style-make :bg "#2e2e2e" :fg "#a0a0a0" :icon "·"))
               (cons 'dead       (agent-shell-dispatch-render-status-style-make :bg "#2e2e2e" :fg "#6c7086" :icon "?")))))
  (setq agent-shell-dispatch-render--derived-layout
        (append (list :node-h 30 :node-text-y 20 :node-pad 12
                      :agent-row-h 14 :agent-box-h 12)
                agent-shell-dispatch-render--layout)))

(defun agent-shell-dispatch-test--stub-text-width (_text _font _size)
  "Return a fixed pixel width for text measurement in tests."
  60)

(advice-add 'agent-shell-dispatch-render--text-pixel-width
            :override #'agent-shell-dispatch-test--stub-text-width)

(agent-shell-dispatch-test--stub-theme)

;; ── Test helpers ─────────────────────────────────────────────────────

(defmacro with-dispatch-buffer (&rest body)
  "Execute BODY in a temporary `agent-shell-mode' buffer with dispatch wiring.
Attaches a fake process so that `get-buffer-process' returns non-nil,
preventing tasks from resolving to `dead'."
  (declare (indent 0))
  `(let ((buf (generate-new-buffer " *test-dispatch*")))
     (unwind-protect
         (with-current-buffer buf
           (agent-shell-mode)
           (setq-local header-line-format nil)
           ;; Attach a fake process (cat blocks, simulating a live agent)
           (let ((proc (start-process "test-fake" buf "cat")))
             (set-process-query-on-exit-flag proc nil))
           ,@body)
       (when (buffer-live-p buf)
         (let ((kill-buffer-query-functions nil)
               (confirm-kill-processes nil))
           (when-let* ((proc (get-buffer-process buf)))
             (set-process-query-on-exit-flag proc nil)
             (delete-process proc))
           (kill-buffer buf))))))

(defun agent-shell-dispatch-test--emit (buffer event &optional data)
  "Deliver EVENT with DATA to subscribers of BUFFER, as agent-shell does."
  (dolist (sub agent-shell-test--subscriptions)
    (pcase-let ((`(,_token ,sub-buf ,sub-event ,on-event) sub))
      (when (and (eq sub-buf buffer)
                 (or (null sub-event) (eq sub-event event)))
        (with-current-buffer buffer
          (funcall on-event (list (cons :event event) (cons :data data))))))))

(defun agent-shell-dispatch-test--subscribed-p (buffer event)
  "Return non-nil when BUFFER has a subscription for EVENT."
  (cl-some (lambda (sub) (and (eq (nth 1 sub) buffer) (eq (nth 2 sub) event)))
           agent-shell-test--subscriptions))

(cl-defun agent-shell-dispatch-test--emit-tool-call
    (id &key (status "pending") (kind "think") title raw-input)
  "Emit a `tool-call-update' for tool call ID in the current buffer.
The tool call alist mirrors what agent-shell stores from ACP notifications."
  (agent-shell-dispatch-test--emit
   (current-buffer) 'tool-call-update
   (list (cons :tool-call-id id)
         (cons :tool-call (list (cons :title title)
                                (cons :status status)
                                (cons :kind kind)
                                (cons :raw-input raw-input))))))

(cl-defun agent-shell-dispatch-test--emit-agent-call
    (id &key (status "pending") (description "Research: caching") prompt background)
  "Emit a `tool-call-update' for an Agent tool call ID.
claude-agent-acp titles Agent calls with their description and kind `think'."
  (agent-shell-dispatch-test--emit-tool-call
   id :status status :title description
   :raw-input `((description . ,description)
                (prompt . ,(or prompt "Investigate the question."))
                (subagent_type . "general-purpose")
                (run_in_background . ,background))))

(defun agent-shell-dispatch-test--task (id)
  "Return the dispatch task plist with ID, or nil."
  (cl-find id (agent-shell-dispatch-state-tasks agent-shell-dispatch--state)
           :key (lambda (task) (plist-get task :id)) :test #'equal))

(defun agent-shell-dispatch-test--status (id)
  "Return the rendered status symbol for task ID."
  (agent-shell-dispatch-render-task-status-status
   (gethash id (agent-shell-dispatch--build-status-map))))

(defun test-tasks-simple ()
  "Return a simple three-task graph: A -> B -> C."
  (list (list :id "a" :name "Task A" :depends-on nil)
        (list :id "b" :name "Task B" :depends-on '("a"))
        (list :id "c" :name "Task C" :depends-on '("b"))))

(defun test-tasks-diamond ()
  "Return a diamond graph: A -> B, A -> C, B -> D, C -> D."
  (list (list :id "a" :name "Root" :depends-on nil)
        (list :id "b" :name "Left" :depends-on '("a"))
        (list :id "c" :name "Right" :depends-on '("a"))
        (list :id "d" :name "Join" :depends-on '("b" "c"))))

;; ── Integration tests ─────────────────────────────────────────────────

(ert-deftest dispatch-start-creates-state-and-render-ctx ()
  "Starting dispatch wires state, tasks, and render context together."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    ;; Dispatch state is populated
    (should agent-shell-dispatch--state)
    (should (= 3 (length (agent-shell-dispatch-state-tasks
                          agent-shell-dispatch--state))))
    ;; Render context was prepared
    (should agent-shell-dispatch-render--ctx)
    ;; Status function is wired
    (should (functionp agent-shell-dispatch-render-status-function))
    ;; Statuses hash is empty (no reports yet)
    (should (= 0 (hash-table-count
                  (agent-shell-dispatch-state-statuses
                   agent-shell-dispatch--state))))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-report-updates-status-map ()
  "Reporting status flows through to the render status-map."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    ;; Report task A working
    (agent-shell-dispatch-report "a" "working" "doing stuff")
    ;; Build the status map (what the renderer calls each frame)
    ;; shell-maker-busy must be non-nil for a working task to stay working
    (let ((shell-maker-busy-val t))
      (let ((sm (agent-shell-dispatch--build-status-map)))
        (should sm)
        (let ((ts (gethash "a" sm)))
          (should ts)
          (should (eq 'working (agent-shell-dispatch-render-task-status-status ts)))
          (should (equal "doing stuff" (agent-shell-dispatch-render-task-status-detail ts))))))
    ;; Report task A done
    (agent-shell-dispatch-report "a" "done")
    (let ((sm (agent-shell-dispatch--build-status-map)))
      (should (eq 'done (agent-shell-dispatch-render-task-status-status
                         (gethash "a" sm)))))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-report-unreported-tasks-are-not-started ()
  "Tasks without reports show as not-started in the status map."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (let ((sm (agent-shell-dispatch--build-status-map)))
      (should (eq 'not-started
                  (agent-shell-dispatch-render-task-status-status
                   (gethash "b" sm)))))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-render-prepare-computes-topology ()
  "Render prepare produces valid topology for a diamond graph."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-diamond))
    (let* ((ctx agent-shell-dispatch-render--ctx)
           (topo (agent-shell-dispatch-render-ctx-topo ctx))
           (leveled (agent-shell-dispatch-render-topology-leveled topo)))
      ;; Three levels: root=0, left/right=1, join=2
      (should (= 2 (agent-shell-dispatch-render-topology-max-level topo)))
      ;; All four tasks are leveled
      (should (= 4 (length leveled)))
      ;; Root is at level 0
      (let ((root (cl-find-if (lambda (t_) (equal "a" (plist-get t_ :id))) leveled)))
        (should (= 0 (plist-get root :level))))
      ;; Join is at level 2
      (let ((join (cl-find-if (lambda (t_) (equal "d" (plist-get t_ :id))) leveled)))
        (should (= 2 (plist-get join :level)))))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-render-draw-produces-svg ()
  "Drawing with a status-map produces valid SVG output."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-report "a" "done")
    (agent-shell-dispatch-report "b" "working")
    (let* ((sm (agent-shell-dispatch--build-status-map))
           (ctx agent-shell-dispatch-render--ctx)
           (svg (agent-shell-dispatch-render-draw ctx sm)))
      ;; svg-print should produce an XML string
      (let ((svg-str (with-temp-buffer (svg-print svg) (buffer-string))))
        (should (string-match-p "<svg" svg-str))
        (should (string-match-p "</svg>" svg-str))
        ;; Should contain task name text
        (should (string-match-p "Task A" svg-str))
        (should (string-match-p "Task B" svg-str))
        (should (string-match-p "Task C" svg-str))))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-message-task-completed-queues-prompt ()
  "Task-completed message handler queues a prompt in the dispatcher."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (setq agent-shell-prompt-queue--entries nil)
    (let ((msg (agent-shell-dispatch-msg-task-completed-make
                :agent-buffer "[agent:worker]"
                :timestamp (current-time)
                :task-id "a"
                :summary "Finished task A successfully.")))
      (agent-shell-dispatch-msg-handle msg (buffer-name)))
    ;; Should have queued something
    (should agent-shell-prompt-queue--entries)
    (let ((prompt (plist-get (car agent-shell-prompt-queue--entries) :prompt)))
      (should (string-match-p "Task Complete" prompt))
      (should (string-match-p "task: a" prompt))
      (should (string-match-p "Finished task A" prompt)))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-message-error-queues-prompt ()
  "Error message handler queues a prompt in the dispatcher."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (setq agent-shell-prompt-queue--entries nil)
    (let ((msg (agent-shell-dispatch-msg-error-make
                :agent-buffer "[agent:worker]"
                :timestamp (current-time)
                :task-id "b"
                :description "File not found"
                :context "Looking for config.yaml")))
      (agent-shell-dispatch-msg-handle msg (buffer-name)))
    (should agent-shell-prompt-queue--entries)
    (let ((prompt (plist-get (car agent-shell-prompt-queue--entries) :prompt)))
      (should (string-match-p "Task Error" prompt))
      (should (string-match-p "File not found" prompt))
      (should (string-match-p "config.yaml" prompt)))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-message-input-needed-tracks-agent ()
  "Input-needed message marks the agent buffer in pending-input list."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (setq agent-shell-dispatch-msg--pending-input-agents nil
          agent-shell-prompt-queue--entries nil)
    (let ((msg (agent-shell-dispatch-msg-input-needed-make
                :agent-buffer "[agent:research]"
                :timestamp (current-time)
                :question "Which API version?"
                :context nil)))
      (agent-shell-dispatch-msg-handle msg (buffer-name)))
    (should (member "[agent:research]"
                    agent-shell-dispatch-msg--pending-input-agents))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-incremental-add-task ()
  "Adding a task mid-session updates both state and render context."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    ;; Add task D depending on C
    (agent-shell-dispatch-add-task
     (list :id "d" :name "Task D" :depends-on '("c")))
    ;; State updated
    (should (= 4 (length (agent-shell-dispatch-state-tasks
                          agent-shell-dispatch--state))))
    ;; Render context re-prepared with 4 nodes
    (let* ((ctx agent-shell-dispatch-render--ctx)
           (topo (agent-shell-dispatch-render-ctx-topo ctx))
           (leveled (agent-shell-dispatch-render-topology-leveled topo)))
      (should (= 4 (length leveled)))
      ;; D is at level 3
      (let ((d (cl-find-if (lambda (t_) (equal "d" (plist-get t_ :id))) leveled)))
        (should (= 3 (plist-get d :level)))))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-incremental-remove-task ()
  "Removing a task cleans up status, graph, and dependency edges."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    ;; Report B as working so it has a status entry
    (agent-shell-dispatch-report "b" "working")
    ;; Remove B
    (should (agent-shell-dispatch-remove-task "b"))
    ;; Only A and C remain
    (should (= 2 (length (agent-shell-dispatch-state-tasks
                          agent-shell-dispatch--state))))
    ;; B's status is gone
    (should-not (gethash "b" (agent-shell-dispatch-state-statuses
                              agent-shell-dispatch--state)))
    ;; C no longer depends on B
    (let ((c (cl-find-if (lambda (t_) (equal "c" (plist-get t_ :id)))
                          (agent-shell-dispatch-state-tasks
                           agent-shell-dispatch--state))))
      (should-not (member "b" (plist-get c :depends-on))))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-stop-clears-render-mode ()
  "Stopping dispatch disables render mode and clears context."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (should agent-shell-dispatch-render--ctx)
    (agent-shell-dispatch-stop)
    (should-not agent-shell-dispatch-render--ctx)))

(ert-deftest dispatch-permission-marks-status-permission ()
  "A pending permission on a working task shows as 'permission' in the status map."
  (with-dispatch-buffer
    (let ((agent-buf (generate-new-buffer "[agent:worker]")))
      (unwind-protect
          (progn
            (agent-shell-dispatch-start (buffer-name)
                                        (list (list :id "t1" :name "Task 1"
                                                    :depends-on nil
                                                    :agent (buffer-name agent-buf))))
            ;; Report working
            (agent-shell-dispatch-report "t1" "working")
            ;; Simulate a pending permission from that agent
            (setq agent-shell-dispatch-msg--pending-permission-agents
                  (list (buffer-name agent-buf)))
            ;; Agent must appear busy for prune not to clear it
            (let ((shell-maker-busy-val t))
              (let ((sm (agent-shell-dispatch--build-status-map)))
                (should (eq 'permission
                            (agent-shell-dispatch-render-task-status-status
                             (gethash "t1" sm))))))
            (agent-shell-dispatch-stop))
        (kill-buffer agent-buf)))))

(ert-deftest dispatch-resolve-status-dead-when-process-gone ()
  "A working task with a dead buffer process resolves to 'dead'."
  (with-dispatch-buffer
    (let* ((agent-buf (generate-new-buffer " *test-agent*")))
      (unwind-protect
          (progn
            (agent-shell-dispatch-start
             (buffer-name)
             (list (list :id "t1" :name "Task 1"
                         :depends-on nil
                         :agent (buffer-name agent-buf))))
            ;; Report working
            (agent-shell-dispatch-report "t1" "working")
            ;; Buffer exists but has no process — simulates crashed agent
            (let ((sm (agent-shell-dispatch--build-status-map)))
              (should (eq 'dead
                          (agent-shell-dispatch-render-task-status-status
                           (gethash "t1" sm))))))
        (when (buffer-live-p agent-buf)
          (kill-buffer agent-buf))))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-batch-add-tasks ()
  "Adding multiple tasks at once rebuilds render context only once."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (let ((rebuild-count 0))
      (advice-add 'agent-shell-dispatch--rebuild-render-ctx
                  :before (lambda () (cl-incf rebuild-count))
                  '((name . test-counter)))
      (unwind-protect
          (progn
            (agent-shell-dispatch-add-tasks
             (list (list :id "d" :name "Task D" :depends-on '("c"))
                   (list :id "e" :name "Task E" :depends-on '("c"))))
            ;; Rebuilt exactly once despite two tasks added
            (should (= 1 rebuild-count))
            ;; Both tasks present
            (should (= 5 (length (agent-shell-dispatch-state-tasks
                                  agent-shell-dispatch--state)))))
        (advice-remove 'agent-shell-dispatch--rebuild-render-ctx 'test-counter)))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-full-lifecycle ()
  "Full lifecycle: start, work, complete, error, stop."
  (with-dispatch-buffer
    ;; Start
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    ;; Work task A
    (agent-shell-dispatch-report "a" "working" "parsing input")
    (let ((shell-maker-busy-val t))
      (let ((sm (agent-shell-dispatch--build-status-map)))
        (should (eq 'working (agent-shell-dispatch-render-task-status-status
                              (gethash "a" sm))))))
    ;; Complete task A
    (agent-shell-dispatch-report "a" "done")
    (let ((sm (agent-shell-dispatch--build-status-map)))
      (should (eq 'done (agent-shell-dispatch-render-task-status-status
                         (gethash "a" sm)))))
    ;; Work then error on task B
    (let ((shell-maker-busy-val t))
      (agent-shell-dispatch-report "b" "working"))
    (agent-shell-dispatch-report "b" "error")
    (let ((sm (agent-shell-dispatch--build-status-map)))
      (should (eq 'error (agent-shell-dispatch-render-task-status-status
                          (gethash "b" sm)))))
    ;; Stop
    (agent-shell-dispatch-stop)
    (should-not agent-shell-dispatch-render--ctx)))

;; ── Wayfinder integration (local backend, no shell dependencies) ─────

(ert-deftest wayfinder-tickets-to-tasks-converts-correctly ()
  "Wayfinder ticket-to-task conversion produces valid dispatch plists."
  (let ((tickets (list (list :id "1" :name "Do thing"
                             :type "task" :status nil :blocked-by nil)
                       (list :id "2" :name "Research Q"
                             :type "research" :status "claimed"
                             :blocked-by '("1")))))
    (let ((tasks (agent-shell-dispatch-wayfinder--tickets-to-tasks tickets)))
      (should (= 2 (length tasks)))
      ;; First task has type icon prefix
      (should (string-match-p "\\[T\\]" (plist-get (car tasks) :name)))
      ;; Second task depends on first
      (should (equal '("1") (plist-get (cadr tasks) :depends-on)))
      ;; Research type icon
      (should (string-match-p "\\[R\\]" (plist-get (cadr tasks) :name))))))

(ert-deftest wayfinder-status-mapping ()
  "Wayfinder maps tracker statuses to dispatch statuses correctly."
  (should (equal "done"
                 (agent-shell-dispatch-wayfinder--ticket-dispatch-status
                  '(:id "1" :status "resolved"))))
  (should (equal "claimed"
                 (agent-shell-dispatch-wayfinder--ticket-dispatch-status
                  '(:id "2" :status "claimed"))))
  (should (equal "waiting"
                 (agent-shell-dispatch-wayfinder--ticket-dispatch-status
                  '(:id "3" :status nil)))))

(defun test-parse-local-ticket (content)
  "Parse CONTENT as local ticket file 03-do-the-thing.md and return its plist."
  (let ((dir (make-temp-file "wayfinder-test-" t)))
    (unwind-protect
        (let ((file (expand-file-name "03-do-the-thing.md" dir)))
          (with-temp-file file (insert content))
          (agent-shell-dispatch-wayfinder--local-parse-ticket file))
      (delete-directory dir t))))

(ert-deftest wayfinder-local-parse-ticket ()
  "Local backend parses markdown ticket files correctly."
  (let ((ticket (test-parse-local-ticket
                 "Type: grilling\nStatus: claimed\nBlocked by: 1, 2\n\n# Do the thing\n\nBody text.")))
    (should ticket)
    (should (equal "3" (plist-get ticket :id)))
    (should (equal "do the thing" (plist-get ticket :name)))
    (should (equal "grilling" (plist-get ticket :type)))
    (should (equal "claimed" (plist-get ticket :status)))
    (should (equal '("1" "2") (plist-get ticket :blocked-by)))))

(ert-deftest wayfinder-local-parse-blocked-by-prose-means-unblocked ()
  "A Blocked by line with no ticket numbers yields no dependencies."
  (should-not (plist-get (test-parse-local-ticket
                          "Type: task\nBlocked by: None (can start immediately)\n")
                         :blocked-by)))

(ert-deftest wayfinder-local-parse-blocked-by-ignores-prose-around-ids ()
  "Ticket numbers are extracted from a Blocked by line mixed with prose."
  (should (equal '("1" "12")
                 (plist-get (test-parse-local-ticket
                             "Type: task\nBlocked by: 01 (audit), 12\n")
                            :blocked-by))))

(ert-deftest wayfinder-github-parse-blocked-by-prose-means-unblocked ()
  "A GitHub Blocked by line with no issue numbers yields no dependencies."
  (should-not (agent-shell-dispatch-wayfinder--github-parse-blocked-by
               "Blocked by: None (can start immediately)\n"))
  (should (equal '("4" "7")
                 (agent-shell-dispatch-wayfinder--github-parse-blocked-by
                  "Intro\nBlocked by: #4, #7\n"))))

(ert-deftest dispatch-resolve-prefers-dispatcher-in-callers-project ()
  "Resolution from a non-shell buffer picks the dispatcher rooted in the
caller's directory over the selected window's shell and spawned agents."
  (let* ((mine (file-name-as-directory (make-temp-file "proj-mine-" t)))
         (other (file-name-as-directory (make-temp-file "proj-other-" t)))
         (make-shell (lambda (name dir &optional primary)
                       (with-current-buffer (generate-new-buffer name)
                         (agent-shell-mode)
                         (setq default-directory dir)
                         (setq-local agent-shell-dispatch--primary-buffer primary)
                         (current-buffer))))
         (dispatcher (funcall make-shell " *shell-mine*" mine))
         (spawned (funcall make-shell " *agent-mine*" mine " *shell-mine*"))
         (foreign (funcall make-shell " *shell-other*" other)))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) foreign)
          (with-temp-buffer
            (setq default-directory mine)
            (should (eq dispatcher
                        (agent-shell-dispatch--resolve-agent-shell-buffer)))))
      (mapc #'kill-buffer (list dispatcher spawned foreign))
      (delete-directory mine t)
      (delete-directory other t))))

(ert-deftest wayfinder-diff-and-apply-adds-and-removes ()
  "Incremental diff correctly adds new and removes old tickets."
  (with-dispatch-buffer
    (agent-shell-dispatch-start
     (buffer-name)
     (list (list :id "1" :name "[T] First" :depends-on nil)
           (list :id "2" :name "[T] Second" :depends-on '("1"))))
    ;; Simulate wayfinder state
    (setq agent-shell-dispatch-wayfinder--known-ids '("1" "2"))
    ;; Simulate tickets changing: 2 gone, 3 added
    (let ((new-tickets (list (list :id "1" :name "First"
                                   :type "task" :status "resolved"
                                   :blocked-by nil)
                             (list :id "3" :name "Third"
                                   :type "research" :status nil
                                   :blocked-by '("1")))))
      (agent-shell-dispatch-wayfinder--diff-and-apply new-tickets)
      ;; Task 2 removed
      (should-not (cl-find-if
                   (lambda (t_) (equal "2" (plist-get t_ :id)))
                   (agent-shell-dispatch-state-tasks agent-shell-dispatch--state)))
      ;; Task 3 added
      (should (cl-find-if
               (lambda (t_) (equal "3" (plist-get t_ :id)))
               (agent-shell-dispatch-state-tasks agent-shell-dispatch--state)))
      ;; Known IDs updated
      (should (equal '("1" "3") agent-shell-dispatch-wayfinder--known-ids)))
    (agent-shell-dispatch-stop)))

;; ── Status resolution edge cases ─────────────────────────────────────

(ert-deftest dispatch-working-idle-resolves-to-done ()
  "A working task whose agent is no longer busy resolves to done."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-report "a" "working" "building")
    ;; shell-maker-busy returns nil — agent finished between reports
    (let ((shell-maker-busy-val nil))
      (let ((sm (agent-shell-dispatch--build-status-map)))
        (should (eq 'done (agent-shell-dispatch-render-task-status-status
                           (gethash "a" sm))))))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-claimed-stays-claimed ()
  "A task reported as claimed stays claimed regardless of busy state."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-report "a" "claimed")
    (let ((shell-maker-busy-val nil))
      (let ((sm (agent-shell-dispatch--build-status-map)))
        (should (eq 'claimed (agent-shell-dispatch-render-task-status-status
                              (gethash "a" sm))))))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-detail-only-shown-for-working ()
  "Detail text is only reported for tasks in working/permission state."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    ;; Working task shows detail
    (agent-shell-dispatch-report "a" "working" "parsing")
    (let ((shell-maker-busy-val t))
      (let* ((sm (agent-shell-dispatch--build-status-map))
             (ts (gethash "a" sm)))
        (should (equal "parsing" (agent-shell-dispatch-render-task-status-detail ts)))))
    ;; Done task does not show detail
    (agent-shell-dispatch-report "a" "done")
    (let* ((sm (agent-shell-dispatch--build-status-map))
           (ts (gethash "a" sm)))
      (should-not (agent-shell-dispatch-render-task-status-detail ts)))
    (agent-shell-dispatch-stop)))

;; ── Agent registry integration ───────────────────────────────────────

(ert-deftest dispatch-agent-registry-tracks-spawned-agents ()
  "Spawning an agent registers it in the dispatch agents hash."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (let ((agents (agent-shell-dispatch-state-agents agent-shell-dispatch--state)))
      ;; Register a mock agent
      (puthash "test-worker"
               (agent-shell-dispatch-agent-info-make
                :buffer "[agent:test-worker]"
                :name "test-worker"
                :busy nil)
               agents)
      ;; Lookup should find it
      (should (equal "[agent:test-worker]"
                     (agent-shell-dispatch-agent-buffer "test-worker")))
      ;; Unknown name returns nil
      (should-not (agent-shell-dispatch-agent-buffer "nonexistent")))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-render-agents-produces-render-structs ()
  "Agent activity function returns render-agent structs from registry."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    ;; Register a mock agent pointing to our buffer (which has a process)
    (let ((agents (agent-shell-dispatch-state-agents agent-shell-dispatch--state)))
      (puthash "worker"
               (agent-shell-dispatch-agent-info-make
                :buffer (buffer-name)
                :name "worker"
                :busy nil)
               agents))
    ;; The render function should produce a render-agent
    (let ((result (agent-shell-dispatch--render-agents)))
      (should result)
      (should (= 1 (length result)))
      (should (agent-shell-dispatch-render-agent-p (car result)))
      (should (equal "worker" (agent-shell-dispatch-render-agent-name (car result)))))
    (agent-shell-dispatch-stop)))

;; ── Multiple message types in sequence ───────────────────────────────

(ert-deftest dispatch-messages-multiple-agents-queue ()
  "Messages from multiple agents queue correctly in the dispatcher."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-diamond))
    (setq agent-shell-prompt-queue--entries nil)
    ;; Two agents complete different tasks
    (agent-shell-dispatch-msg-handle
     (agent-shell-dispatch-msg-task-completed-make
      :agent-buffer "[agent:left]"
      :timestamp (current-time)
      :task-id "b"
      :summary "Left branch done.")
     (buffer-name))
    (agent-shell-dispatch-msg-handle
     (agent-shell-dispatch-msg-task-completed-make
      :agent-buffer "[agent:right]"
      :timestamp (current-time)
      :task-id "c"
      :summary "Right branch done.")
     (buffer-name))
    ;; Both queued
    (should (= 2 (length agent-shell-prompt-queue--entries)))
    ;; Each prompt identifies its task
    (should (cl-find-if (lambda (e) (string-match-p "task: b" (plist-get e :prompt)))
                        agent-shell-prompt-queue--entries))
    (should (cl-find-if (lambda (e) (string-match-p "task: c" (plist-get e :prompt)))
                        agent-shell-prompt-queue--entries))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-input-needed-clears-on-send ()
  "Sending to an agent clears its pending-input state."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (setq agent-shell-dispatch-msg--pending-input-agents nil)
    ;; Simulate input-needed from agent
    (push (buffer-name) agent-shell-dispatch-msg--pending-input-agents)
    ;; Send response
    (agent-shell-dispatch-send-to-agent (buffer-name) "v2" "dispatcher")
    ;; Pending state cleared
    (should-not (member (buffer-name)
                        agent-shell-dispatch-msg--pending-input-agents))
    (agent-shell-dispatch-stop)))

;; ── Render context stability across mutations ────────────────────────

(ert-deftest dispatch-add-task-preserves-existing-statuses ()
  "Adding a task does not lose status reports for existing tasks."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-report "a" "done")
    ;; Add task D
    (agent-shell-dispatch-add-task
     (list :id "d" :name "Task D" :depends-on '("c")))
    ;; Task A's done status is preserved
    (let ((sm (agent-shell-dispatch--build-status-map)))
      (should (eq 'done (agent-shell-dispatch-render-task-status-status
                         (gethash "a" sm))))
      ;; New task D is not-started
      (should (eq 'not-started (agent-shell-dispatch-render-task-status-status
                                (gethash "d" sm)))))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-remove-last-task-empties-graph ()
  "Removing every task leaves no node behind in the rendered graph."
  (with-dispatch-buffer
    (agent-shell-dispatch-start
     (buffer-name) (list (list :id "a" :name "A" :depends-on nil)))
    (let* ((resets 0)
           (agent-shell-dispatch-render-reset-function (lambda () (cl-incf resets))))
      (should (agent-shell-dispatch-remove-task "a"))
      (should-not agent-shell-dispatch-render--task-defs)
      (should-not agent-shell-dispatch-render--ctx)
      (should (= 1 resets)))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-remove-task-preserves-other-statuses ()
  "Removing a task does not lose status reports for remaining tasks."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-report "a" "done")
    (agent-shell-dispatch-report "c" "done")
    ;; Remove B
    (agent-shell-dispatch-remove-task "b")
    ;; A and C statuses survive
    (let ((sm (agent-shell-dispatch--build-status-map)))
      (should (eq 'done (agent-shell-dispatch-render-task-status-status
                         (gethash "a" sm))))
      (should (eq 'done (agent-shell-dispatch-render-task-status-status
                         (gethash "c" sm)))))
    (agent-shell-dispatch-stop)))

;; ── Wayfinder sync-statuses integration ──────────────────────────────

(ert-deftest wayfinder-sync-does-not-downgrade-working ()
  "Sync from tracker does not downgrade a working task to claimed."
  (with-dispatch-buffer
    (agent-shell-dispatch-start
     (buffer-name)
     (list (list :id "1" :name "[T] First" :depends-on nil)))
    ;; Agent has started working
    (agent-shell-dispatch-report "1" "working")
    ;; Tracker still says claimed (file hasn't updated to resolved yet)
    (let ((tickets (list (list :id "1" :name "First"
                               :type "task" :status "claimed"
                               :blocked-by nil))))
      (agent-shell-dispatch-wayfinder--sync-statuses tickets))
    ;; Should still be working, not downgraded to claimed
    (let ((reported (gethash "1" (agent-shell-dispatch-state-statuses
                                  agent-shell-dispatch--state))))
      (should (eq 'working (agent-shell-dispatch-reported-status-status reported))))
    (agent-shell-dispatch-stop)))

(ert-deftest wayfinder-sync-upgrades-to-done ()
  "Sync from tracker upgrades a claimed task to done when resolved."
  (with-dispatch-buffer
    (agent-shell-dispatch-start
     (buffer-name)
     (list (list :id "1" :name "[T] First" :depends-on nil)))
    ;; Task was claimed
    (agent-shell-dispatch-report "1" "claimed")
    ;; Tracker says resolved
    (let ((tickets (list (list :id "1" :name "First"
                               :type "task" :status "resolved"
                               :blocked-by nil))))
      (agent-shell-dispatch-wayfinder--sync-statuses tickets))
    ;; Should upgrade to done
    (let ((reported (gethash "1" (agent-shell-dispatch-state-statuses
                                  agent-shell-dispatch--state))))
      (should (eq 'done (agent-shell-dispatch-reported-status-status reported))))
    (agent-shell-dispatch-stop)))

;; ── SVG rendering with agent activity ────────────────────────────────

(ert-deftest dispatch-render-draw-with-agents-produces-svg ()
  "Drawing with agents produces SVG containing agent names."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-report "a" "done")
    (let* ((sm (agent-shell-dispatch--build-status-map))
           (ctx agent-shell-dispatch-render--ctx)
           (agents (list (agent-shell-dispatch-render-agent-make
                          :name "researcher" :busy t)
                         (agent-shell-dispatch-render-agent-make
                          :name "builder" :busy nil)))
           (svg (agent-shell-dispatch-render-draw ctx sm agents)))
      (let ((svg-str (with-temp-buffer (svg-print svg) (buffer-string))))
        (should (string-match-p "<svg" svg-str))
        (should (string-match-p "researcher" svg-str))
        (should (string-match-p "builder" svg-str))))
    (agent-shell-dispatch-stop)))

;; ── Start/stop idempotency ───────────────────────────────────────────

(ert-deftest dispatch-start-twice-replaces-state ()
  "Calling start a second time replaces the dispatch state cleanly."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-report "a" "done")
    ;; Restart with different tasks
    (agent-shell-dispatch-start
     (buffer-name)
     (list (list :id "x" :name "Task X" :depends-on nil)
           (list :id "y" :name "Task Y" :depends-on '("x"))))
    ;; New state replaces old
    (should (= 2 (length (agent-shell-dispatch-state-tasks
                          agent-shell-dispatch--state))))
    ;; Old status is gone
    (should (= 0 (hash-table-count
                  (agent-shell-dispatch-state-statuses
                   agent-shell-dispatch--state))))
    ;; Render context reflects new tasks
    (let* ((ctx agent-shell-dispatch-render--ctx)
           (topo (agent-shell-dispatch-render-ctx-topo ctx))
           (leveled (agent-shell-dispatch-render-topology-leveled topo)))
      (should (= 2 (length leveled)))
      (should (cl-find-if (lambda (t_) (equal "x" (plist-get t_ :id))) leveled)))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-stop-is-idempotent ()
  "Calling stop multiple times does not error."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-stop)
    (agent-shell-dispatch-stop)
    (should-not agent-shell-dispatch-render--ctx)))

;; ── Diamond graph topology verification ──────────────────────────────

(ert-deftest dispatch-diamond-all-statuses ()
  "Diamond graph correctly builds status-map for all task states."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-diamond))
    (agent-shell-dispatch-report "a" "done")
    (agent-shell-dispatch-report "b" "working")
    (agent-shell-dispatch-report "c" "error")
    ;; d unreported
    (let ((shell-maker-busy-val t))
      (let ((sm (agent-shell-dispatch--build-status-map)))
        (should (eq 'done (agent-shell-dispatch-render-task-status-status
                           (gethash "a" sm))))
        (should (eq 'working (agent-shell-dispatch-render-task-status-status
                              (gethash "b" sm))))
        (should (eq 'error (agent-shell-dispatch-render-task-status-status
                            (gethash "c" sm))))
        (should (eq 'not-started (agent-shell-dispatch-render-task-status-status
                                  (gethash "d" sm))))))
    (agent-shell-dispatch-stop)))

;; ── Claude Code subagent tracking ─────────────────────────────────────

(ert-deftest subagent-agent-call-adds-task-node ()
  "An Agent tool call adds a node keyed by tool call ID, named by description."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-test--emit-agent-call "toolu_1" :description "Research: caching")
    (let ((task (agent-shell-dispatch-test--task "toolu_1")))
      (should task)
      (should (equal "Research: caching" (plist-get task :name))))
    (should (= 4 (length (agent-shell-dispatch-state-tasks agent-shell-dispatch--state))))
    (let ((leveled (agent-shell-dispatch-render-topology-leveled
                    (agent-shell-dispatch-render-ctx-topo agent-shell-dispatch-render--ctx))))
      (should (cl-find "toolu_1" leveled :key (lambda (task) (plist-get task :id)) :test #'equal)))
    (agent-shell-dispatch-stop)))

(ert-deftest subagent-name-falls-back-to-title ()
  "Without a description, the node is named after the tool call title."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-test--emit-tool-call
     "toolu_1" :title "Task" :raw-input '((prompt . "Look into it.")))
    (should (equal "Task" (plist-get (agent-shell-dispatch-test--task "toolu_1") :name)))
    (agent-shell-dispatch-stop)))

(ert-deftest subagent-status-follows-tool-call-status ()
  "pending and in_progress render working, completed done, failed error."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (let ((shell-maker-busy-val t))
      (agent-shell-dispatch-test--emit-agent-call "toolu_1" :status "pending")
      (should (eq 'working (agent-shell-dispatch-test--status "toolu_1")))
      (agent-shell-dispatch-test--emit-agent-call "toolu_1" :status "in_progress")
      (should (eq 'working (agent-shell-dispatch-test--status "toolu_1")))
      (agent-shell-dispatch-test--emit-agent-call "toolu_1" :status "completed")
      (should (eq 'done (agent-shell-dispatch-test--status "toolu_1")))
      (agent-shell-dispatch-test--emit-agent-call "toolu_2" :status "in_progress")
      (agent-shell-dispatch-test--emit-agent-call "toolu_2" :status "failed")
      (should (eq 'error (agent-shell-dispatch-test--status "toolu_2"))))
    (agent-shell-dispatch-stop)))

(ert-deftest subagent-non-agent-tool-calls-ignored ()
  "Bash, Read, WebFetch and task-list tool calls do not add nodes."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-test--emit-tool-call
     "toolu_bash" :kind "execute" :title "ls" :raw-input '((command . "ls")))
    (agent-shell-dispatch-test--emit-tool-call
     "toolu_read" :kind "read" :title "Read foo.el" :raw-input '((file_path . "foo.el")))
    (agent-shell-dispatch-test--emit-tool-call
     "toolu_fetch" :kind "fetch" :title "Fetch"
     :raw-input '((url . "https://example.com") (prompt . "Summarize")))
    (agent-shell-dispatch-test--emit-tool-call
     "toolu_todo" :kind "think" :title "TaskCreate"
     :raw-input '((subject . "x") (description . "y")))
    (should (= 3 (length (agent-shell-dispatch-state-tasks agent-shell-dispatch--state))))
    (should (= 0 (hash-table-count
                  (agent-shell-dispatch-state-statuses agent-shell-dispatch--state))))
    (agent-shell-dispatch-stop)))

(ert-deftest subagent-repeat-updates-do-not-duplicate ()
  "Repeat updates for one tool call ID update a single node."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-test--emit-agent-call "toolu_1" :status "pending")
    (agent-shell-dispatch-test--emit-agent-call "toolu_1" :status "in_progress")
    (agent-shell-dispatch-test--emit-agent-call "toolu_1" :status "completed")
    (should (= 1 (cl-count "toolu_1" (agent-shell-dispatch-state-tasks agent-shell-dispatch--state)
                           :key (lambda (task) (plist-get task :id)) :test #'equal)))
    (should (eq 'done (agent-shell-dispatch-test--status "toolu_1")))
    (agent-shell-dispatch-stop)))

(ert-deftest subagent-ticket-reference-routes-status-to-ticket ()
  "A subagent naming a graph ticket updates that ticket instead of adding a node."
  (with-dispatch-buffer
    (agent-shell-dispatch-start
     (buffer-name)
     (list (list :id "1" :name "1 [T] First" :depends-on nil)
           (list :id "2" :name "2 [R] Second" :depends-on '("1"))))
    (let ((shell-maker-busy-val t))
      ;; Named in the description
      (agent-shell-dispatch-test--emit-agent-call
       "toolu_1" :description "Research ticket 2: cache eviction")
      (should (eq 'working (agent-shell-dispatch-test--status "2")))
      (agent-shell-dispatch-test--emit-agent-call
       "toolu_1" :description "Research ticket 2: cache eviction" :status "completed")
      (should (eq 'done (agent-shell-dispatch-test--status "2")))
      ;; Named in the prompt by its local ticket file name
      (agent-shell-dispatch-test--emit-agent-call
       "toolu_2" :description "Research: schema"
       :prompt "Answer the question in .scratch/x/issues/01-first.md")
      (should (eq 'working (agent-shell-dispatch-test--status "1"))))
    (should (= 2 (length (agent-shell-dispatch-state-tasks agent-shell-dispatch--state))))
    (agent-shell-dispatch-stop)))

(ert-deftest subagent-unknown-ticket-reference-adds-node ()
  "A ticket reference that is not in the graph, or a bare number, adds a node."
  (with-dispatch-buffer
    (agent-shell-dispatch-start
     (buffer-name)
     (list (list :id "1" :name "1 [T] First" :depends-on nil)))
    (agent-shell-dispatch-test--emit-agent-call "toolu_1" :description "Research ticket #9")
    (agent-shell-dispatch-test--emit-agent-call "toolu_2" :description "Compare 1 vs 2 options")
    (should (agent-shell-dispatch-test--task "toolu_1"))
    (should (agent-shell-dispatch-test--task "toolu_2"))
    (should-not (gethash "1" (agent-shell-dispatch-state-statuses agent-shell-dispatch--state)))
    (agent-shell-dispatch-stop)))

(ert-deftest subagent-hyphenated-number-is-not-a-ticket-reference ()
  "A number joined to a word, like 2-phase, is not a ticket file name."
  (with-dispatch-buffer
    (agent-shell-dispatch-start
     (buffer-name)
     (list (list :id "2" :name "2 [T] Second" :depends-on nil)))
    (agent-shell-dispatch-test--emit-agent-call
     "toolu_1" :description "Design the 2-phase commit")
    (should (agent-shell-dispatch-test--task "toolu_1"))
    (should-not (gethash "2" (agent-shell-dispatch-state-statuses agent-shell-dispatch--state)))
    (agent-shell-dispatch-stop)))

(ert-deftest subagent-background-tracked-until-turn-complete ()
  "A background subagent stays working after its launch ack until the turn ends."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (let ((shell-maker-busy-val t))
      (agent-shell-dispatch-test--emit-agent-call "toolu_bg" :background t)
      ;; claude-agent-acp completes a background Agent call as soon as it launches
      (agent-shell-dispatch-test--emit-agent-call "toolu_bg" :background t :status "completed")
      (should (eq 'working (agent-shell-dispatch-test--status "toolu_bg"))))
    ;; The prompt turn is held open until background subagents drain
    (agent-shell-dispatch-test--emit (current-buffer) 'turn-complete)
    (should (eq 'done (agent-shell-dispatch-reported-status-status
                       (gethash "toolu_bg" (agent-shell-dispatch-state-statuses
                                            agent-shell-dispatch--state)))))
    (agent-shell-dispatch-stop)))

(ert-deftest subagent-background-failure-is-error ()
  "A background subagent that fails to launch shows as error."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-test--emit-agent-call "toolu_bg" :background t)
    (agent-shell-dispatch-test--emit-agent-call "toolu_bg" :background t :status "failed")
    (agent-shell-dispatch-test--emit (current-buffer) 'turn-complete)
    (should (eq 'error (agent-shell-dispatch-test--status "toolu_bg")))
    (agent-shell-dispatch-stop)))

(ert-deftest subagent-teardown-clears-graph-state ()
  "Render teardown drops the graph state and its turn-complete subscription."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-render-teardown)
    (should-not (agent-shell-dispatch-test--subscribed-p (current-buffer) 'turn-complete))
    (should-not agent-shell-dispatch--state)))

(ert-deftest subagent-tracking-disabled-by-defcustom ()
  "With tracking off, subagents neither add nodes nor start a graph."
  (with-dispatch-buffer
    (let ((agent-shell-dispatch-track-subagents nil))
      (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
      (agent-shell-dispatch-test--emit-agent-call "toolu_1")
      (should-not (agent-shell-dispatch-test--task "toolu_1"))
      (agent-shell-dispatch-stop)
      (agent-shell-dispatch--clear-state)
      (agent-shell-dispatch-test--emit-agent-call "toolu_2")
      (should-not agent-shell-dispatch--state))))

(ert-deftest subagent-finished-foreground-calls-stop-being-tracked ()
  "Foreground subagents leave the tracking table once they finish; running
background subagents stay tracked until the turn completes."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-test--emit-agent-call "toolu_ok" :description "Research: ok")
    (agent-shell-dispatch-test--emit-agent-call "toolu_ok" :description "Research: ok"
                                                :status "completed")
    (agent-shell-dispatch-test--emit-agent-call "toolu_bad" :description "Research: bad"
                                                :status "failed")
    (agent-shell-dispatch-test--emit-agent-call "toolu_bg" :description "Research: bg"
                                                :background t :status "completed")
    (should (eq 'done (agent-shell-dispatch-test--status "toolu_ok")))
    (should (eq 'error (agent-shell-dispatch-test--status "toolu_bad")))
    (should (equal '("toolu_bg")
                   (hash-table-keys (agent-shell-dispatch-state-subagents
                                     agent-shell-dispatch--state))))
    (agent-shell-dispatch-stop)))

(ert-deftest wayfinder-local-ticket-prompt-asks-agent-to-resolve ()
  "The default local ticket prompt carries the ticket and how to resolve it."
  (let ((prompt (agent-shell-dispatch-wayfinder--ticket-prompt
                 '(:id "3" :name "summarize") 'local
                 "/work/.scratch/fx/issues/03-summarize.md" "Write the summary.")))
    (should (string-match-p "Work on: summarize" prompt))
    (should (string-match-p "Write the summary\\." prompt))
    (should (string-match-p (regexp-quote "/work/.scratch/fx/issues/03-summarize.md") prompt))
    (should (string-match-p "## Answer" prompt))
    (should (string-match-p "Status: resolved" prompt))))

(ert-deftest wayfinder-github-ticket-prompt-asks-agent-to-close-issue ()
  "The default GitHub ticket prompt tells the agent to close its issue."
  (let ((prompt (agent-shell-dispatch-wayfinder--ticket-prompt
                 '(:id "7" :name "probe api") 'github nil nil)))
    (should (string-match-p "Work on: probe api" prompt))
    (should (string-match-p "gh issue close 7" prompt))))

;; ── One graph per shell ────────────────────────────────────────────────

(defun agent-shell-dispatch-test--set-host-header ()
  "Give the current buffer an agent-shell style header holding an SVG image."
  (setq-local header-line-format
              (concat " " (propertize " " 'display
                                      (list 'image :type 'svg
                                            :data "<svg width=\"100\" height=\"20\"></svg>")))))

(defun agent-shell-dispatch-test--header-svg ()
  "Return the SVG data shown in the current buffer's header line."
  (plist-get (cdr (get-text-property 1 'display header-line-format)) :data))

(ert-deftest dispatch-start-from-another-buffer-targets-dispatcher ()
  "The graph starts in the named dispatcher, whatever buffer is current."
  (with-dispatch-buffer
    (let ((dispatcher (buffer-name)))
      (with-temp-buffer
        (agent-shell-dispatch-start dispatcher (test-tasks-simple))
        (should-not agent-shell-dispatch--state))
      (should agent-shell-dispatch--state)
      (should agent-shell-dispatch-render--ctx)
      (should agent-shell-dispatch-render-mode)
      (agent-shell-dispatch-stop))))

(ert-deftest dispatch-graphs-are-independent-per-shell ()
  "Starting and tearing down a graph in one shell leaves another shell's graph working."
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-report "a" "done")
    (with-dispatch-buffer
      (agent-shell-dispatch-start (buffer-name) (test-tasks-diamond))
      (agent-shell-dispatch-render-teardown))
    (should (eq 'done (agent-shell-dispatch-test--status "a")))
    (should agent-shell-dispatch-render-mode)
    (should (eq 'agent-shell--update-header-and-mode-line
                agent-shell-dispatch-render-advice-target))
    (agent-shell-dispatch-test--set-host-header)
    (agent-shell-dispatch-render--extend-header)
    (should (string-match-p "Task A" (agent-shell-dispatch-test--header-svg)))
    (agent-shell-dispatch-stop)))

(ert-deftest dispatch-start-keeps-other-shells-blocked-agents ()
  "Restarting a graph forgets only its own agents' pending permission and input."
  (let ((agent-shell-dispatch-msg--pending-permission-agents nil)
        (agent-shell-dispatch-msg--pending-input-agents nil))
    (with-dispatch-buffer
      (let ((dispatcher (buffer-name)))
        (agent-shell-dispatch-start dispatcher (test-tasks-simple))
        (with-dispatch-buffer
          (setq-local agent-shell-dispatch--primary-buffer dispatcher)
          (let ((agent (buffer-name)))
            (setq agent-shell-dispatch-msg--pending-permission-agents (list agent)
                  agent-shell-dispatch-msg--pending-input-agents (list agent))
            (with-dispatch-buffer
              (agent-shell-dispatch-start (buffer-name) (test-tasks-diamond))
              (agent-shell-dispatch-stop))
            (should (equal (list agent) agent-shell-dispatch-msg--pending-permission-agents))
            (should (equal (list agent) agent-shell-dispatch-msg--pending-input-agents))
            (agent-shell-dispatch-start dispatcher (test-tasks-simple))
            (should-not agent-shell-dispatch-msg--pending-permission-agents)
            (should-not agent-shell-dispatch-msg--pending-input-agents)))
        (agent-shell-dispatch-stop)))))

(ert-deftest render-spinner-frame-follows-the-clock ()
  "Every graph shows the same spinner frame at a given moment, however many
graphs render it."
  (let ((working-icon (lambda ()
                        (agent-shell-dispatch-render-status-style-icon
                         (cdr (assq 'working (agent-shell-dispatch-render-theme-status
                                              (agent-shell-dispatch-render--theme-colors))))))))
    (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 100.0)))
      (agent-shell-dispatch-render-cycle-spinner)
      (let ((frame (funcall working-icon)))
        (agent-shell-dispatch-render-cycle-spinner)
        (should (equal frame (funcall working-icon)))
        (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 100.1)))
          (agent-shell-dispatch-render-cycle-spinner)
          (should-not (equal frame (funcall working-icon))))))))

;; ── Automatic subagent graph ──────────────────────────────────────────

(defun agent-shell-dispatch-test--watchers (buffer)
  "Return the number of tool-call-update subscriptions on BUFFER."
  (cl-count-if (lambda (sub) (and (eq (nth 1 sub) buffer) (eq (nth 2 sub) 'tool-call-update)))
               agent-shell-test--subscriptions))

(ert-deftest auto-graph-starts-on-first-subagent ()
  "A shell's first subagent starts a graph showing it, without any dispatch call."
  (agent-shell-dispatch-global-mode 1)
  (with-dispatch-buffer
    (should-not agent-shell-dispatch--state)
    (let ((shell-maker-busy-val t))
      (agent-shell-dispatch-test--emit-agent-call "toolu_1" :description "Research: caching")
      (should agent-shell-dispatch-render-mode)
      (should (equal "Research: caching"
                     (plist-get (agent-shell-dispatch-test--task "toolu_1") :name)))
      (should (eq 'working (agent-shell-dispatch-test--status "toolu_1"))))
    (agent-shell-dispatch-test--set-host-header)
    (agent-shell-dispatch-render--extend-header)
    (should (string-match-p "caching" (agent-shell-dispatch-test--header-svg)))
    (agent-shell-dispatch-render-teardown)))

(ert-deftest auto-graph-starts-fresh-after-teardown ()
  "After a graph is torn down, the next subagent starts a new graph with only itself."
  (agent-shell-dispatch-global-mode 1)
  (with-dispatch-buffer
    (agent-shell-dispatch-test--emit-agent-call "toolu_1")
    (agent-shell-dispatch-render-teardown)
    (agent-shell-dispatch-test--emit-agent-call "toolu_2")
    (should (equal '("toolu_2")
                   (mapcar (lambda (task) (plist-get task :id))
                           (agent-shell-dispatch-state-tasks agent-shell-dispatch--state))))
    (agent-shell-dispatch-render-teardown)))

(ert-deftest auto-graph-ignores-spawned-agents ()
  "Subagents inside a dispatch-spawned agent do not give it a graph of its own."
  (agent-shell-dispatch-global-mode 1)
  (with-dispatch-buffer
    (setq-local agent-shell-dispatch--primary-buffer "dispatcher")
    (agent-shell-dispatch-test--emit-agent-call "toolu_1")
    (should-not agent-shell-dispatch--state)))

(ert-deftest auto-graph-disabled-by-defcustom ()
  "With auto-graph off, subagents only show in a graph that was started explicitly."
  (agent-shell-dispatch-global-mode 1)
  (with-dispatch-buffer
    (let ((agent-shell-dispatch-auto-graph nil))
      (agent-shell-dispatch-test--emit-agent-call "toolu_1")
      (should-not agent-shell-dispatch--state)
      (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
      (agent-shell-dispatch-test--emit-agent-call "toolu_2")
      (should (agent-shell-dispatch-test--task "toolu_2")))
    (agent-shell-dispatch-render-teardown)))

(ert-deftest auto-graph-watches-shells-opened-before-global-mode ()
  "Enabling the global mode watches shells that are already open."
  (agent-shell-dispatch-global-mode -1)
  (with-dispatch-buffer
    (agent-shell-dispatch-global-mode 1)
    (agent-shell-dispatch-test--emit-agent-call "toolu_1")
    (should (agent-shell-dispatch-test--task "toolu_1"))
    (agent-shell-dispatch-render-teardown)))

(ert-deftest auto-graph-global-mode-off-stops-watching ()
  "Disabling the global mode stops watching shells for subagents."
  (agent-shell-dispatch-global-mode 1)
  (with-dispatch-buffer
    (agent-shell-dispatch-global-mode -1)
    (should (= 0 (agent-shell-dispatch-test--watchers (current-buffer))))
    (agent-shell-dispatch-global-mode 1)))

(ert-deftest auto-graph-one-watcher-per-shell ()
  "Restarting a shell's graph does not add more tool-call subscriptions."
  (agent-shell-dispatch-global-mode 1)
  (with-dispatch-buffer
    (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
    (agent-shell-dispatch-start (buffer-name) (test-tasks-diamond))
    (should (= 1 (agent-shell-dispatch-test--watchers (current-buffer))))
    (agent-shell-dispatch-render-teardown)))

;; ── Dismissing a graph from its header ────────────────────────────────

(defun agent-shell-dispatch-test--dismiss-button-center ()
  "Return the (X . Y) centre of the close button in the header SVG, or nil."
  (let ((svg (agent-shell-dispatch-test--header-svg)))
    (when (string-match (concat "<rect id=\"agent-shell-dispatch-dismiss\" "
                                "x=\"\\([0-9.]+\\)\" y=\"\\([0-9.]+\\)\" "
                                "width=\"\\([0-9.]+\\)\" height=\"\\([0-9.]+\\)\"")
                        svg)
      (let ((x (string-to-number (match-string 1 svg)))
            (y (string-to-number (match-string 2 svg)))
            (w (string-to-number (match-string 3 svg)))
            (h (string-to-number (match-string 4 svg))))
        (cons (+ x (/ w 2.0)) (+ y (/ h 2.0)))))))

(defun agent-shell-dispatch-test--header-dims ()
  "Return the (WIDTH . HEIGHT) of the header SVG."
  (let ((dims (agent-shell-dispatch-render--svg-dimensions
               (agent-shell-dispatch-test--header-svg))))
    (cons (agent-shell-dispatch-render-dimensions-w dims)
          (agent-shell-dispatch-render-dimensions-h dims))))

(defun agent-shell-dispatch-test--click-header (x y &optional scale)
  "Click the current buffer's header image at image pixel X, Y.
SCALE is how much larger the image is displayed than its SVG size."
  (let* ((scale (or scale 1))
         (dims (agent-shell-dispatch-test--header-dims))
         (win (selected-window)))
    (set-window-buffer win (current-buffer))
    (agent-shell-dispatch-render-header-click
     (list 'mouse-1
           (list win 'header-line '(0 . 0) 0 nil nil '(0 . 0) nil
                 (cons (round (* x scale)) (round (* y scale)))
                 (cons (round (* (car dims) scale)) (round (* (cdr dims) scale))))))))

(defun agent-shell-dispatch-test--render-graph ()
  "Start a graph in the current shell and draw it into a host header."
  (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
  (agent-shell-dispatch-test--set-host-header)
  (agent-shell-dispatch-render--extend-header))

(ert-deftest dismiss-clicking-close-button-removes-graph ()
  "Clicking the graph's close button removes the graph and its state."
  (with-dispatch-buffer
    (agent-shell-dispatch-test--render-graph)
    (let ((center (agent-shell-dispatch-test--dismiss-button-center)))
      (should center)
      (agent-shell-dispatch-test--click-header (car center) (cdr center)))
    (should-not agent-shell-dispatch--state)
    (should-not agent-shell-dispatch-render-mode)
    (should-not agent-shell-dispatch-render--ctx)))

(ert-deftest dismiss-clicking-elsewhere-keeps-graph ()
  "Clicking the header away from the close button leaves the graph."
  (with-dispatch-buffer
    (agent-shell-dispatch-test--render-graph)
    (agent-shell-dispatch-test--click-header 1 1)
    (should agent-shell-dispatch--state)
    (should agent-shell-dispatch-render-mode)
    (agent-shell-dispatch-stop)))

(ert-deftest dismiss-click-accounts-for-image-scaling ()
  "The close button is hit where it is displayed when the header image is scaled."
  (with-dispatch-buffer
    (agent-shell-dispatch-test--render-graph)
    (let ((center (agent-shell-dispatch-test--dismiss-button-center)))
      (agent-shell-dispatch-test--click-header (car center) (cdr center) 2))
    (should-not agent-shell-dispatch--state)))

(ert-deftest dismiss-button-only-drawn-when-graph-can-be-dismissed ()
  "A renderer host that provides no dismiss function gets no close button."
  (with-dispatch-buffer
    (agent-shell-dispatch-test--render-graph)
    (setq agent-shell-dispatch-render-dismiss-function nil)
    (agent-shell-dispatch-test--set-host-header)
    (agent-shell-dispatch-render--extend-header)
    (should-not (agent-shell-dispatch-test--dismiss-button-center))
    (agent-shell-dispatch-stop)))

(ert-deftest dismiss-runs-dismiss-hook ()
  "Dismissing a graph runs the shell's dismiss hook so extensions can clean up."
  (with-dispatch-buffer
    (let ((ran nil))
      (agent-shell-dispatch-start (buffer-name) (test-tasks-simple))
      (add-hook 'agent-shell-dispatch-dismiss-hook (lambda () (setq ran t)) nil t)
      (agent-shell-dispatch-dismiss)
      (should ran)
      (should-not agent-shell-dispatch--state))))

(ert-deftest dismiss-wayfinder-graph-unloads-effort ()
  "Dismissing a wayfinder graph unloads its effort and stops watching tickets."
  (let* ((root (file-name-as-directory (make-temp-file "wayfinder-dismiss-" t)))
         (issues (expand-file-name ".scratch/demo/issues" root)))
    (unwind-protect
        (with-dispatch-buffer
          (make-directory issues t)
          (with-temp-file (expand-file-name "01-first.md" issues)
            (insert "Type: task\nStatus: claimed\nBlocked by:\n\n# First\n"))
          (let ((default-directory root))
            (agent-shell-dispatch-wayfinder-load "demo"))
          (should agent-shell-dispatch-wayfinder--effort)
          (agent-shell-dispatch-dismiss)
          (should-not agent-shell-dispatch-wayfinder--effort)
          (should-not agent-shell-dispatch-wayfinder--file-watcher)
          (should-not agent-shell-dispatch--state)
          ;; A later graph in the same shell is not wayfinder's to unload
          (should-not (memq #'agent-shell-dispatch-wayfinder-unload
                            agent-shell-dispatch-dismiss-hook)))
      (delete-directory root t))))

;; ── Permission lock follows agent-shell's permission events ────────────

(defmacro agent-shell-dispatch-test--with-spawned-agent (agent &rest body)
  "Run BODY in a dispatcher shell with AGENT bound to a spawned agent's buffer."
  (declare (indent 1))
  `(let ((agent-shell-dispatch-msg--pending-permission-agents nil)
         (agent-shell-dispatch-msg-show-permissions-in-dispatcher nil))
     (with-dispatch-buffer
       (let ((dispatcher (current-buffer)))
         (with-dispatch-buffer
           (let ((,agent (current-buffer)))
             (with-current-buffer dispatcher
               (cl-letf (((symbol-function 'agent-shell--start) (lambda (&rest _) ,agent)))
                 (agent-shell-dispatch-start-agent nil nil "worker")))
             ,@body))))))

(defun agent-shell-dispatch-test--request-permission (agent)
  "Have AGENT ask for permission through its responder, as agent-shell does."
  (with-current-buffer agent
    (funcall agent-shell-permission-responder-function
             (list (cons :tool-call '((:title . "Edit file") (:kind . "edit")))
                   (cons :options nil)
                   (cons :respond #'ignore)))))

(ert-deftest permission-lock-clears-when-agent-answers ()
  "An agent's permission lock clears once agent-shell reports the permission answered.
This holds however it was answered: a dispatcher button, the agent's own
buffer, or an interrupt rejecting it."
  (agent-shell-dispatch-test--with-spawned-agent agent
    (agent-shell-dispatch-test--request-permission agent)
    (should (member (buffer-name agent) agent-shell-dispatch-msg--pending-permission-agents))
    (agent-shell-dispatch-test--emit agent 'permission-response
                                     '((:option-id . "allow") (:cancelled . nil)))
    (should-not (member (buffer-name agent) agent-shell-dispatch-msg--pending-permission-agents))))

(ert-deftest permission-lock-cleared-for-newly-started-agent ()
  "A newly started agent has no permission lock left from an earlier one of the same name."
  (let ((agent-shell-dispatch-msg--pending-permission-agents nil))
    (with-dispatch-buffer
      (let ((agent (current-buffer)))
        (setq agent-shell-dispatch-msg--pending-permission-agents (list (buffer-name agent)))
        (cl-letf (((symbol-function 'agent-shell--start) (lambda (&rest _) agent)))
          (agent-shell-dispatch-start-agent nil nil "worker"))
        (should-not agent-shell-dispatch-msg--pending-permission-agents)))))

;; ── Spawned agent's first message ─────────────────────────────────────

(ert-deftest spawn-agent-submits-initial-message-to-new-agent ()
  "A spawned agent's first message is submitted into that agent's own shell.
agent-shell holds the submission until the new session is ready, so it is
handed over straight away rather than after a guessed delay."
  (let ((agent-shell-test--insertions nil))
    (with-dispatch-buffer
      (let ((agent (current-buffer)))
        (with-temp-buffer
          (cl-letf (((symbol-function 'agent-shell--start) (lambda (&rest _) agent)))
            (agent-shell-dispatch-spawn-agent default-directory "worker" "Research: caching")))
        (should (= 1 (length agent-shell-test--insertions)))
        (pcase-let ((`(,current . ,args) (car agent-shell-test--insertions)))
          ;; Inserting from the agent's buffer keeps it out of any viewport
          (should (eq current agent))
          (should (eq (plist-get args :shell-buffer) agent))
          (should (equal (plist-get args :text) "Research: caching"))
          (should (plist-get args :submit))
          (should (plist-get args :no-focus)))))))

;; ── Prompts queued for a shell ───────────────────────────────────────

(defun agent-shell-dispatch-test--prompt-senders (target)
  "Return functions that each queue one dispatch prompt for TARGET's shell."
  (let ((name (buffer-name target)))
    (list
     (lambda () (agent-shell-dispatch-send-to-agent name "Use v2" "dispatcher"))
     (lambda () (agent-shell-dispatch-msg-handle
                 (agent-shell-dispatch-msg-task-completed-make
                  :agent-buffer "[agent:w]" :timestamp (current-time)
                  :task-id "a" :summary "Done.")
                 name))
     (lambda () (agent-shell-dispatch-msg-handle
                 (agent-shell-dispatch-msg-error-make
                  :agent-buffer "[agent:w]" :timestamp (current-time)
                  :task-id "a" :description "Broke" :context nil)
                 name))
     (lambda () (agent-shell-dispatch-msg-handle
                 (agent-shell-dispatch-msg-input-needed-make
                  :agent-buffer "[agent:w]" :timestamp (current-time)
                  :question "Which?" :context nil)
                 name)))))

(ert-deftest queued-prompt-sent-at-once-to-idle-shell ()
  "Every dispatch prompt is queued, and sent straight away when its shell is idle."
  (let ((agent-shell-dispatch-msg--pending-input-agents nil))
    (with-dispatch-buffer
      (let ((target (current-buffer)))
        (dolist (send (agent-shell-dispatch-test--prompt-senders target))
          (let ((agent-shell-prompt-queue--entries nil)
                (agent-shell-test--queue-sends nil)
                (shell-maker-busy-val nil))
            (with-temp-buffer (funcall send))
            (should (= 1 (length agent-shell-prompt-queue--entries)))
            (should (equal (list target) agent-shell-test--queue-sends))))))))

(ert-deftest queued-prompt-waits-for-busy-shell ()
  "A dispatch prompt for a busy shell waits in its queue for the turn to end."
  (let ((agent-shell-dispatch-msg--pending-input-agents nil))
    (with-dispatch-buffer
      (let ((target (current-buffer)))
        (dolist (send (agent-shell-dispatch-test--prompt-senders target))
          (let ((agent-shell-prompt-queue--entries nil)
                (agent-shell-test--queue-sends nil)
                (shell-maker-busy-val t))
            (with-temp-buffer (funcall send))
            (should (= 1 (length agent-shell-prompt-queue--entries)))
            (should-not agent-shell-test--queue-sends)))))))

(provide 'agent-shell-dispatch-integration-test)
;;; agent-shell-dispatch-integration-test.el ends here
