;;; agent-shell-dispatch-state.el --- Dispatch state structs and accessors -*- lexical-binding: t; -*-

;;; Commentary:

;; Core data structures for dispatch sessions: state container, agent info,
;; reported/resolved status structs, and their pure accessors.

;;; Code:

(require 'cl-lib)

(declare-function agent-shell-unsubscribe "agent-shell")
(declare-function shell-maker-busy "shell-maker")

;; ── Structs ───────────────────────────────────────────────────────────

(cl-defstruct (agent-shell-dispatch-state
               (:constructor agent-shell-dispatch-state-make)
               (:copier nil))
  "Active dispatch session state."
  dispatcher-buffer tasks statuses agents turn-complete-subscription)

(cl-defstruct (agent-shell-dispatch-agent-info
               (:constructor agent-shell-dispatch-agent-info-make)
               (:copier nil))
  "Tracked agent with display name and activity state."
  buffer name busy)

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

;; ── Buffer-local state ────────────────────────────────────────────────

(defvar-local agent-shell-dispatch--primary-buffer nil
  "Buffer name of the primary (dispatcher) shell for permission rendering.")

(defvar-local agent-shell-dispatch--state nil
  "Dispatch session state for this buffer.")

;; ── State mutation ────────────────────────────────────────────────────

(defun agent-shell-dispatch--record-report (task-id status &optional detail)
  "Record STATUS for TASK-ID in the current dispatch buffer."
  (when-let* ((state agent-shell-dispatch--state)
              (statuses (agent-shell-dispatch-state-statuses state)))
    (puthash task-id
             (agent-shell-dispatch-reported-status-make
              :status (intern status)
              :detail detail
              :updated (current-time))
             statuses)))

(defun agent-shell-dispatch--clear-state ()
  "Clear dispatch state and unsubscribe from events. Used as teardown hook."
  (when-let* ((state agent-shell-dispatch--state)
              (token (agent-shell-dispatch-state-turn-complete-subscription state)))
    (ignore-errors (agent-shell-unsubscribe :subscription token)))
  (setq agent-shell-dispatch--state nil))

;; ── Status resolution ─────────────────────────────────────────────────

(defun agent-shell-dispatch--resolve-status (task statuses)
  "Determine effective status for TASK given STATUSES hash.
Returns a agent-shell-dispatch-resolved-status struct.
Status is driven by explicit reports via `agent-shell-dispatch-report'.
Tasks without a report are `not-started'.
An agent reported as working but now idle (not busy) is treated as done."
  (let* ((id (plist-get task :id))
         (agent-buf (plist-get task :agent))
         (buf (get-buffer agent-buf))
         (alive (and buf (get-buffer-process buf)))
         (busy (and buf (with-current-buffer buf (shell-maker-busy))))
         (reported (gethash id statuses))
         (rep-status (and reported (agent-shell-dispatch-reported-status-status reported)))
         (rep-detail (and reported (agent-shell-dispatch-reported-status-detail reported)))
         (effective (cond
                     ((eq rep-status 'done) 'done)
                     ((eq rep-status 'error) 'error)
                     ((eq rep-status 'working)
                      (cond
                       ((not alive) 'dead)
                       ((not busy) 'done)
                       (t 'working)))
                     ((eq rep-status 'claimed) 'claimed)
                     (t 'not-started))))
    (agent-shell-dispatch-resolved-status-make
     :effective effective
     :detail (and rep-detail (memq effective '(working permission)) rep-detail))))

;; ── Agent activity accessors ──────────────────────────────────────────

(defun agent-shell-dispatch--update-agent-activity ()
  "Update busy state for all tracked agents via `shell-maker-busy'.
Called each render frame from the dispatcher buffer."
  (when-let* ((state agent-shell-dispatch--state)
              (agents (agent-shell-dispatch-state-agents state)))
    (maphash (lambda (_name info)
               (let ((buf (get-buffer (agent-shell-dispatch-agent-info-buffer info))))
                 (setf (agent-shell-dispatch-agent-info-busy info)
                       (and buf
                            (buffer-live-p buf)
                            (with-current-buffer buf (shell-maker-busy))))))
             agents)))

(defun agent-shell-dispatch--get-agents ()
  "Update busy states and return the agents hash for the renderer."
  (agent-shell-dispatch--update-agent-activity)
  (when-let* ((state agent-shell-dispatch--state))
    (agent-shell-dispatch-state-agents state)))

(defun agent-shell-dispatch-agent-buffer (name)
  "Look up the full buffer name for agent with display NAME.
Returns the buffer name string, or nil if not found."
  (when-let* ((state agent-shell-dispatch--state)
              (agents (agent-shell-dispatch-state-agents state))
              (info (gethash name agents)))
    (agent-shell-dispatch-agent-info-buffer info)))

(provide 'agent-shell-dispatch-state)
;;; agent-shell-dispatch-state.el ends here
