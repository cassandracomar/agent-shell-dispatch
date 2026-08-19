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
                                (when (re-search-forward "^Blocked by:\\s-*\\(.+\\)" nil t)
                                  (let ((raw (match-string 1)))
                                    (mapcar (lambda (s)
                                              (string-trim (replace-regexp-in-string "^0+" "" s)))
                                            (split-string raw ",")))))))
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
    ("claimed"  "working")
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
        :name (format "[%s] %s"
                      (agent-shell-dispatch-wayfinder--type-icon
                       (plist-get ticket :type))
                      (plist-get ticket :name))
        :depends-on (plist-get ticket :blocked-by)))

(defun agent-shell-dispatch-wayfinder--tickets-to-tasks (tickets)
  "Convert TICKETS to dispatch task plists."
  (mapcar #'agent-shell-dispatch-wayfinder--ticket-to-task tickets))

;; ── Sync logic ─────────────────────────────────────────────────────────

(defun agent-shell-dispatch-wayfinder--sync-statuses (tickets)
  "Report dispatch statuses for all TICKETS based on their tracker state."
  (dolist (ticket tickets)
    (let ((status (agent-shell-dispatch-wayfinder--ticket-dispatch-status ticket)))
      (agent-shell-dispatch-report (plist-get ticket :id) status))))

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
      (agent-shell-dispatch-wayfinder--sync-statuses tickets))
    (message "Wayfinder: loaded %d tickets from %s (%s)" (length tickets) effort be)))

(defun agent-shell-dispatch-wayfinder-refresh ()
  "Re-read the active effort and incrementally update the dispatch graph.
Adds nodes for newly graduated tickets, removes out-of-scope'd ones,
and syncs all statuses. Call after any ticket state change."
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
        (agent-shell-dispatch-wayfinder--sync-statuses tickets)))))

(defun agent-shell-dispatch-wayfinder-unload ()
  "Stop dispatch and clear wayfinder state."
  (interactive)
  (when-let* ((buf (agent-shell-dispatch-wayfinder--dispatch-buffer)))
    (with-current-buffer buf
      (agent-shell-dispatch-stop)
      (setq agent-shell-dispatch-wayfinder--effort nil
            agent-shell-dispatch-wayfinder--backend nil
            agent-shell-dispatch-wayfinder--known-ids nil))))

(provide 'agent-shell-dispatch-wayfinder)
;;; agent-shell-dispatch-wayfinder.el ends here
