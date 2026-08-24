;;; agent-shell-dispatch-integration-test.el --- Integration tests -*- lexical-binding: t; -*-

;;; Commentary:

;; End-to-end tests verifying that the dispatch, render, and messages
;; modules integrate correctly.  External dependencies (agent-shell,
;; shell-maker, agent-shell-ui) are stubbed at the boundary.

;;; Code:

(setq load-prefer-newer t)

(require 'ert)
(require 'cl-lib)

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
  (defun agent-shell-subscribe-to (&rest _) 'test-subscription-token)
  (defun agent-shell-unsubscribe (&rest _) nil)
  (defun agent-shell-interrupt (&optional _) nil)
  (defun agent-shell-diff (&rest _) nil)
  (defun agent-shell-anthropic-make-claude-code-config () nil)
  (defun agent-shell-cycle-session-mode (&optional _on-success) nil)
  (defun agent-shell-set-session-mode (&optional _on-success) nil)
  (provide 'agent-shell))

(unless (featurep 'agent-shell-prompt-queue)
  (defvar agent-shell-prompt-queue--entries nil)
  (defun agent-shell--prompt-queue-enqueue (&rest args)
    (push args agent-shell-prompt-queue--entries))
  (defun agent-shell--prompt-queue-process-next () nil)
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

(ert-deftest wayfinder-local-parse-ticket ()
  "Local backend parses markdown ticket files correctly."
  (let ((tmp (make-temp-file "wayfinder-test-" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "Type: grilling\nStatus: claimed\nBlocked by: 1, 2\n\n# Do the thing\n\nBody text."))
          ;; Rename to match expected pattern
          (let ((proper (expand-file-name "03-do-the-thing.md"
                                          (file-name-directory tmp))))
            (rename-file tmp proper t)
            (unwind-protect
                (let ((ticket (agent-shell-dispatch-wayfinder--local-parse-ticket proper)))
                  (should ticket)
                  (should (equal "3" (plist-get ticket :id)))
                  (should (equal "do the thing" (plist-get ticket :name)))
                  (should (equal "grilling" (plist-get ticket :type)))
                  (should (equal "claimed" (plist-get ticket :status)))
                  (should (equal '("1" "2") (plist-get ticket :blocked-by))))
              (delete-file proper))))
      (when (file-exists-p tmp)
        (delete-file tmp)))))

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

(provide 'agent-shell-dispatch-integration-test)
;;; agent-shell-dispatch-integration-test.el ends here
