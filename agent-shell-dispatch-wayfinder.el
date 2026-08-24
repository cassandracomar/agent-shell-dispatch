;;; agent-shell-dispatch-wayfinder.el --- Bridge between wayfinder maps and dispatch -*- lexical-binding: t; -*-

;;; Commentary:

;; Reads a wayfinder map's tickets and blocking edges from the issue tracker,
;; converts them into a dispatch task graph, and keeps the SVG header in sync
;; as tickets are claimed/resolved.
;;
;; Supports two tracker backends:
;;   - Local markdown (.scratch/<effort>/issues/) -- the default
;;   - GitHub Issues (via `gh` CLI)
;;
;; The bridge handles the fog-of-war pattern: as wayfinder resolves tickets
;; and graduates fog into new tickets, `agent-shell-dispatch-wayfinder-refresh'
;; incrementally adds/removes nodes without restarting the full dispatch session.
;;
;; Usage:
;;   ;; Local markdown (default):
;;   (agent-shell-dispatch-wayfinder-load "my-effort")
;;
;;   ;; GitHub Issues:
;;   (agent-shell-dispatch-wayfinder-load "my-effort" :backend 'github)
;;
;;   ;; After any ticket state change:
;;   (agent-shell-dispatch-wayfinder-refresh)
;;
;;   ;; Tear down:
;;   (agent-shell-dispatch-wayfinder-unload)

;;; Code:

(require 'cl-lib)
(require 'agent-shell-dispatch)

(defvar-local agent-shell-dispatch-wayfinder--effort nil
  "Active wayfinder effort slug for this buffer.")

(defvar-local agent-shell-dispatch-wayfinder--backend nil
  "Active tracker backend symbol: `local' or `github'.")

(defvar-local agent-shell-dispatch-wayfinder--known-ids nil
  "Set of ticket IDs currently in the dispatch graph.")

(defvar-local agent-shell-dispatch-wayfinder--file-watcher nil
  "File-notify descriptor for the local backend's issues directory.")

(defvar-local agent-shell-dispatch-wayfinder--poll-timer nil
  "Timer for periodic refresh (used by the github backend).")

(defcustom agent-shell-dispatch-wayfinder-poll-interval 5.0
  "Seconds between GitHub backend poll refreshes."
  :type 'number
  :group 'agent-shell-dispatch)

(defcustom agent-shell-dispatch-wayfinder-auto-start t
  "When non-nil, automatically start tickets whose blockers are all done."
  :type 'boolean
  :group 'agent-shell-dispatch)

;; ── Normalized ticket format ───────────────────────────────────────────
;;
;; Both backends produce tickets as plists:
;;   (:id STRING :name STRING :type STRING :status STRING :blocked-by (STRING ...))
;;
;; :id         -- unique identifier (file number or issue number, as string)
;; :name       -- human-readable ticket name
;; :type       -- "research" | "prototype" | "grilling" | "task" | nil
;; :status     -- "resolved" | "claimed" | nil (open/unclaimed)
;; :blocked-by -- list of IDs this ticket depends on

;; ── Local markdown backend ─────────────────────────────────────────────

(defun agent-shell-dispatch-wayfinder--local-effort-dir (effort)
  "Return the absolute path to EFFORT's directory under .scratch/."
  (let ((root (or (when-let* ((proj (project-current)))
                    (project-root proj))
                  default-directory)))
    (expand-file-name (format ".scratch/%s" effort) root)))

(defun agent-shell-dispatch-wayfinder--local-parse-ticket (file)
  "Parse a local-markdown wayfinder ticket FILE into a normalized plist."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let* ((basename (file-name-nondirectory file))
             (id (when (string-match "\\`\\([0-9]+\\)-" basename)
                   (match-string 1 basename)))
             (name (when (string-match "\\`[0-9]+-\\(.+\\)\\.md\\'" basename)
                     (replace-regexp-in-string "-" " " (match-string 1 basename))))
             (type (when (re-search-forward "^Type:\\s-*\\(\\S-+\\)" nil t)
                    (match-string 1)))
             (status (progn (goto-char (point-min))
                            (when (re-search-forward "^Status:\\s-*\\(\\S-+\\)" nil t)
                              (match-string 1))))
             (blocked-by (progn (goto-char (point-min))
                                (when (re-search-forward "^Blocked by:[ \t]*\\([^\n]+\\)" nil t)
                                  (let ((raw (string-trim (match-string 1))))
                                    (when (not (string-empty-p raw))
                                      (mapcar (lambda (s)
                                                (string-trim (replace-regexp-in-string "^0+" "" s)))
                                              (split-string raw ","))))))))
        (when id
          (list :id (replace-regexp-in-string "^0+" "" id)
                :name (or name basename)
                :type type
                :status status
                :blocked-by blocked-by))))))

(defun agent-shell-dispatch-wayfinder--local-scan (effort)
  "Scan local-markdown tickets for EFFORT. Returns normalized ticket list."
  (let* ((effort-dir (agent-shell-dispatch-wayfinder--local-effort-dir effort))
         (issues-dir (expand-file-name "issues" effort-dir))
         (files (when (file-directory-p issues-dir)
                  (directory-files issues-dir t "\\`[0-9]+-.*\\.md\\'"))))
    (sort (delq nil (mapcar #'agent-shell-dispatch-wayfinder--local-parse-ticket files))
          (lambda (a b) (< (string-to-number (plist-get a :id))
                           (string-to-number (plist-get b :id)))))))

;; ── GitHub Issues backend ──────────────────────────────────────────────

(defun agent-shell-dispatch-wayfinder--github-parse-type (labels)
  "Extract wayfinder ticket type from LABELS list of label name strings."
  (cl-loop for label in labels
           when (string-match "\\`wayfinder:\\(.+\\)" label)
           return (let ((type (match-string 1 label)))
                    (unless (equal type "map") type))))

(defun agent-shell-dispatch-wayfinder--github-parse-blocked-by (body)
  "Extract blocked-by IDs from issue BODY text.
Looks for lines like 'Blocked by: #1, #2' or 'Blocked by #1, #2'."
  (when (and body (string-match "^Blocked by:?\\s-*\\(.+\\)" body))
    (let ((raw (match-string 1 body)))
      (mapcar (lambda (s)
                (string-trim (replace-regexp-in-string "^#" "" s)))
              (split-string raw "[,;]")))))

(defun agent-shell-dispatch-wayfinder--github-issue-status (issue)
  "Derive normalized status from a GitHub ISSUE plist.
ISSUE has :state and :assignees."
  (let ((state (plist-get issue :state))
        (assignees (plist-get issue :assignees)))
    (cond
     ((equal state "closed") "resolved")
     ((and assignees (not (seq-empty-p assignees))) "claimed")
     (t nil))))

(defun agent-shell-dispatch-wayfinder--github-scan (effort)
  "Fetch GitHub Issues for wayfinder EFFORT (the map issue title or label).
Uses `gh issue list` to find child tickets. Returns normalized ticket list."
  (let* ((json-str (shell-command-to-string
                    (format "gh issue list --label wayfinder --state all --limit 200 --json number,title,labels,state,assignees,body 2>/dev/null")))
         (issues (condition-case nil
                     (json-parse-string json-str :object-type 'plist :array-type 'list)
                   (error nil))))
    (when issues
      (let ((map-number nil)
            (tickets nil))
        ;; Find the map issue
        (dolist (issue issues)
          (let* ((labels (mapcar (lambda (l) (plist-get l :name))
                                 (plist-get issue :labels)))
                 (is-map (member "wayfinder:map" labels))
                 (title (plist-get issue :title)))
            (when (and is-map (or (string-match-p (regexp-quote effort) title)
                                  (string-match-p (regexp-quote effort)
                                                  (or (plist-get issue :body) ""))))
              (setq map-number (plist-get issue :number)))))
        ;; Collect child tickets (non-map wayfinder issues)
        (dolist (issue issues)
          (let* ((labels (mapcar (lambda (l) (plist-get l :name))
                                 (plist-get issue :labels)))
                 (type (agent-shell-dispatch-wayfinder--github-parse-type labels))
                 (body (plist-get issue :body)))
            (when (and type (not (member "wayfinder:map" labels)))
              (push (list :id (number-to-string (plist-get issue :number))
                          :name (plist-get issue :title)
                          :type type
                          :status (agent-shell-dispatch-wayfinder--github-issue-status issue)
                          :blocked-by (agent-shell-dispatch-wayfinder--github-parse-blocked-by body))
                    tickets))))
        (sort tickets (lambda (a b) (< (string-to-number (plist-get a :id))
                                       (string-to-number (plist-get b :id)))))))))

;; ── Backend dispatch ───────────────────────────────────────────────────

(defun agent-shell-dispatch-wayfinder--scan-tickets (effort backend)
  "Scan tickets for EFFORT using BACKEND (symbol: `local' or `github')."
  (pcase backend
    ('github (agent-shell-dispatch-wayfinder--github-scan effort))
    (_ (agent-shell-dispatch-wayfinder--local-scan effort))))

;; ── Status mapping ─────────────────────────────────────────────────────

(defun agent-shell-dispatch-wayfinder--ticket-dispatch-status (ticket)
  "Map TICKET's tracker status to a dispatch status string."
  (pcase (plist-get ticket :status)
    ("resolved" "done")
    ("claimed"  "claimed")
    (_          "waiting")))

;; ── Graph construction ─────────────────────────────────────────────────

(defun agent-shell-dispatch-wayfinder--type-icon (type)
  "Return a short icon prefix for ticket TYPE."
  (pcase type
    ("research"  "R")
    ("prototype" "P")
    ("grilling"  "G")
    ("task"      "T")
    (_           "?")))

(defun agent-shell-dispatch-wayfinder--ticket-to-task (ticket)
  "Convert a single TICKET plist to a dispatch task plist."
  (list :id (plist-get ticket :id)
        :name (format "%s [%s] %s"
                      (plist-get ticket :id)
                      (agent-shell-dispatch-wayfinder--type-icon
                       (plist-get ticket :type))
                      (plist-get ticket :name))
        :depends-on (plist-get ticket :blocked-by)))

(defun agent-shell-dispatch-wayfinder--tickets-to-tasks (tickets)
  "Convert TICKETS to dispatch task plists."
  (mapcar #'agent-shell-dispatch-wayfinder--ticket-to-task tickets))

;; ── Sync logic ─────────────────────────────────────────────────────────

(defun agent-shell-dispatch-wayfinder--sync-statuses (tickets)
  "Report dispatch statuses for all TICKETS based on their tracker state.
Never downgrades: once a ticket reaches working or done via the dispatch
system, the file's claimed/waiting state cannot override it."
  (dolist (ticket tickets)
    (let* ((id (plist-get ticket :id))
           (status (agent-shell-dispatch-wayfinder--ticket-dispatch-status ticket))
           (state agent-shell-dispatch--state)
           (existing (and state
                         (gethash id (agent-shell-dispatch-state-statuses state))))
           (existing-status (and existing
                                 (agent-shell-dispatch-reported-status-status existing))))
      (unless (and (memq existing-status '(working done))
                   (member status '("claimed" "waiting")))
        (agent-shell-dispatch-report id status)))))

(defun agent-shell-dispatch-wayfinder--auto-start-ready (tickets)
  "Start any TICKETS whose blockers are all done and that haven't been claimed.
Only acts when `agent-shell-dispatch-wayfinder-auto-start' is non-nil.
A dependency is considered done only when explicitly reported as done."
  (when agent-shell-dispatch-wayfinder-auto-start
    (let ((state agent-shell-dispatch--state))
      (when state
        (let ((statuses (agent-shell-dispatch-state-statuses state)))
          (dolist (ticket tickets)
            (let* ((id (plist-get ticket :id))
                   (tracker-status (plist-get ticket :status))
                   (existing (gethash id statuses))
                   (dispatch-status (and existing
                                         (agent-shell-dispatch-reported-status-status existing)))
                   (blocked-by (plist-get ticket :blocked-by)))
              (when (and (not tracker-status)
                         (not (memq dispatch-status '(claimed working done)))
                         (or (null blocked-by)
                             (cl-every
                              (lambda (dep-id)
                                (let ((dep (gethash dep-id statuses)))
                                  (and dep (eq 'done (agent-shell-dispatch-reported-status-status dep)))))
                              blocked-by)))
                (agent-shell-dispatch-wayfinder-start-ticket id)))))))))

(defun agent-shell-dispatch-wayfinder--diff-and-apply (tickets)
  "Compute the diff between current graph and TICKETS, apply incrementally.
Adds new tickets, removes gone tickets, updates edges on changed tickets."
  (let* ((current-ids agent-shell-dispatch-wayfinder--known-ids)
         (new-ids (mapcar (lambda (t_) (plist-get t_ :id)) tickets))
         (added (cl-set-difference new-ids current-ids :test #'equal))
         (removed (cl-set-difference current-ids new-ids :test #'equal))
         (retained (cl-intersection current-ids new-ids :test #'equal)))
    ;; Remove tasks that disappeared (out-of-scope'd)
    (dolist (id removed)
      (agent-shell-dispatch-remove-task id))
    ;; Add newly graduated tickets
    (when added
      (let ((new-tasks (cl-remove-if-not
                        (lambda (t_) (member (plist-get t_ :id) added))
                        tickets)))
        (agent-shell-dispatch-add-tasks
         (agent-shell-dispatch-wayfinder--tickets-to-tasks new-tasks))))
    ;; For retained tickets whose deps changed, replace them in-place
    (dolist (id retained)
      (when-let* ((ticket (cl-find-if (lambda (t_) (equal (plist-get t_ :id) id)) tickets))
                  (state agent-shell-dispatch--state)
                  (existing (cl-find-if (lambda (t_) (equal (plist-get t_ :id) id))
                                        (agent-shell-dispatch-state-tasks state)))
                  ((not (equal (plist-get existing :depends-on)
                               (plist-get ticket :blocked-by)))))
        (agent-shell-dispatch-add-task
         (agent-shell-dispatch-wayfinder--ticket-to-task ticket))))
    ;; Update known set
    (setq agent-shell-dispatch-wayfinder--known-ids new-ids)))

;; ── Auto-refresh ──────────────────────────────────────────────────────

(defun agent-shell-dispatch-wayfinder--auto-refresh (_event)
  "Handle a file-notify EVENT by refreshing the dispatch graph."
  (ignore-errors (agent-shell-dispatch-wayfinder-refresh)))

(defun agent-shell-dispatch-wayfinder--start-watching (effort backend)
  "Start auto-refresh for EFFORT using BACKEND.
Local backend uses file-notify; github uses a poll timer."
  (agent-shell-dispatch-wayfinder--stop-watching)
  (pcase backend
    ('local
     (let ((issues-dir (expand-file-name
                        "issues"
                        (agent-shell-dispatch-wayfinder--local-effort-dir effort))))
       (when (file-directory-p issues-dir)
         (setq agent-shell-dispatch-wayfinder--file-watcher
               (file-notify-add-watch
                issues-dir '(change attribute-change)
                #'agent-shell-dispatch-wayfinder--auto-refresh)))))
    ('github
     (let ((buf (current-buffer)))
       (setq agent-shell-dispatch-wayfinder--poll-timer
             (run-with-timer
              agent-shell-dispatch-wayfinder-poll-interval
              agent-shell-dispatch-wayfinder-poll-interval
              (lambda ()
                (when (buffer-live-p buf)
                  (ignore-errors (agent-shell-dispatch-wayfinder-refresh))))))))))

(defun agent-shell-dispatch-wayfinder--stop-watching ()
  "Stop any active file watcher or poll timer."
  (when agent-shell-dispatch-wayfinder--file-watcher
    (file-notify-rm-watch agent-shell-dispatch-wayfinder--file-watcher)
    (setq agent-shell-dispatch-wayfinder--file-watcher nil))
  (when agent-shell-dispatch-wayfinder--poll-timer
    (cancel-timer agent-shell-dispatch-wayfinder--poll-timer)
    (setq agent-shell-dispatch-wayfinder--poll-timer nil)))

;; ── Ticket mutation ────────────────────────────────────────────────────

(defun agent-shell-dispatch-wayfinder--local-find-file (effort id)
  "Return the absolute path of ticket ID within EFFORT, or nil."
  (let* ((issues-dir (expand-file-name
                      "issues"
                      (agent-shell-dispatch-wayfinder--local-effort-dir effort)))
         (files (when (file-directory-p issues-dir)
                  (directory-files issues-dir t "\\`[0-9]+-.*\\.md\\'"))))
    (cl-find-if
     (lambda (f)
       (let ((basename (file-name-nondirectory f)))
         (and (string-match "\\`\\([0-9]+\\)-" basename)
              (equal (replace-regexp-in-string "^0+" "" (match-string 1 basename))
                     (replace-regexp-in-string "^0+" "" id)))))
     files)))

(defun agent-shell-dispatch-wayfinder--local-set-status (file status)
  "Set STATUS in the frontmatter of ticket FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (if (re-search-forward "^Status:\\s-*.*$" nil t)
        (replace-match (format "Status: %s" status))
      (goto-char (point-min))
      (end-of-line)
      (insert (format "\nStatus: %s" status)))
    (write-region (point-min) (point-max) file nil 'silent)))

(defun agent-shell-dispatch-wayfinder--local-ticket-body (file)
  "Extract the body text (below the heading) from ticket FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (if (re-search-forward "^# " nil t)
        (let ((start (line-beginning-position 2)))
          (string-trim (buffer-substring-no-properties start (point-max))))
      (string-trim (buffer-substring-no-properties (point-min) (point-max))))))

(defun agent-shell-dispatch-wayfinder--github-claim-ticket (id)
  "Assign the current user to GitHub issue ID, marking it claimed."
  (let ((cmd (format "gh issue edit %s --add-assignee @me 2>/dev/null" id)))
    (shell-command-to-string cmd)))

;; ── Public API ─────────────────────────────────────────────────────────

(defun agent-shell-dispatch-wayfinder--dispatch-buffer ()
  "Return the buffer where dispatch state lives, or nil."
  (ignore-errors (agent-shell-dispatch--resolve-agent-shell-buffer nil t)))

(cl-defun agent-shell-dispatch-wayfinder-load (effort &key backend)
  "Load wayfinder EFFORT and start dispatch with its task graph.
EFFORT is the slug (local) or map title substring (github).
BACKEND is `local' (default) or `github'."
  (interactive "sEffort slug: ")
  (let* ((be (or backend 'local))
         (tickets (agent-shell-dispatch-wayfinder--scan-tickets effort be))
         (tasks (agent-shell-dispatch-wayfinder--tickets-to-tasks tickets))
         (ids (mapcar (lambda (t_) (plist-get t_ :id)) tickets)))
    (unless tickets
      (user-error "No tickets found for effort %S (backend: %s)" effort be))
    (agent-shell-dispatch-start-current tasks)
    ;; Set wayfinder state in the dispatch buffer (where it will be read)
    (with-current-buffer (agent-shell-dispatch-wayfinder--dispatch-buffer)
      (setq agent-shell-dispatch-wayfinder--effort effort
            agent-shell-dispatch-wayfinder--backend be
            agent-shell-dispatch-wayfinder--known-ids ids)
      (agent-shell-dispatch-wayfinder--sync-statuses tickets)
      (agent-shell-dispatch-wayfinder--auto-start-ready tickets)
      (agent-shell-dispatch-wayfinder--start-watching effort be))
    (message "Wayfinder: loaded %d tickets from %s (%s)" (length tickets) effort be)))

(defun agent-shell-dispatch-wayfinder-refresh ()
  "Re-read the active effort and incrementally update the dispatch graph.
Adds nodes for newly graduated tickets, removes out-of-scope'd ones,
and syncs all statuses.  When `agent-shell-dispatch-wayfinder-auto-start'
is non-nil, automatically starts unblocked tickets."
  (interactive)
  (let ((buf (agent-shell-dispatch-wayfinder--dispatch-buffer)))
    (unless buf
      (user-error "No dispatch buffer found"))
    (with-current-buffer buf
      (unless agent-shell-dispatch-wayfinder--effort
        (user-error "No wayfinder effort loaded"))
      (let* ((tickets (agent-shell-dispatch-wayfinder--scan-tickets
                       agent-shell-dispatch-wayfinder--effort
                       agent-shell-dispatch-wayfinder--backend)))
        (agent-shell-dispatch-wayfinder--diff-and-apply tickets)
        (agent-shell-dispatch-wayfinder--sync-statuses tickets)
        (agent-shell-dispatch-wayfinder--auto-start-ready tickets)))))

(defun agent-shell-dispatch-wayfinder-unload ()
  "Stop dispatch and clear all wayfinder and dispatch state."
  (interactive)
  (when-let* ((buf (agent-shell-dispatch-wayfinder--dispatch-buffer)))
    (with-current-buffer buf
      (agent-shell-dispatch-wayfinder--stop-watching)
      (agent-shell-dispatch-stop)
      (agent-shell-dispatch--clear-state)
      (setq agent-shell-dispatch-wayfinder--effort nil
            agent-shell-dispatch-wayfinder--backend nil
            agent-shell-dispatch-wayfinder--known-ids nil))))

(defun agent-shell-dispatch-wayfinder--on-agent-complete ()
  "Handle a subagent's turn completion.
When the agent is no longer busy, reports its task as done and
refreshes to cascade auto-start to unblocked tickets."
  (let ((agent-buf (buffer-name (current-buffer))))
    (run-with-idle-timer
     0.5 nil
     (lambda ()
       (when-let* ((dispatch-buf (ignore-errors
                                   (agent-shell-dispatch-wayfinder--dispatch-buffer))))
         (with-current-buffer dispatch-buf
           (when (and agent-shell-dispatch-wayfinder--effort
                      agent-shell-dispatch--state)
             ;; Find the task owned by this agent and report done if idle
             (let* ((abuf (get-buffer agent-buf))
                    (busy (and abuf (with-current-buffer abuf (shell-maker-busy)))))
               (unless busy
                 (when-let* ((task (cl-find-if
                                    (lambda (t_) (equal (plist-get t_ :agent) agent-buf))
                                    (agent-shell-dispatch-state-tasks agent-shell-dispatch--state))))
                   (agent-shell-dispatch-report (plist-get task :id) "done"))))
             (agent-shell-dispatch-wayfinder-refresh))))))))

(defun agent-shell-dispatch-wayfinder-start-ticket (id &optional message)
  "Claim ticket ID, spawn an agent for it, and mark it working.
MESSAGE overrides the default initial prompt (the ticket body).
Requires an active wayfinder effort."
  (interactive "sTicket ID: ")
  (let ((buf (agent-shell-dispatch-wayfinder--dispatch-buffer)))
    (unless buf
      (user-error "No dispatch buffer found"))
    (with-current-buffer buf
      (unless agent-shell-dispatch-wayfinder--effort
        (user-error "No wayfinder effort loaded"))
      (let* ((effort agent-shell-dispatch-wayfinder--effort)
             (backend agent-shell-dispatch-wayfinder--backend)
             (id-normalized (replace-regexp-in-string "^0+" "" id))
             (ticket (cl-find-if
                      (lambda (t_) (equal (plist-get t_ :id) id-normalized))
                      (agent-shell-dispatch-wayfinder--scan-tickets effort backend))))
        (unless ticket
          (user-error "Ticket %s not found in effort %s" id effort))
        (when (equal (plist-get ticket :status) "resolved")
          (user-error "Ticket %s is already resolved" id))
        ;; Claim in the tracker
        (pcase backend
          ('local
           (when-let* ((file (agent-shell-dispatch-wayfinder--local-find-file effort id)))
             (agent-shell-dispatch-wayfinder--local-set-status file "claimed")))
          ('github
           (agent-shell-dispatch-wayfinder--github-claim-ticket id-normalized)))
        ;; Ensure the graph is rendered (idempotent if already active)
        (unless agent-shell-dispatch-render-mode
          (let ((tasks (agent-shell-dispatch-wayfinder--tickets-to-tasks
                        (agent-shell-dispatch-wayfinder--scan-tickets effort backend))))
            (agent-shell-dispatch-start-current tasks)))
        ;; Build the initial message for the agent
        (let* ((name (plist-get ticket :name))
               (agent-name
                (pcase backend
                  ('local
                   (when-let* ((file (agent-shell-dispatch-wayfinder--local-find-file effort id)))
                     (file-name-sans-extension (file-name-nondirectory file))))
                  (_ (format "%s-%s"
                             id-normalized
                             (replace-regexp-in-string "[^a-z0-9]+" "-"
                                                      (downcase name))))))
               (body (pcase backend
                       ('local
                        (when-let* ((file (agent-shell-dispatch-wayfinder--local-find-file effort id)))
                          (agent-shell-dispatch-wayfinder--local-ticket-body file)))
                       (_ nil)))
               (prompt (or message
                           (format "Work on: %s\n\n%s" name (or body "")))))
          ;; Spawn the agent and wire it to this task
          (let ((agent-buf (agent-shell-dispatch-spawn-agent default-directory agent-name prompt)))
            (when agent-buf
              (setq agent-shell-dispatch-msg--pending-permission-agents
                    (delete agent-buf agent-shell-dispatch-msg--pending-permission-agents))
              (when-let* ((state agent-shell-dispatch--state)
                          (task (cl-find-if
                                 (lambda (t_) (equal (plist-get t_ :id) id-normalized))
                                 (agent-shell-dispatch-state-tasks state))))
                (plist-put task :agent agent-buf))
              ;; Subscribe to subagent completion to trigger auto-start cascade
              (agent-shell-subscribe-to
               :shell-buffer (get-buffer agent-buf)
               :event 'turn-complete
               :on-event (lambda (_event)
                           (agent-shell-dispatch-wayfinder--on-agent-complete)))))
          ;; Report working and refresh
          (agent-shell-dispatch-report id-normalized "working")
          (agent-shell-dispatch-wayfinder-refresh)
          (message "Wayfinder: started ticket %s — %s" id-normalized name))))))

(provide 'agent-shell-dispatch-wayfinder)
;;; agent-shell-dispatch-wayfinder.el ends here
