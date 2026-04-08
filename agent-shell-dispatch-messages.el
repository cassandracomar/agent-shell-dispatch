;;; agent-shell-dispatch-messages.el --- Messaging protocol for dispatch -*- lexical-binding: t; -*-

;;; Commentary:

;; Typed messaging between subagents and the dispatcher buffer.
;; Uses cl-defgeneric for method dispatch on message struct types.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'agent-shell)
(require 'agent-shell-ui)

(defvar agent-shell-dispatch--primary-buffer)

;; ── Base struct ─────────────────────────────────────────────────────

(cl-defstruct (agent-shell-dispatch-msg
               (:constructor nil)
               (:copier nil))
  "Base message from a subagent."
  agent-buffer
  timestamp)

;; ── Message types ───────────────────────────────────────────────────

(cl-defstruct (agent-shell-dispatch-msg-permission
               (:include agent-shell-dispatch-msg)
               (:constructor agent-shell-dispatch-msg-permission-make)
               (:copier nil))
  "Permission request from a subagent."
  tool-call options respond)

(cl-defstruct (agent-shell-dispatch-msg-input-needed
               (:include agent-shell-dispatch-msg)
               (:constructor agent-shell-dispatch-msg-input-needed-make)
               (:copier nil))
  "Subagent needs input from the dispatcher."
  question context)

(cl-defstruct (agent-shell-dispatch-msg-batch-progress
               (:include agent-shell-dispatch-msg)
               (:constructor agent-shell-dispatch-msg-batch-progress-make)
               (:copier nil))
  "Milestone progress on a batch of work."
  phase completed total)

(cl-defstruct (agent-shell-dispatch-msg-batch-completed
               (:include agent-shell-dispatch-msg)
               (:constructor agent-shell-dispatch-msg-batch-completed-make)
               (:copier nil))
  "Batch of work completed."
  summary)

(cl-defstruct (agent-shell-dispatch-msg-task-progress
               (:include agent-shell-dispatch-msg)
               (:constructor agent-shell-dispatch-msg-task-progress-make)
               (:copier nil))
  "Milestone progress on the overall task."
  phase)

(cl-defstruct (agent-shell-dispatch-msg-task-completed
               (:include agent-shell-dispatch-msg)
               (:constructor agent-shell-dispatch-msg-task-completed-make)
               (:copier nil))
  "Overall task completed."
  summary)

(cl-defstruct (agent-shell-dispatch-msg-error
               (:include agent-shell-dispatch-msg)
               (:constructor agent-shell-dispatch-msg-error-make)
               (:copier nil))
  "Error report from a subagent."
  description context)

;; ── Protocol ────────────────────────────────────────────────────────

(cl-defgeneric agent-shell-dispatch-msg-render (msg)
  "Format MSG body as a propertized string.
Used by frame-based senders (permissions, input-needed).")

(cl-defgeneric agent-shell-dispatch-msg-handle (_msg _target-buf)
  "Handle side effects of MSG after rendering in TARGET-BUF.
Default is no-op."
  nil)

(cl-defgeneric agent-shell-dispatch-msg-summary (msg)
  "Return a short propertized summary for MSG fragment label-right.
Used by the default `msg-send' for the collapsible fragment header.")

(cl-defgeneric agent-shell-dispatch-msg-detail (_msg)
  "Return the detailed body string for MSG fragment, or nil.
When nil the fragment displays flat; when non-nil it is collapsible."
  nil)

(defvar agent-shell-dispatch-msg--block-counter 0
  "Counter for generating unique dispatch fragment block IDs.")

(cl-defgeneric agent-shell-dispatch-msg-send (msg target-buf)
  "Send MSG to TARGET-BUF as a collapsible UI fragment.
Permission and input-needed messages override this with frame-based rendering."
  (when-let* ((buf (get-buffer target-buf)))
    (let* ((agent (agent-shell-dispatch-msg-agent-buffer msg))
           (summary (agent-shell-dispatch-msg-summary msg))
           (detail (agent-shell-dispatch-msg-detail msg))
           (block-id (format "dispatch-%d"
                             (cl-incf agent-shell-dispatch-msg--block-counter)))
           (label-left (propertize agent 'font-lock-face 'font-lock-comment-face))
           (model (agent-shell-ui-make-fragment-model
                   :namespace-id "dispatch"
                   :block-id block-id
                   :label-left label-left
                   :label-right summary
                   :body detail)))
      (with-current-buffer buf
        (save-excursion
          (let ((inhibit-read-only t))
            (save-restriction
              ;; Narrow to before the prompt so the fragment inserts above it.
              (when-let* ((proc (get-buffer-process (current-buffer)))
                          ((not shell-maker--busy)))
                (narrow-to-region (point-min)
                                  (save-excursion
                                    (goto-char (process-mark proc))
                                    (forward-line 0)
                                    (point))))
              (agent-shell-ui-update-fragment model
                                              :create-new t
                                              :no-undo t)))))
      (agent-shell-dispatch-msg-handle msg target-buf))))

;; ── Shared rendering helpers ────────────────────────────────────────

(defun agent-shell-dispatch-msg--frame (agent-name body)
  "Wrap BODY in a frame with AGENT-NAME header."
  (let ((header (propertize (format "╭─ %s " agent-name)
                            'font-lock-face 'font-lock-comment-face))
        (rule (propertize (make-string 30 ?─)
                          'font-lock-face 'font-lock-comment-face))
        (footer (propertize "╰─" 'font-lock-face 'font-lock-comment-face))
        (bar (propertize "│ " 'font-lock-face 'font-lock-comment-face)))
    (concat "\n" header rule "\n"
            (mapconcat (lambda (line) (concat bar line))
                       (split-string body "\n" t)
                       "\n")
            "\n" footer "\n")))

(defun agent-shell-dispatch-msg--insert-before-prompt (buf text)
  "Insert TEXT into BUF before the prompt, or at point-max if busy."
  (with-current-buffer buf
    (save-excursion
      (let ((inhibit-read-only t))
        (cond
         (shell-maker--busy
          (goto-char (point-max))
          (insert text))
         ((when-let* ((proc (get-buffer-process (current-buffer))))
            (goto-char (process-mark proc))
            (forward-line 0)
            (insert text "\n")
            t))
         (t (goto-char (point-max))
            (insert text)))))))

;; ── Render methods ──────────────────────────────────────────────────

(cl-defmethod agent-shell-dispatch-msg-render
  ((msg agent-shell-dispatch-msg-input-needed))
  "Render input-needed MSG as question with context."
  (let ((q (agent-shell-dispatch-msg-input-needed-question msg))
        (ctx (agent-shell-dispatch-msg-input-needed-context msg)))
    (concat (propertize "❓ " 'font-lock-face 'warning)
            (propertize q 'font-lock-face 'bold)
            (when ctx (concat "\n\n" ctx)))))

(cl-defmethod agent-shell-dispatch-msg-render
  ((msg agent-shell-dispatch-msg-batch-progress))
  "Render batch progress MSG as milestone line."
  (let ((phase (agent-shell-dispatch-msg-batch-progress-phase msg))
        (done (agent-shell-dispatch-msg-batch-progress-completed msg))
        (total (agent-shell-dispatch-msg-batch-progress-total msg)))
    (concat (propertize "📋 " 'font-lock-face 'success)
            (propertize (format "%s (%d/%d)" phase done total)
                        'font-lock-face 'font-lock-function-name-face))))

(cl-defmethod agent-shell-dispatch-msg-render
  ((msg agent-shell-dispatch-msg-batch-completed))
  "Render batch completed MSG as summary."
  (concat (propertize "✅ " 'font-lock-face 'success)
          (propertize "Batch complete: " 'font-lock-face 'bold)
          (agent-shell-dispatch-msg-batch-completed-summary msg)))

(cl-defmethod agent-shell-dispatch-msg-render
  ((msg agent-shell-dispatch-msg-task-progress))
  "Render task progress MSG as phase milestone."
  (concat (propertize "📋 " 'font-lock-face 'success)
          (agent-shell-dispatch-msg-task-progress-phase msg)))

(cl-defmethod agent-shell-dispatch-msg-render
  ((msg agent-shell-dispatch-msg-task-completed))
  "Render task completed MSG as summary."
  (concat (propertize "✅ " 'font-lock-face 'success)
          (propertize "Task complete: " 'font-lock-face 'bold)
          (agent-shell-dispatch-msg-task-completed-summary msg)))

(cl-defmethod agent-shell-dispatch-msg-render
  ((msg agent-shell-dispatch-msg-error))
  "Render error MSG with description and context."
  (let ((desc (agent-shell-dispatch-msg-error-description msg))
        (ctx (agent-shell-dispatch-msg-error-context msg)))
    (concat (propertize "❌ " 'font-lock-face 'error)
            (propertize desc 'font-lock-face 'error)
            (when ctx (concat "\n\n" ctx)))))

;; ── Summary methods (fragment label-right) ─────────────────────────

(cl-defmethod agent-shell-dispatch-msg-summary
  ((msg agent-shell-dispatch-msg-batch-progress))
  (let ((phase (agent-shell-dispatch-msg-batch-progress-phase msg))
        (done (agent-shell-dispatch-msg-batch-progress-completed msg))
        (total (agent-shell-dispatch-msg-batch-progress-total msg)))
    (concat (propertize "📋 " 'font-lock-face 'success)
            (propertize (format "%s (%d/%d)" phase done total)
                        'font-lock-face 'font-lock-function-name-face))))

(cl-defmethod agent-shell-dispatch-msg-summary
  ((_msg agent-shell-dispatch-msg-batch-completed))
  (concat (propertize "✅ " 'font-lock-face 'success)
          (propertize "Batch complete" 'font-lock-face 'bold)))

(cl-defmethod agent-shell-dispatch-msg-summary
  ((msg agent-shell-dispatch-msg-task-progress))
  (concat (propertize "📋 " 'font-lock-face 'success)
          (agent-shell-dispatch-msg-task-progress-phase msg)))

(cl-defmethod agent-shell-dispatch-msg-summary
  ((_msg agent-shell-dispatch-msg-task-completed))
  (concat (propertize "✅ " 'font-lock-face 'success)
          (propertize "Task complete" 'font-lock-face 'bold)))

;; ── Detail methods (fragment body, nil = no collapse) ─────────────

(cl-defmethod agent-shell-dispatch-msg-detail
  ((msg agent-shell-dispatch-msg-batch-completed))
  (agent-shell-dispatch-msg-batch-completed-summary msg))

(cl-defmethod agent-shell-dispatch-msg-detail
  ((msg agent-shell-dispatch-msg-task-completed))
  (agent-shell-dispatch-msg-task-completed-summary msg))

;; ── Frame-based send (not collapsible) ─────────────────────────────

(defun agent-shell-dispatch-msg--send-framed (msg target-buf)
  "Send MSG to TARGET-BUF with frame rendering (not collapsible)."
  (when-let* ((buf (get-buffer target-buf)))
    (let* ((body (agent-shell-dispatch-msg-render msg))
           (agent (agent-shell-dispatch-msg-agent-buffer msg))
           (text (agent-shell-dispatch-msg--frame agent body)))
      (agent-shell-dispatch-msg--insert-before-prompt buf text)
      (agent-shell-dispatch-msg-handle msg target-buf))))

(cl-defmethod agent-shell-dispatch-msg-send
  ((msg agent-shell-dispatch-msg-input-needed) target-buf)
  "Send input-needed MSG with frame rendering.
Questions from subagents stay visible, not collapsed."
  (agent-shell-dispatch-msg--send-framed msg target-buf))

(cl-defmethod agent-shell-dispatch-msg-send
  ((msg agent-shell-dispatch-msg-error) target-buf)
  "Send error MSG with frame rendering.
Errors stay visible, not collapsed."
  (agent-shell-dispatch-msg--send-framed msg target-buf))

;; ── Permission state ────────────────────────────────────────────────

(defvar agent-shell-dispatch-msg--pending-permission-agents nil
  "List of agent buffer names with unresolved permission dialogs.")

(defvar agent-shell-dispatch-msg--pending-input-agents nil
  "List of agent buffer names waiting for dispatcher input.")

(defun agent-shell-dispatch-msg--cleanup-permission
    (perm-id target-buf agent-buf option-id)
  "Remove the permission dialog identified by PERM-ID from TARGET-BUF.
AGENT-BUF and OPTION-ID label the replacement text."
  (when-let* ((buf (get-buffer target-buf)))
    (with-current-buffer buf
      (save-excursion
        (let ((inhibit-read-only t))
          (goto-char (point-min))
          (when-let* ((match (text-property-search-forward
                              'agent-shell-dispatch-msg-perm-id perm-id t)))
            (let ((start (prop-match-beginning match))
                  (end (prop-match-end match)))
              (delete-region start end)
              (goto-char start)
              (insert (propertize
                       (format "    ✓ %s — %s\n" agent-buf option-id)
                       'font-lock-face 'font-lock-comment-face
                       'read-only t)))))))))

(defun agent-shell-dispatch-msg--make-respond-action
    (respond option-id agent-buf perm-id target-name)
  "Create a permission button action calling RESPOND and cleaning up.
OPTION-ID, AGENT-BUF, PERM-ID, and TARGET-NAME identify the dialog."
  (lambda ()
    (interactive)
    (funcall respond option-id)
    (setq agent-shell-dispatch-msg--pending-permission-agents
          (delete agent-buf
                  agent-shell-dispatch-msg--pending-permission-agents))
    (agent-shell-dispatch-msg--cleanup-permission
     perm-id target-name agent-buf option-id)))

(defun agent-shell-dispatch-msg--make-permission-buttons
    (options keymap respond agent-buf perm-id target-name)
  "Build permission button string from OPTIONS, binding keys in KEYMAP.
RESPOND is called with the chosen option-id.  AGENT-BUF, PERM-ID, and
TARGET-NAME are forwarded to the response action."
  (mapconcat
   (lambda (opt)
     (let ((action (agent-shell-dispatch-msg--make-respond-action
                    respond (map-elt opt :option-id)
                    agent-buf perm-id target-name)))
       (when-let* ((char-str (map-elt opt :char)))
         (define-key keymap (kbd char-str) action))
       (agent-shell--make-permission-button
        :text (map-elt opt :label)
        :help (map-elt opt :label)
        :action action
        :keymap keymap
        :char (map-elt opt :char)
        :option (or (map-elt opt :option) (map-elt opt :label))
        :navigatable t)))
   options " "))

(defun agent-shell-dispatch-msg--make-view-button
    (diff options respond keymap agent-buf perm-id target-name)
  "Create a View (v) button that opens ediff for DIFF.
OPTIONS and RESPOND wire accept/reject in the ediff session.
KEYMAP receives the `v' binding.  AGENT-BUF, PERM-ID, and TARGET-NAME
identify the dialog to remove on accept/reject."
  (let* ((old (map-elt diff :old))
         (new (map-elt diff :new))
         (file (map-elt diff :file))
         (accept-opt (seq-find (lambda (o)
                                 (equal (map-elt o :kind) "allow_once"))
                               options))
         (reject-opt (seq-find (lambda (o)
                                 (equal (map-elt o :kind) "reject_once"))
                               options))
         (view-action
          (lambda ()
            (interactive)
            (agent-shell-diff
             :old (or old "")
             :new (or new "")
             :file file
             :title (and file (file-name-nondirectory file))
             :on-accept (when accept-opt
                          (lambda ()
                            (funcall respond (map-elt accept-opt :option-id))
                            (setq agent-shell-dispatch-msg--pending-permission-agents
                                  (delete agent-buf
                                          agent-shell-dispatch-msg--pending-permission-agents))
                            (agent-shell-dispatch-msg--cleanup-permission
                             perm-id target-name agent-buf
                             (map-elt accept-opt :option-id))))
             :on-reject (when reject-opt
                          (lambda ()
                            (funcall respond (map-elt reject-opt :option-id))
                            (setq agent-shell-dispatch-msg--pending-permission-agents
                                  (delete agent-buf
                                          agent-shell-dispatch-msg--pending-permission-agents))
                            (agent-shell-dispatch-msg--cleanup-permission
                             perm-id target-name agent-buf
                             (map-elt reject-opt :option-id))))))))
    (define-key keymap "v" view-action)
    (agent-shell--make-permission-button
     :text "View (v)"
     :help "Press v to view diff"
     :action view-action
     :keymap keymap
     :char "v"
     :option "View"
     :navigatable t)))

(cl-defmethod agent-shell-dispatch-msg-render
  ((msg agent-shell-dispatch-msg-permission))
  "Render permission MSG as interactive button block.
Returns propertized text with keymap for button interaction."
  (let* ((tool-call (agent-shell-dispatch-msg-permission-tool-call msg))
         (options (agent-shell-dispatch-msg-permission-options msg))
         (respond (agent-shell-dispatch-msg-permission-respond msg))
         (agent-buf (agent-shell-dispatch-msg-agent-buffer msg))
         (title (or (map-elt tool-call :title) "unknown"))
         (kind (or (map-elt tool-call :kind) "unknown"))
         (diff (map-elt tool-call :diff))
         (perm-id (format "perm-%s-%s" agent-buf (random)))
         (keymap (make-sparse-keymap))
         ;; Build option buttons
         (buttons (agent-shell-dispatch-msg--make-permission-buttons
                   options keymap respond agent-buf perm-id
                   (or agent-shell-dispatch--primary-buffer "")))
         ;; Add View button if diff available
         (view-btn (when diff
                     (agent-shell-dispatch-msg--make-view-button
                      diff options respond keymap agent-buf perm-id
                      (or agent-shell-dispatch--primary-buffer ""))))
         (all-buttons (if view-btn
                         (concat view-btn " " buttons)
                       buttons))
         (text (concat
                (propertize "⚠ " 'font-lock-face 'warning)
                (propertize (format "Permission: %s" agent-buf)
                            'font-lock-face 'bold)
                " "
                (propertize "⚠" 'font-lock-face 'warning)
                "\n\n"
                (propertize (format "%s (%s)" title kind)
                            'font-lock-face 'comint-highlight-input)
                "\n\n"
                all-buttons)))
    (put-text-property 0 (length text) 'keymap keymap text)
    (put-text-property 0 (length text)
                       'agent-shell-dispatch-msg-perm-id perm-id text)
    text))

(cl-defmethod agent-shell-dispatch-msg-handle
  ((msg agent-shell-dispatch-msg-permission) _target-buf)
  "Track MSG agent as having a pending permission."
  (cl-pushnew (agent-shell-dispatch-msg-agent-buffer msg)
              agent-shell-dispatch-msg--pending-permission-agents
              :test #'equal))

(cl-defmethod agent-shell-dispatch-msg-send
  ((msg agent-shell-dispatch-msg-permission) target-buf)
  "Send permission MSG to TARGET-BUF: render with frame, insert, handle.
Permission render returns text with embedded keymap that must be preserved."
  (when-let* ((buf (get-buffer target-buf)))
    (let* ((body (agent-shell-dispatch-msg-render msg))
           (agent (agent-shell-dispatch-msg-agent-buffer msg))
           (text (agent-shell-dispatch-msg--frame agent body)))
      ;; Preserve the keymap and perm-id from the body across the frame
      (when-let* ((km (get-text-property 0 'keymap body)))
        (put-text-property 0 (length text) 'keymap km text))
      (when-let* ((pid (get-text-property 0
                         'agent-shell-dispatch-msg-perm-id body)))
        (put-text-property 0 (length text)
                           'agent-shell-dispatch-msg-perm-id pid text))
      (agent-shell-dispatch-msg--insert-before-prompt buf text)
      (agent-shell-dispatch-msg-handle msg target-buf))))

;; ── Handle methods ──────────────────────────────────────────────────

(cl-defmethod agent-shell-dispatch-msg-handle
  ((msg agent-shell-dispatch-msg-input-needed) target-buf)
  "Queue MSG question to the dispatcher agent in TARGET-BUF.
Also tracks the agent as waiting for input."
  (let ((agent (agent-shell-dispatch-msg-agent-buffer msg)))
    (cl-pushnew agent agent-shell-dispatch-msg--pending-input-agents
                :test #'equal)
    (when-let* ((buf (get-buffer target-buf)))
      (with-current-buffer buf
        (let ((question (agent-shell-dispatch-msg-input-needed-question msg))
              (context (agent-shell-dispatch-msg-input-needed-context msg)))
          (agent-shell--enqueue-request
           :prompt (format "[Input Needed: %s]\n\n%s%s\n\nRespond via (agent-shell-dispatch-send-to-agent \"%s\" YOUR_ANSWER \"dispatcher\")"
                           agent question
                           (if context (format "\n\nContext: %s" context) "")
                           agent)))))))

(provide 'agent-shell-dispatch-messages)
;;; agent-shell-dispatch-messages.el ends here
