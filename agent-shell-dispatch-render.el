;;; agent-shell-dispatch-render.el --- SVG task-graph renderer -*- lexical-binding: t; -*-

;;; Commentary:

;; Pure SVG task-graph renderer for dispatch workflows.
;; No knowledge of agent buffers, processes, permissions, or dispatch lifecycle.
;; Receives fully-resolved task data and produces SVGs.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'svg)

;; ── Color blending (replaces doom-blend) ────────────────────────────

(defun agent-shell-dispatch-render--blend-colors (color1 color2 alpha)
  "Blend COLOR1 and COLOR2 (color names or hex strings) by ALPHA (0-1).
ALPHA=1.0 returns COLOR1, ALPHA=0.0 returns COLOR2."
  (let ((c1 (color-name-to-rgb color1))
        (c2 (color-name-to-rgb color2)))
    (apply #'color-rgb-to-hex
           (append (cl-mapcar (lambda (a b) (+ (* a alpha) (* b (- 1.0 alpha))))
                              c1 c2)
                   '(2)))))

;; ── Structs ─────────────────────────────────────────────────────────

(cl-defstruct (agent-shell-dispatch-render-status-style
               (:constructor agent-shell-dispatch-render-status-style-make)
               (:copier nil))
  "Visual style for one task status."
  bg fg icon)

(cl-defstruct (agent-shell-dispatch-render-theme
               (:constructor agent-shell-dispatch-render-theme-make)
               (:copier nil))
  "Resolved color scheme from current Emacs theme."
  bg fg name-fg dim arrow pill-bg font
  status) ;; alist of (symbol . agent-shell-dispatch-render-status-style)

(cl-defstruct (agent-shell-dispatch-render-task
               (:constructor agent-shell-dispatch-render-task-make)
               (:copier nil))
  "Static task definition — interface type from dispatcher to renderer."
  id name depends-on)

(cl-defstruct (agent-shell-dispatch-render-task-status
               (:constructor agent-shell-dispatch-render-task-status-make)
               (:copier nil))
  "Dynamic per-frame status for one task."
  status detail)

(cl-defstruct (agent-shell-dispatch-render-stack-info
               (:constructor agent-shell-dispatch-render-stack-info-make)
               (:copier nil))
  "Stacking metadata for one level in a vertically-paired column."
  peer-level position)

(cl-defstruct (agent-shell-dispatch-render-topology
               (:constructor agent-shell-dispatch-render-topology-make)
               (:copier nil))
  "Pure graph structure computed from task definitions."
  leveled max-level columns edges stack-map)

(cl-defstruct (agent-shell-dispatch-render-geometry
               (:constructor agent-shell-dispatch-render-geometry-make)
               (:copier nil))
  "Computed spatial layout."
  col-widths col-xs task-heights max-col-h last-col-right)

(cl-defstruct (agent-shell-dispatch-render-col-extent
               (:constructor agent-shell-dispatch-render-col-extent-make)
               (:copier nil))
  "Vertical pixel bounds of a column."
  top bot)

(cl-defstruct (agent-shell-dispatch-render-routing
               (:constructor agent-shell-dispatch-render-routing-make)
               (:copier nil))
  "Bypass arrow routing context."
  col-bounds canvas-h)

(cl-defstruct (agent-shell-dispatch-render-node-edges
               (:constructor agent-shell-dispatch-render-node-edges-make)
               (:copier nil))
  "Connection points for a drawn node."
  left-x right-x cy)

(cl-defstruct (agent-shell-dispatch-render-node-pos
               (:constructor agent-shell-dispatch-render-node-pos-make)
               (:copier nil))
  "Pre-computed position for a node."
  x y w h)

(cl-defstruct (agent-shell-dispatch-render-arrow-spec
               (:constructor agent-shell-dispatch-render-arrow-spec-make)
               (:copier nil))
  "Pre-computed arrow specification."
  x1 y1 x2 y2 bypass-y)

(cl-defstruct (agent-shell-dispatch-render-dimensions
               (:constructor agent-shell-dispatch-render-dimensions-make)
               (:copier nil))
  "SVG width and height."
  w h)

(cl-defstruct (agent-shell-dispatch-render-ctx
               (:constructor agent-shell-dispatch-render-ctx-make)
               (:copier nil))
  "Top-level rendering context. Cached across frames."
  theme topo geom
  node-positions  ;; hash: id -> agent-shell-dispatch-render-node-pos
  node-edges      ;; hash: id -> agent-shell-dispatch-render-node-edges
  arrow-specs     ;; list of agent-shell-dispatch-render-arrow-spec
  stack-arrows    ;; list of (top-node-edges bot-node-pos) for stacked pair arrows
  routing         ;; agent-shell-dispatch-render-routing
  canvas          ;; agent-shell-dispatch-render-dimensions
  has-bypass)     ;; bool — whether any arrows skip levels

;; ── Layout constants ─────────────────────────────────────────────────

(defconst agent-shell-dispatch-render--layout
  '(:node-h 34 :node-pad 8 :col-gap 50 :margin 10
    :pill-w 40 :pill-h 28 :pill-rx 14
    :node-rx 5 :node-max-w 220
    :node-pad-x 4 :node-icon-w 14 :node-text-y 22
    :node-font-size 12 :pill-font-size 14
    :pill-text-y-offset 5 :name-max-len 24
    :arrow-head-len 5 :arrow-head-hw 4.0 :arrow-cp-factor 0.4
    :arrow-stroke-w "1.5" :bg-rx 8
    :stack-vgap 30 :stack-threshold 5 :stack-arrow-overshoot 40)
  "Layout constants for the SVG task graph.")

;; ── Spinner ─────────────────────────────────────────────────────────

(defvar agent-shell-dispatch-render--spinner-frames
  '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "Braille spinner animation frames.")

(defvar agent-shell-dispatch-render--spinner-index 0
  "Current spinner frame index.")

;; ── Theme ───────────────────────────────────────────────────────────

(defvar agent-shell-dispatch-render--theme-cache nil
  "Cached theme color scheme for SVG rendering.")

(defun agent-shell-dispatch-render--theme-colors ()
  "Derive SVG color scheme from current Emacs theme.
Caches the result; call `agent-shell-dispatch-render-refresh-theme' to update."
  (or agent-shell-dispatch-render--theme-cache
      (setq agent-shell-dispatch-render--theme-cache (agent-shell-dispatch-render--compute-theme-colors))))

(defun agent-shell-dispatch-render-refresh-theme ()
  "Recompute cached theme colors."
  (interactive)
  (setq agent-shell-dispatch-render--theme-cache (agent-shell-dispatch-render--compute-theme-colors)))

(defun agent-shell-dispatch-render--resolve-face (face attr)
  "Resolve FACE's ATTR respecting `face-remapping-alist' in the render buffer."
  (let* ((buf (or (and agent-shell-dispatch-render-buffer
                       (get-buffer agent-shell-dispatch-render-buffer))
                  (current-buffer)))
         (remap (with-current-buffer buf
                  (alist-get face face-remapping-alist)))
         (resolved (if (and remap (facep (car remap))) (car remap) face)))
    (funcall (if (eq attr :background) #'face-background #'face-foreground)
             resolved nil t)))

(defun agent-shell-dispatch-render--compute-theme-colors ()
  "Compute SVG color scheme from current Emacs faces.
Respects face remapping (e.g. `solaire-mode') in the dispatcher buffer."
  (let* ((bg  (or (agent-shell-dispatch-render--resolve-face 'header-line :background)
                  (face-background 'header-line nil t)
                  (face-background 'default)))
         (fg  (or (agent-shell-dispatch-render--resolve-face 'default :foreground)
                  (face-foreground 'default)))
         (ok  (or (face-foreground 'success nil t) "#b6e63e"))
         (wrn (or (face-foreground 'warning nil t) "#e2c770"))
         (err (or (face-foreground 'error nil t) "#e74c3c"))
         (dim (or (face-foreground 'font-lock-comment-face nil t) "#75715e"))
         (fnc (or (face-foreground 'font-lock-function-name-face nil t) fg))
         (tint 0.2))
    (let* ((font-family (or (ignore-errors
                              (symbol-name (font-get (face-attribute 'default :font) :family)))
                            "monospace")))
      (agent-shell-dispatch-render-theme-make
       :bg bg :fg fg :name-fg fnc :dim dim
       :font (replace-regexp-in-string "\\\\" "" font-family)
       :arrow (agent-shell-dispatch-render--blend-colors dim bg 0.6)
       :pill-bg (agent-shell-dispatch-render--blend-colors dim bg 0.25)
       :status
       (list (cons 'done       (agent-shell-dispatch-render-status-style-make
                                :bg (agent-shell-dispatch-render--blend-colors ok  bg tint) :fg ok  :icon "✓"))
             (cons 'working    (agent-shell-dispatch-render-status-style-make
                                :bg (agent-shell-dispatch-render--blend-colors wrn bg tint) :fg wrn :icon "⠹"))
             (cons 'permission (agent-shell-dispatch-render-status-style-make
                                :bg (agent-shell-dispatch-render--blend-colors err bg tint) :fg err :icon "🔒"))
             (cons 'waiting    (agent-shell-dispatch-render-status-style-make
                                :bg (agent-shell-dispatch-render--blend-colors dim bg 0.1)  :fg dim :icon "◦"))
             (cons 'error      (agent-shell-dispatch-render-status-style-make
                                :bg (agent-shell-dispatch-render--blend-colors err bg tint) :fg err :icon "✗"))
             (cons 'not-started (agent-shell-dispatch-render-status-style-make
                                :bg (agent-shell-dispatch-render--blend-colors dim bg 0.3)
                                :fg (agent-shell-dispatch-render--blend-colors fg dim 0.5)
                                :icon "·"))
             (cons 'dead       (agent-shell-dispatch-render-status-style-make
                                :bg (agent-shell-dispatch-render--blend-colors dim bg 0.05) :fg dim :icon "?")))))))

;; ── Topology ────────────────────────────────────────────────────────

(defun agent-shell-dispatch-render--compute-levels (tasks-info)
  "Compute topological levels for TASKS-INFO based on :depends-on.
Returns tasks-info with :level added to each entry."
  (let ((id-to-task (make-hash-table :test 'equal))
        (id-to-level (make-hash-table :test 'equal)))
    (dolist (task tasks-info)
      (puthash (plist-get task :id) task id-to-task))
    (cl-labels ((compute (id)
                  (or (gethash id id-to-level)
                      (let* ((task (gethash id id-to-task))
                             (deps (plist-get task :depends-on))
                             (level (if deps
                                        (1+ (cl-loop for d in deps maximize (compute d)))
                                      0)))
                        (puthash id level id-to-level)
                        level))))
      (dolist (task tasks-info) (compute (plist-get task :id))))
    (mapcar (lambda (task)
              (append task (list :level (gethash (plist-get task :id) id-to-level))))
            tasks-info)))

(defun agent-shell-dispatch-render--transitive-reduce (tasks-info)
  "Compute edges for TASKS-INFO.
Returns list of (from-id . to-id) pairs for dependency connections."
  (let (edges)
    (dolist (task tasks-info)
      (dolist (d (plist-get task :depends-on))
        (push (cons d (plist-get task :id)) edges)))
    edges))

(defun agent-shell-dispatch-render--group-by-level (tasks)
  "Group TASKS by :level into a hash of level → task list (preserving order)."
  (let ((columns (make-hash-table))
        (max-level (cl-loop for t_ in tasks maximize (plist-get t_ :level))))
    (dolist (task tasks)
      (push task (gethash (plist-get task :level) columns)))
    (cl-loop for lv from 0 to max-level
             do (puthash lv (nreverse (gethash lv columns)) columns))
    columns))

(defun agent-shell-dispatch-render--compute-stacks (columns max-level)
  "Identify levels to stack vertically as pairs.
Only activates when column count exceeds the stack threshold.
COLUMNS is the level→task hash, MAX-LEVEL the highest index.
Returns a hash of level → stack-info, or nil if not needed."
  (when (>= (1+ max-level) (plist-get agent-shell-dispatch-render--layout :stack-threshold))
    (let ((stack-map (make-hash-table))
          (lv 0))
      (while (<= lv max-level)
        (if (and (<= (1+ lv) max-level)
                 (= 1 (length (gethash lv columns)))
                 (= 1 (length (gethash (1+ lv) columns))))
            (progn
              (puthash lv (agent-shell-dispatch-render-stack-info-make :peer-level (1+ lv) :position 'top) stack-map)
              (puthash (1+ lv) (agent-shell-dispatch-render-stack-info-make :peer-level lv :position 'bottom) stack-map)
              (cl-incf lv 2))
          (cl-incf lv)))
      (when (> (hash-table-count stack-map) 0)
        stack-map))))

;; ── Geometry ────────────────────────────────────────────────────────

(defun agent-shell-dispatch-render--wrap-text (text max-chars)
  "Wrap TEXT into lines of at most MAX-CHARS, breaking at word boundaries."
  (if (<= (length text) max-chars)
      (list text)
    (let ((words (split-string text " ")) lines current-line)
      (dolist (word words)
        (if (and current-line
                 (> (+ (length current-line) 1 (length word)) max-chars))
            (progn (push current-line lines)
                   (setq current-line word))
          (setq current-line (if current-line
                                 (concat current-line " " word)
                               word))))
      (when current-line (push current-line lines))
      (nreverse lines))))

(defun agent-shell-dispatch-render--node-wrap-lines (name node-w)
  "Wrap NAME to fit within NODE-W pixels. Returns list of lines."
  (let* ((L agent-shell-dispatch-render--layout)
         (theme (agent-shell-dispatch-render--theme-colors))
         (font (agent-shell-dispatch-render-theme-font theme))
         (font-size (plist-get L :node-font-size))
         (text-start (+ (plist-get L :node-pad-x) (plist-get L :node-icon-w)))
         (avail-px (- node-w text-start 8))
         ;; Estimate chars from pixel width of a reference character
         (avg-char-w (max 1 (/ (float (agent-shell-dispatch-render--text-pixel-width
                                        "M" font font-size)) 1.0)))
         (avail-chars (max 10 (floor (/ avail-px avg-char-w)))))
    (agent-shell-dispatch-render--wrap-text name avail-chars)))

(defun agent-shell-dispatch-render--task-node-height (task node-w)
  "Compute the height needed for TASK given NODE-W."
  (let* ((L agent-shell-dispatch-render--layout)
         (lines (agent-shell-dispatch-render--node-wrap-lines (plist-get task :name) node-w))
         (base-h (plist-get L :node-h)))
    (if (> (length lines) 1)
        (+ base-h (* (1- (length lines)) (+ (plist-get L :node-font-size) 2)))
      base-h)))

(defun agent-shell-dispatch-render--compute-col-widths (columns max-level &optional stack-map)
  "Compute per-column widths from COLUMNS hash.
MAX-LEVEL is the highest level index.
When STACK-MAP is non-nil, paired levels share width."
  (let* ((L agent-shell-dispatch-render--layout)
         (theme (agent-shell-dispatch-render--theme-colors))
         (font (agent-shell-dispatch-render-theme-font theme))
         (font-size (plist-get L :node-font-size))
         (max-name-len (plist-get L :name-max-len))
         (widths (make-hash-table)))
    (cl-loop for lv from 0 to max-level
             for stack-info = (and stack-map (gethash lv stack-map))
             unless (and stack-info (eq (agent-shell-dispatch-render-stack-info-position stack-info) 'bottom))
             do (let* ((levels-to-measure
                        (if (and stack-info (eq (agent-shell-dispatch-render-stack-info-position stack-info) 'top))
                            (list lv (agent-shell-dispatch-render-stack-info-peer-level stack-info))
                          (list lv)))
                       (max-text-px
                        (cl-loop for mlv in levels-to-measure
                                 for col = (gethash mlv columns)
                                 maximize (cl-loop for t_ in col
                                                   for lines = (agent-shell-dispatch-render--wrap-text
                                                                (plist-get t_ :name) max-name-len)
                                                   maximize (cl-loop for line in lines
                                                                     maximize (agent-shell-dispatch-render--text-pixel-width
                                                                               line font font-size)))))
                       (w (min (+ (plist-get L :node-pad-x)
                                  (plist-get L :node-icon-w)
                                  max-text-px
                                  8) ;; right pad balances icon weight
                               (plist-get L :node-max-w))))
                  (puthash lv w widths)
                  (when (and stack-info (eq (agent-shell-dispatch-render-stack-info-position stack-info) 'top))
                    (puthash (agent-shell-dispatch-render-stack-info-peer-level stack-info) w widths))))
    widths))

(defun agent-shell-dispatch-render--compute-col-x-positions (max-level col-widths &optional stack-map)
  "Compute cumulative x-positions for each level up to MAX-LEVEL.
COL-WIDTHS provides per-level widths.
When STACK-MAP is non-nil, paired levels share x-position."
  (let ((positions (make-hash-table))
        (x (plist-get agent-shell-dispatch-render--layout :margin)))
    (cl-loop for lv from 0 to max-level
             for stack-info = (and stack-map (gethash lv stack-map))
             do (if (and stack-info (eq (agent-shell-dispatch-render-stack-info-position stack-info) 'bottom))
                    (puthash lv (gethash (agent-shell-dispatch-render-stack-info-peer-level stack-info) positions) positions)
                  (puthash lv x positions)
                  (cl-incf x (+ (gethash lv col-widths)
                                (plist-get agent-shell-dispatch-render--layout :col-gap)))))
    positions))

(defun agent-shell-dispatch-render--compute-task-heights (leveled col-widths)
  "Compute per-task heights for LEVELED tasks within COL-WIDTHS."
  (let ((heights (make-hash-table :test 'equal)))
    (dolist (task leveled)
      (puthash (plist-get task :id)
               (agent-shell-dispatch-render--task-node-height
                task (gethash (plist-get task :level) col-widths))
               heights))
    heights))

(defun agent-shell-dispatch-render--col-height (col task-heights node-pad)
  "Compute total height of column COL given TASK-HEIGHTS and NODE-PAD."
  (+ (cl-loop for t_ in col sum (gethash (plist-get t_ :id) task-heights))
     (* (1- (max (length col) 1)) node-pad)))

;; ── Drawing primitives ───────────────────────────────────────────────

(defun agent-shell-dispatch-render--draw-arrow (svg x1 y1 x2 y2 color &optional bypass-y)
  "Draw a curved arrow from (X1,Y1) to (X2,Y2) on SVG with arrowhead.
If BYPASS-Y is non-nil, route the arrow through that Y coordinate
to avoid crossing intermediate boxes."
  (let* ((L agent-shell-dispatch-render--layout)
         (head-len (plist-get L :arrow-head-len))
         (hw (plist-get L :arrow-head-hw))
         (ex (- (float x2) head-len)) (ey (float y2))
         (sw (plist-get L :arrow-stroke-w)))
    ;; Path
    (dom-append-child svg
                      (dom-node 'path
                                `((d . ,(if bypass-y
                                            (let* ((by (float bypass-y))
                                                   (span (- ex (float x1)))
                                                   (rise (min (float (plist-get L :col-gap))
                                                              (/ span 3.0)))
                                                   (jx1 (+ (float x1) rise))
                                                   (jx2 (- ex rise))
                                                   (cp (* 0.55 rise)))
                                              (format "M%f,%f C%f,%f %f,%f %f,%f L%f,%f C%f,%f %f,%f %f,%f"
                                                      (float x1) (float y1)
                                                      (+ (float x1) cp) (float y1)
                                                      (- jx1 cp) by
                                                      jx1 by
                                                      jx2 by
                                                      (+ jx2 cp) by
                                                      (- ex cp) ey
                                                      ex ey))
                                          (let ((cp (* (plist-get L :arrow-cp-factor) (abs (- x2 x1)))))
                                            (format "M%f,%f C%f,%f %f,%f %f,%f"
                                                    (float x1) (float y1)
                                                    (+ x1 cp) (float y1)
                                                    (- x2 cp) (float y2)
                                                    ex ey))))
                                  (stroke . ,color) (stroke-width . ,sw) (fill . "none"))))
    ;; Arrowhead
    (dom-append-child svg
                      (dom-node 'polygon
                                `((points . ,(format "%f,%f %f,%f %f,%f"
                                                     (float x2) (float y2)
                                                     (- ex head-len) (- ey hw)
                                                     (- ex head-len) (+ ey hw)))
                                  (fill . ,color))))))

(defun agent-shell-dispatch-render--draw-stack-arrow (svg top-edges bot-x bot-y bot-w color)
  "Draw a stacked-pair arrow on SVG from top node to bottom node.
TOP-EDGES is the top node's connection points.
BOT-X, BOT-Y, BOT-W define the bottom node's position.
COLOR is the arrow stroke color."
  (let* ((L agent-shell-dispatch-render--layout)
         (x1 (agent-shell-dispatch-render-node-edges-right-x top-edges))
         (y1 (agent-shell-dispatch-render-node-edges-cy top-edges))
         (x2 (+ bot-x (/ bot-w 2)))
         (y2 (float bot-y))
         (ey (+ y2 5))
         (overshoot (plist-get L :stack-arrow-overshoot))
         (cp1-x (+ x1 overshoot))
         (cp1-y (float bot-y))
         (cp2-x (float x2))
         (cp2-y (- y2 20.0))
         (hw (plist-get L :arrow-head-hw))
         (sw (plist-get L :arrow-stroke-w)))
    ;; Path
    (dom-append-child svg
                      (dom-node 'path
                                `((d . ,(format "M%f,%f C%f,%f %f,%f %f,%f"
                                                (float x1) (float y1)
                                                cp1-x cp1-y
                                                cp2-x cp2-y
                                                (float x2) ey))
                                  (stroke . ,color) (stroke-width . ,sw) (fill . "none"))))
    ;; Downward arrowhead
    (dom-append-child svg
                      (dom-node 'polygon
                                `((points . ,(format "%f,%f %f,%f %f,%f"
                                                     (float x2) y2
                                                     (- x2 hw) (- y2 (plist-get L :arrow-head-len))
                                                     (+ x2 hw) (- y2 (plist-get L :arrow-head-len))))
                                  (fill . ,color))))))

(defun agent-shell-dispatch-render--draw-pill (svg x cy w h icon theme)
  "Draw a pill-shaped start/end node on SVG at X, centered at CY.
W and H are dimensions, ICON is the label, THEME provides colors.
Returns connection edge positions."
  (let ((L agent-shell-dispatch-render--layout))
    (svg-rectangle svg x (- cy (/ h 2)) w h
                   :fill (agent-shell-dispatch-render-theme-pill-bg theme)
                   :rx (plist-get L :pill-rx))
    (svg-text svg icon :x (+ x (/ w 2)) :y (+ cy (plist-get L :pill-text-y-offset))
              :fill (agent-shell-dispatch-render-theme-dim theme)
              :font-size (plist-get L :pill-font-size)
              :font-family (agent-shell-dispatch-render-theme-font theme) :text-anchor "middle")
    (let ((rx (plist-get L :pill-rx)))
      (agent-shell-dispatch-render-node-edges-make :left-x (+ x rx) :right-x (- (+ x w) rx) :cy cy))))

(defun agent-shell-dispatch-render--draw-task-node (svg x y w h task theme)
  "Draw a task node on SVG. W x H is the pre-computed size @ (X, Y).
Returns edge positions."
  (let* ((L agent-shell-dispatch-render--layout)
         (sc (cdr (assq (plist-get task :status) (agent-shell-dispatch-render-theme-status theme))))
         (font (agent-shell-dispatch-render-theme-font theme))
         (pad (plist-get L :node-pad-x))
         (lines (agent-shell-dispatch-render--node-wrap-lines (plist-get task :name) w))
         (font-size (plist-get L :node-font-size))
         (line-h (+ font-size 2))
         (text-x (+ x pad (plist-get L :node-icon-w)))
         (text-y (+ y (plist-get L :node-text-y)))
         (cy (+ y (/ h 2))))
    (svg-rectangle svg x y w h :fill (agent-shell-dispatch-render-status-style-bg sc)
                   :rx (plist-get L :node-rx))
    ;; Icon — vertically centered
    (svg-text svg (agent-shell-dispatch-render-status-style-icon sc) :x (+ x pad) :y (+ cy 4)
              :fill (agent-shell-dispatch-render-status-style-fg sc)
              :font-size font-size :font-family font)
    ;; Text lines
    (cl-loop for line in lines
             for i from 0
             do (svg-text svg line
                          :x text-x :y (+ text-y (* i line-h))
                          :fill (agent-shell-dispatch-render-status-style-fg sc)
                          :font-size font-size :font-family font))
    (let ((rx (plist-get L :node-rx)))
      (agent-shell-dispatch-render-node-edges-make :left-x (+ x rx) :right-x (- (+ x w) rx) :cy cy))))

;; ── Agent activity column ────────────────────────────────────────────

(defun agent-shell-dispatch-render--text-pixel-width (text font-family svg-font-size)
  "Measure pixel width of TEXT as it would render in SVG.
SVG-FONT-SIZE is in px; convert to Emacs face height (1/10 pt)."
  (let* ((height (round (* svg-font-size 7.5))) ;; px → 1/10 pt (96dpi: 1px ≈ 0.75pt)
         (sample (propertize text 'face
                             `(:family ,font-family :height ,height))))
    (string-pixel-width sample)))

(defun agent-shell-dispatch-render--agent-layout (agents h theme)
  "Compute per-column layout for agent activity display.
Returns a plist (:total-w WIDTH :columns COLS :per-col N :sorted LIST).
Each entry in COLS is (:x X :w W :agents LIST-OF-INFO)."
  (let* ((font (agent-shell-dispatch-render-theme-font theme))
         (font-size (- (plist-get agent-shell-dispatch-render--layout :node-font-size) 2))
         (pad-x 2) (row-h 16) (col-gap 4)
         (avail-h (- h 6))
         (sorted (let (entries)
                   (maphash (lambda (_buf info) (push info entries)) agents)
                   (sort entries (lambda (a b)
                                   (string< (agent-shell-dispatch-agent-info-name a)
                                            (agent-shell-dispatch-agent-info-name b))))))
         (n (length sorted))
         (per-col (max 1 (floor avail-h row-h)))
         (cols nil)
         (cur-x 0))
    (cl-loop for start from 0 by per-col
             while (< start n)
             for col-agents = (seq-subseq sorted start (min (+ start per-col) n))
             for max-pw = (cl-loop for info in col-agents
                                   maximize (agent-shell-dispatch-render--text-pixel-width
                                             (agent-shell-dispatch-agent-info-name info)
                                             font font-size))
             for w = (+ (* 2 pad-x) max-pw)
             do (push (list :x cur-x :w w :agents col-agents) cols)
             (setq cur-x (+ cur-x w col-gap)))
    (list :total-w (max 0 (- cur-x col-gap))
          :columns (nreverse cols)
          :per-col per-col)))

(defun agent-shell-dispatch-render--agent-column-width (agents h theme)
  "Compute total pixel width needed for the agent column(s)."
  (plist-get (agent-shell-dispatch-render--agent-layout agents h theme) :total-w))

(defun agent-shell-dispatch-render--draw-agent-column (svg agents x h theme)
  "Draw agent activity indicators as labeled boxes on SVG at X.
Filled box = busy, hollow box = idle. Per-column width fits tightest name."
  (let* ((L agent-shell-dispatch-render--layout)
         (font (agent-shell-dispatch-render-theme-font theme))
         (font-size (plist-get L :node-font-size))
         (pad-x 2) (row-h 16) (box-h 14) (rx 3)
         (ok (or (face-foreground 'success nil t) "#b6e63e"))
         (dim (agent-shell-dispatch-render-theme-dim theme))
         (bg (agent-shell-dispatch-render-theme-bg theme))
         (busy-bg (agent-shell-dispatch-render--blend-colors ok bg 0.2))
         (layout (agent-shell-dispatch-render--agent-layout agents h theme)))
    (dolist (col (plist-get layout :columns))
      (let* ((col-x (+ x (plist-get col :x)))
             (col-w (plist-get col :w))
             (col-agents (plist-get col :agents))
             (col-count (length col-agents))
             (total-col-h (* row-h col-count))
             (start-y (/ (- h total-col-h) 2)))
        (cl-loop for info in col-agents
                 for row from 0
                 for name = (agent-shell-dispatch-agent-info-name info)
                 for busy = (agent-shell-dispatch-agent-info-busy info)
                 for by = (+ start-y (* row row-h) (/ (- row-h box-h) 2))
                 for text-y = (+ by box-h -3)
                 do (if busy
                        (svg-rectangle svg col-x by col-w box-h
                                       :fill busy-bg :stroke ok :stroke-width "1" :rx rx)
                      (svg-rectangle svg col-x by col-w box-h
                                       :fill "none" :stroke dim :stroke-width "0.75" :rx rx))
                 (svg-text svg name
                           :x (+ col-x pad-x) :y text-y
                           :fill (if busy ok dim)
                           :font-size (- font-size 2) :font-family font))))))

;; ── Edge routing ────────────────────────────────────────────────────

(defun agent-shell-dispatch-render--compute-col-bounds (node-edges leveled task-heights node-h &optional stack-map)
  "Compute top/bottom pixel bounds per level from NODE-EDGES.
Uses LEVELED tasks, TASK-HEIGHTS, and NODE-H for sizing.
When STACK-MAP is non-nil, stacked pair levels share merged bounds."
  (let ((col-bounds (make-hash-table)))
    (maphash (lambda (id edges)
               (unless (member id '("start" "end"))
                 (when-let* ((task (cl-find-if (lambda (t_) (equal (plist-get t_ :id) id)) leveled))
                             (lv (plist-get task :level))
                             (cy (agent-shell-dispatch-render-node-edges-cy edges))
                             (th (or (gethash id task-heights) node-h)))
                   (let* ((top (- cy (/ th 2)))
                          (bot (+ cy (/ th 2)))
                          (cur (gethash lv col-bounds)))
                     (puthash lv (agent-shell-dispatch-render-col-extent-make
                                  :top (if cur (min (agent-shell-dispatch-render-col-extent-top cur) top) top)
                                  :bot (if cur (max (agent-shell-dispatch-render-col-extent-bot cur) bot) bot))
                              col-bounds)))))
             node-edges)
    (when stack-map
      (maphash (lambda (lv info)
                 (when (eq (agent-shell-dispatch-render-stack-info-position info) 'top)
                   (let* ((peer (agent-shell-dispatch-render-stack-info-peer-level info))
                          (top-b (gethash lv col-bounds))
                          (bot-b (gethash peer col-bounds)))
                     (when (and top-b bot-b)
                       (let ((merged (agent-shell-dispatch-render-col-extent-make
                                      :top (min (agent-shell-dispatch-render-col-extent-top top-b)
                                                (agent-shell-dispatch-render-col-extent-top bot-b))
                                      :bot (max (agent-shell-dispatch-render-col-extent-bot top-b)
                                                (agent-shell-dispatch-render-col-extent-bot bot-b)))))
                         (puthash lv merged col-bounds)
                         (puthash peer merged col-bounds))))))
               stack-map))
    col-bounds))

(defun agent-shell-dispatch-render--compute-bypass-y (from-lv to-lv from-cy col-bounds h &optional stack-map)
  "Compute bypass Y for an arrow spanning FROM-LV to TO-LV, or nil if not needed.
Starts from FROM-CY, respecting COL-BOUNDS, with height H.
When STACK-MAP is non-nil, also avoids stacked pair bounds at the destination."
  (let ((span (- to-lv from-lv)))
    (when (> span 1)
      (let ((min-top h) (max-bot 0) (has-intermediate nil)
            (check-to (and stack-map (gethash to-lv stack-map)
                           (eq (agent-shell-dispatch-render-stack-info-position (gethash to-lv stack-map)) 'top))))
        (cl-loop for lv from (1+ from-lv) to (if check-to to-lv (1- to-lv))
                 for bounds = (gethash lv col-bounds)
                 when bounds
                 do (setq has-intermediate t
                          min-top (min min-top (agent-shell-dispatch-render-col-extent-top bounds))
                          max-bot (max max-bot (agent-shell-dispatch-render-col-extent-bot bounds))))
        (when has-intermediate
          (let ((pad (+ (plist-get agent-shell-dispatch-render--layout :node-pad) 6)))
            (if (< from-cy (/ h 2))
                (- min-top pad)
              (+ max-bot pad))))))))

;; ── SVG utilities ───────────────────────────────────────────────────

(defun agent-shell-dispatch-render--svg-dimensions (svg-str)
  "Extract dimensions from SVG-STR, or nil."
  (when (string-match "width=\"\\([0-9.]+\\)\"" svg-str)
    (let ((w (string-to-number (match-string 1 svg-str))))
      (when (string-match "height=\"\\([0-9.]+\\)\"" svg-str)
        (agent-shell-dispatch-render-dimensions-make :w w :h (string-to-number (match-string 1 svg-str)))))))

(defun agent-shell-dispatch-render--strip-svg-wrapper (svg-str)
  "Remove the outer <svg>...</svg> tags from SVG-STR."
  (replace-regexp-in-string
   "\\`<svg[^>]*>" ""
   (replace-regexp-in-string "</svg>\\'" "" svg-str)))

(defun agent-shell-dispatch-render-combine-svgs (top-svg bottom-svg gap-above gap-below)
  "Stack TOP-SVG and BOTTOM-SVG vertically with GAP-ABOVE and GAP-BELOW."
  (when-let* ((top-dims (agent-shell-dispatch-render--svg-dimensions top-svg))
              (bot-dims (agent-shell-dispatch-render--svg-dimensions bottom-svg)))
    (let* ((w (max (agent-shell-dispatch-render-dimensions-w top-dims) (agent-shell-dispatch-render-dimensions-w bot-dims)))
           (h (+ (agent-shell-dispatch-render-dimensions-h top-dims) gap-above
                 (agent-shell-dispatch-render-dimensions-h bot-dims) gap-below)))
      (format "<svg width=\"%d\" height=\"%d\" version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">
<svg y=\"0\">%s</svg>
<svg y=\"%d\">%s</svg>
</svg>"
              w h
              (agent-shell-dispatch-render--strip-svg-wrapper top-svg)
              (+ (agent-shell-dispatch-render-dimensions-h top-dims) gap-above)
              (agent-shell-dispatch-render--strip-svg-wrapper bottom-svg)))))

;; ── Prepare/Draw split ───────────────────────────────────────────────

(defun agent-shell-dispatch-render--compute-max-col-h (columns max-level stack-map task-heights layout)
  "Compute the maximum column height across all levels.
Accounts for stacked pairs using COLUMNS, MAX-LEVEL, STACK-MAP,
TASK-HEIGHTS, and LAYOUT constants."
  (let ((node-pad (plist-get layout :node-pad)))
    (cl-loop for lv from 0 to max-level
             for si = (and stack-map (gethash lv stack-map))
             unless (and si (eq (agent-shell-dispatch-render-stack-info-position si) 'bottom))
             maximize (if (and si (eq (agent-shell-dispatch-render-stack-info-position si) 'top))
                          (let* ((bot-lv (agent-shell-dispatch-render-stack-info-peer-level si))
                                 (top-task (car (gethash lv columns)))
                                 (bot-task (car (gethash bot-lv columns)))
                                 (top-h (gethash (plist-get top-task :id) task-heights))
                                 (bot-h (gethash (plist-get bot-task :id) task-heights)))
                            (+ top-h (plist-get layout :stack-vgap) bot-h))
                        (agent-shell-dispatch-render--col-height
                         (gethash lv columns) task-heights node-pad)))))

(defun agent-shell-dispatch-render-prepare (task-defs)
  "Compute topology, geometry, and node positions.
TASK-DEFS is a list of `agent-shell-dispatch-render-task' structs.
Returns a `agent-shell-dispatch-render-ctx' for `agent-shell-dispatch-render-draw'."
  (let* ((L agent-shell-dispatch-render--layout)
         (theme (agent-shell-dispatch-render--theme-colors))
         (node-pad (plist-get L :node-pad))
         (col-gap (plist-get L :col-gap))
         (margin (plist-get L :margin))
         ;; Convert task structs to internal plists for topology functions
         (tasks-info (mapcar (lambda (td)
                               (list :id (agent-shell-dispatch-render-task-id td)
                                     :name (agent-shell-dispatch-render-task-name td)
                                     :depends-on (agent-shell-dispatch-render-task-depends-on td)))
                             task-defs))
         ;; Topology
         (leveled (agent-shell-dispatch-render--compute-levels tasks-info))
         (max-level (cl-loop for t_ in leveled maximize (plist-get t_ :level)))
         (columns (agent-shell-dispatch-render--group-by-level leveled))
         (stack-map (agent-shell-dispatch-render--compute-stacks columns max-level))
         (edges (agent-shell-dispatch-render--transitive-reduce leveled))
         (topo (agent-shell-dispatch-render-topology-make
                :leveled leveled :max-level max-level
                :columns columns :edges edges :stack-map stack-map))
         ;; Geometry
         (col-widths (agent-shell-dispatch-render--compute-col-widths columns max-level stack-map))
         (col-xs (agent-shell-dispatch-render--compute-col-x-positions max-level col-widths stack-map))
         (task-heights (agent-shell-dispatch-render--compute-task-heights leveled col-widths))
         (max-col-h (agent-shell-dispatch-render--compute-max-col-h
                     columns max-level stack-map task-heights L))
         (last-col-right (cl-loop for lv from 0 to max-level
                                  for si = (and stack-map (gethash lv stack-map))
                                  unless (and si (eq (agent-shell-dispatch-render-stack-info-position si) 'bottom))
                                  maximize (+ (gethash lv col-xs) (gethash lv col-widths))))
         (geom (agent-shell-dispatch-render-geometry-make
                :col-widths col-widths :col-xs col-xs
                :task-heights task-heights :max-col-h max-col-h
                :last-col-right last-col-right))
         ;; Canvas dimensions
         (has-bypass (let ((id-lv (make-hash-table :test 'equal)))
                       (dolist (t_ leveled) (puthash (plist-get t_ :id) (plist-get t_ :level) id-lv))
                       (cl-loop for (from . to) in edges
                                thereis (> (- (gethash to id-lv) (gethash from id-lv)) 1))))
         (bypass-pad (if has-bypass (+ node-pad 6 5) 0))
         (w (+ last-col-right margin))
         (h (max (+ (* 2 (+ margin bypass-pad)) max-col-h) 60))
         (canvas (agent-shell-dispatch-render-dimensions-make :w w :h h))
         ;; Pre-compute node positions and edges
         (node-positions (make-hash-table :test 'equal))
         (node-edges-map (make-hash-table :test 'equal))
         (stack-arrows nil))

    ;; Task node positions by column
    (cl-loop
     for lv from 0 to max-level
     for si = (and stack-map (gethash lv stack-map))
     unless (and si (eq (agent-shell-dispatch-render-stack-info-position si) 'bottom))
     do (let* ((col-tasks (gethash lv columns))
               (col-x (gethash lv col-xs))
               (cw (gethash lv col-widths))
               (rx (plist-get L :node-rx)))
          (if (and si (eq (agent-shell-dispatch-render-stack-info-position si) 'top))
              ;; Stacked pair
              (let* ((bot-lv (agent-shell-dispatch-render-stack-info-peer-level si))
                     (top-task (car col-tasks))
                     (bot-task (car (gethash bot-lv columns)))
                     (top-h (gethash (plist-get top-task :id) task-heights))
                     (bot-h (gethash (plist-get bot-task :id) task-heights))
                     (stack-vgap (plist-get L :stack-vgap))
                     (pair-h (+ top-h stack-vgap bot-h))
                     (top-y (/ (- h pair-h) 2))
                     (bot-y (+ top-y top-h stack-vgap))
                     (top-cy (+ top-y (/ top-h 2)))
                     (bot-cy (+ bot-y (/ bot-h 2))))
                ;; Top node
                (puthash (plist-get top-task :id)
                         (agent-shell-dispatch-render-node-pos-make :x col-x :y top-y :w cw :h top-h)
                         node-positions)
                (puthash (plist-get top-task :id)
                         (agent-shell-dispatch-render-node-edges-make
                          :left-x (+ col-x rx) :right-x (- (+ col-x cw) rx) :cy top-cy)
                         node-edges-map)
                ;; Bottom node
                (puthash (plist-get bot-task :id)
                         (agent-shell-dispatch-render-node-pos-make :x col-x :y bot-y :w cw :h bot-h)
                         node-positions)
                (puthash (plist-get bot-task :id)
                         (agent-shell-dispatch-render-node-edges-make
                          :left-x (+ col-x rx) :right-x (- (+ col-x cw) rx) :cy bot-cy)
                         node-edges-map)
                ;; Record stack arrow
                (push (list (gethash (plist-get top-task :id) node-edges-map)
                            (agent-shell-dispatch-render-node-pos-make :x col-x :y bot-y :w cw :h bot-h))
                      stack-arrows))
            ;; Normal column
            (let* ((col-h (agent-shell-dispatch-render--col-height col-tasks task-heights node-pad))
                   (cur-y (/ (- h col-h) 2)))
              (cl-loop
               for task in col-tasks
               for th = (gethash (plist-get task :id) task-heights)
               for cy = (+ cur-y (/ th 2))
               do (puthash (plist-get task :id)
                           (agent-shell-dispatch-render-node-pos-make :x col-x :y cur-y :w cw :h th)
                           node-positions)
               (puthash (plist-get task :id)
                        (agent-shell-dispatch-render-node-edges-make
                         :left-x (+ col-x rx) :right-x (- (+ col-x cw) rx) :cy cy)
                        node-edges-map)
               (cl-incf cur-y (+ th node-pad)))))))

    ;; Pre-compute col-bounds and arrow specs
    (let* ((col-bounds (agent-shell-dispatch-render--compute-col-bounds
                        node-edges-map leveled task-heights (plist-get L :node-h) stack-map))
           (routing (agent-shell-dispatch-render-routing-make :col-bounds col-bounds :canvas-h h))
           (id-to-level (make-hash-table :test 'equal))
           (id-to-stack (when stack-map
                          (let ((m (make-hash-table :test 'equal)))
                            (dolist (task leveled)
                              (when-let* ((si (gethash (plist-get task :level) stack-map)))
                                (puthash (plist-get task :id) si m)))
                            m)))
           (arrow-specs nil))
      (dolist (task leveled) (puthash (plist-get task :id) (plist-get task :level) id-to-level))
      (dolist (edge edges)
        (unless (and id-to-stack
                     (when-let* ((from-si (gethash (car edge) id-to-stack))
                                 (to-si (gethash (cdr edge) id-to-stack)))
                       (and (eq (agent-shell-dispatch-render-stack-info-position from-si) 'top)
                            (eq (agent-shell-dispatch-render-stack-info-position to-si) 'bottom)
                            (= (agent-shell-dispatch-render-stack-info-peer-level from-si)
                               (gethash (cdr edge) id-to-level)))))
          (when-let* ((from (gethash (car edge) node-edges-map))
                      (to (gethash (cdr edge) node-edges-map))
                      (from-lv (gethash (car edge) id-to-level))
                      (to-lv (gethash (cdr edge) id-to-level)))
            (push (agent-shell-dispatch-render-arrow-spec-make
                   :x1 (agent-shell-dispatch-render-node-edges-right-x from)
                   :y1 (agent-shell-dispatch-render-node-edges-cy from)
                   :x2 (agent-shell-dispatch-render-node-edges-left-x to)
                   :y2 (agent-shell-dispatch-render-node-edges-cy to)
                   :bypass-y (agent-shell-dispatch-render--compute-bypass-y
                              from-lv to-lv
                              (agent-shell-dispatch-render-node-edges-cy from)
                              col-bounds h stack-map))
                  arrow-specs))))

      (agent-shell-dispatch-render-ctx-make
       :theme theme :topo topo :geom geom
       :node-positions node-positions
       :node-edges node-edges-map
       :arrow-specs (nreverse arrow-specs)
       :stack-arrows (nreverse stack-arrows)
       :routing routing
       :canvas canvas
       :has-bypass has-bypass))))

(defun agent-shell-dispatch-render-draw (ctx status-map &optional agents)
  "Draw SVG from cached CTX with current STATUS-MAP and optional AGENTS hash.
CTX is a agent-shell-dispatch-render-ctx from `agent-shell-dispatch-render-prepare'.
STATUS-MAP is a hash of task-id -> agent-shell-dispatch-render-task-status.
AGENTS is a hash of buffer-name -> agent-shell-dispatch-agent-info."
  (let* ((L agent-shell-dispatch-render--layout)
         (theme (agent-shell-dispatch-render--theme-colors))
         (topo (agent-shell-dispatch-render-ctx-topo ctx))
         (canvas (agent-shell-dispatch-render-ctx-canvas ctx))
         (w (agent-shell-dispatch-render-dimensions-w canvas))
         (h (agent-shell-dispatch-render-dimensions-h canvas))
         (node-positions (agent-shell-dispatch-render-ctx-node-positions ctx))
         (leveled (agent-shell-dispatch-render-topology-leveled topo))
         ;; Compute agent column width first (tight padding)
         (agent-col-w (if (and agents (> (hash-table-count agents) 0))
                          (+ (agent-shell-dispatch-render--agent-column-width agents h theme) 8)
                        0))
         (svg (svg-create (+ w agent-col-w) h)))

    ;; Background
    (svg-rectangle svg 0 0 (+ w agent-col-w) h
                   :fill (agent-shell-dispatch-render-theme-bg theme)
                   :rx (plist-get L :bg-rx))

    ;; Agent activity column (left side, no margin — header provides padding)
    (when (> agent-col-w 0)
      (agent-shell-dispatch-render--draw-agent-column svg agents 0 h theme))

    ;; Task nodes — offset by agent column width
    (dolist (task leveled)
      (let* ((id (plist-get task :id))
             (pos (gethash id node-positions))
             (ts (gethash id status-map))
             (task-with-status (list :id id
                                     :name (plist-get task :name)
                                     :status (if ts (agent-shell-dispatch-render-task-status-status ts)
                                               'not-started))))
        (agent-shell-dispatch-render--draw-task-node
         svg
         (+ (agent-shell-dispatch-render-node-pos-x pos) agent-col-w)
         (agent-shell-dispatch-render-node-pos-y pos)
         (agent-shell-dispatch-render-node-pos-w pos)
         (agent-shell-dispatch-render-node-pos-h pos)
         task-with-status theme)))

    ;; Arrows from pre-computed specs (offset by agent column)
    (let ((arrow-color (agent-shell-dispatch-render-theme-arrow theme)))
      (dolist (spec (agent-shell-dispatch-render-ctx-arrow-specs ctx))
        (agent-shell-dispatch-render--draw-arrow
         svg
         (+ (agent-shell-dispatch-render-arrow-spec-x1 spec) agent-col-w)
         (agent-shell-dispatch-render-arrow-spec-y1 spec)
         (+ (agent-shell-dispatch-render-arrow-spec-x2 spec) agent-col-w)
         (agent-shell-dispatch-render-arrow-spec-y2 spec)
         arrow-color
         (agent-shell-dispatch-render-arrow-spec-bypass-y spec)))
      ;; Stack arrows
      (dolist (sa (agent-shell-dispatch-render-ctx-stack-arrows ctx))
        (let ((top-edges (car sa))
              (bot-pos (cadr sa)))
          (agent-shell-dispatch-render--draw-stack-arrow
           svg
           (agent-shell-dispatch-render-node-edges-make
            :left-x (+ (agent-shell-dispatch-render-node-edges-left-x top-edges) agent-col-w)
            :right-x (+ (agent-shell-dispatch-render-node-edges-right-x top-edges) agent-col-w)
            :cy (agent-shell-dispatch-render-node-edges-cy top-edges))
           (+ (agent-shell-dispatch-render-node-pos-x bot-pos) agent-col-w)
           (agent-shell-dispatch-render-node-pos-y bot-pos)
           (agent-shell-dispatch-render-node-pos-w bot-pos)
           arrow-color))))

    svg))

(defun agent-shell-dispatch-render-apply-viewport (svg-str ctx status-map dispatcher-buf)
  "Apply viewBox panning to SVG-STR if wider than window.
CTX is the cached agent-shell-dispatch-render-ctx. STATUS-MAP is the per-frame status hash.
DISPATCHER-BUF is the buffer name."
  (when-let* ((dims (agent-shell-dispatch-render--svg-dimensions svg-str))
              (svg-w (agent-shell-dispatch-render-dimensions-w dims))
              (svg-h (agent-shell-dispatch-render-dimensions-h dims))
              (win (get-buffer-window dispatcher-buf))
              (win-pw (window-body-width win t))
              ((> svg-w win-pw)))
    (let* ((topo (agent-shell-dispatch-render-ctx-topo ctx))
           (leveled (agent-shell-dispatch-render-topology-leveled topo))
           (geom (agent-shell-dispatch-render-ctx-geom ctx))
           (col-xs (agent-shell-dispatch-render-geometry-col-xs geom))
           (target-level (or (cl-loop for task in leveled
                                      for id = (plist-get task :id)
                                      for ts = (gethash id status-map)
                                      unless (and ts (eq (agent-shell-dispatch-render-task-status-status ts) 'done))
                                      minimize (plist-get task :level))
                             0))
           (show-level (max 0 (1- target-level)))
           (view-x (max 0 (- (gethash show-level col-xs)
                             (plist-get agent-shell-dispatch-render--layout :margin)))))
      (setq svg-str (replace-regexp-in-string
                     (format "width=\"%d\" height=\"%d\"" svg-w svg-h)
                     (format "width=\"%d\" height=\"%d\" viewBox=\"%d 0 %d %d\""
                             win-pw svg-h view-x win-pw svg-h)
                     svg-str t t))))
  svg-str)

(defun agent-shell-dispatch-render-cycle-spinner ()
  "Advance the spinner frame and update the working icon."
  (cl-incf agent-shell-dispatch-render--spinner-index)
  (setf (agent-shell-dispatch-render-status-style-icon
         (cdr (assq 'working (agent-shell-dispatch-render-theme-status (agent-shell-dispatch-render--theme-colors)))))
        (nth (% agent-shell-dispatch-render--spinner-index (length agent-shell-dispatch-render--spinner-frames))
             agent-shell-dispatch-render--spinner-frames)))

;; ── Header integration ─────────────────────────────────────────────
;;
;; The render module owns the rendering lifecycle (mode, heartbeat,
;; header advice, theme hook).  The dispatcher injects its logic via
;; hook variables — the render module never references dispatch state,
;; agent-shell, or shell-maker directly.

(defvar-local agent-shell-dispatch-render--ctx nil
  "Cached `agent-shell-dispatch-render-ctx'.")

(defvar-local agent-shell-dispatch-render--task-defs nil
  "Original `agent-shell-dispatch-render-task' list for re-prepare on theme change.")

(defvar-local agent-shell-dispatch-render-buffer nil
  "Buffer name for face resolution and heartbeat context.")

(defvar-local agent-shell-dispatch-render-status-function nil
  "Function of no args returning a hash of id → `agent-shell-dispatch-render-task-status'.
Called every frame by the header renderer.")

(defvar-local agent-shell-dispatch-render-agent-activity-function nil
  "Function of no args returning the agents hash (buffer-name -> agent-info).
Called every frame to render the agent activity column.")

(defvar-local agent-shell-dispatch-render-header-function nil
  "Function of no args that triggers a header redisplay.
Called by the heartbeat timer.")

(defvar-local agent-shell-dispatch-render-reset-function nil
  "Function of no args that restores the original header on mode disable.")

(defvar-local agent-shell-dispatch-render-busy-p-function nil
  "Function of no args returning non-nil when the host buffer is busy.
When busy, the heartbeat skips since the host drives updates itself.")

(defvar agent-shell-dispatch-render-advice-target nil
  "Function symbol to advise with the header extend function.
Global — only one advice installation is needed.")

(defvar-local agent-shell-dispatch-render--heartbeat-timer nil
  "Timer that drives header updates while the host buffer is idle.")

(defun agent-shell-dispatch-render-set-tasks (task-defs)
  "Set TASK-DEFS and prepare the render context."
  (setq agent-shell-dispatch-render--task-defs task-defs
        agent-shell-dispatch-render--ctx (agent-shell-dispatch-render-prepare task-defs)))

(defun agent-shell-dispatch-render--heartbeat (buf)
  "Force a header update in BUF when the host buffer is idle."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when agent-shell-dispatch-render--ctx
        (unless (and agent-shell-dispatch-render-busy-p-function
                     (funcall agent-shell-dispatch-render-busy-p-function))
          (when agent-shell-dispatch-render-header-function
            (ignore-errors (funcall agent-shell-dispatch-render-header-function))))))))

(defun agent-shell-dispatch-render--extend-header (&rest _)
  "Build task graph SVG and append below the host header SVG.
Buffer-local render vars ensure this is a no-op in non-dispatcher buffers."
  (when-let* ((ctx agent-shell-dispatch-render--ctx)
              (status-fn agent-shell-dispatch-render-status-function)
              (status-map (funcall status-fn))
              ((stringp header-line-format))
              (disp (get-text-property 1 'display header-line-format))
              (orig-svg (plist-get (cdr disp) :data)))
    (agent-shell-dispatch-render-cycle-spinner)
    (let* ((agents (when agent-shell-dispatch-render-agent-activity-function
                     (funcall agent-shell-dispatch-render-agent-activity-function)))
           (svg (agent-shell-dispatch-render-draw ctx status-map agents))
           (graph-svg (with-temp-buffer (svg-print svg) (buffer-string)))
           (graph-svg (agent-shell-dispatch-render-apply-viewport graph-svg ctx status-map (buffer-name)))
           (combined (agent-shell-dispatch-render-combine-svgs orig-svg graph-svg -12 10)))
      (when combined
        (setq header-line-format
              (format " %s" (propertize " " 'display
                                        (list 'image :type 'svg
                                              :data combined :scale 'default))))))))

(defun agent-shell-dispatch-render--on-theme-change (&rest _)
  "Recompute theme and re-prepare geometry on theme change.
Iterates over all buffers with active dispatch render state."
  (agent-shell-dispatch-render-refresh-theme)
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when agent-shell-dispatch-render--task-defs
          (setq agent-shell-dispatch-render--ctx
                (agent-shell-dispatch-render-prepare agent-shell-dispatch-render--task-defs)))))))


(define-minor-mode agent-shell-dispatch-render-mode
  "Buffer-local minor mode for dispatch task graph heartbeat.
Manages the per-buffer heartbeat timer that drives header updates.
Requires `agent-shell-dispatch-render-global-mode' for the advice."
  :lighter " Dispatch"
  (if agent-shell-dispatch-render-mode
      (if (null agent-shell-dispatch-render--ctx)
          (setq agent-shell-dispatch-render-mode nil)
        ;; Auto-enable global mode if not already on
        (unless (bound-and-true-p agent-shell-dispatch-global-mode)
          (agent-shell-dispatch-global-mode 1))
        ;; Buffer-local heartbeat timer
        (let ((buf (current-buffer)))
          (setq agent-shell-dispatch-render--heartbeat-timer
                (run-with-timer 0.1 0.1
                                (lambda () (agent-shell-dispatch-render--heartbeat buf))))))
    (when (timerp agent-shell-dispatch-render--heartbeat-timer)
      (cancel-timer agent-shell-dispatch-render--heartbeat-timer)
      (setq agent-shell-dispatch-render--heartbeat-timer nil))
    ;; Clear ctx BEFORE reset so the advice doesn't re-render during header update
    (setq agent-shell-dispatch-render--ctx nil)
    (when agent-shell-dispatch-render-reset-function
      (ignore-errors (funcall agent-shell-dispatch-render-reset-function)))))

(defvar-local agent-shell-dispatch-render-teardown-hook nil
  "Hook run during teardown for clearing external state.")

(defun agent-shell-dispatch-render-teardown ()
  "Disable rendering and clear all render state and hooks."
  (when agent-shell-dispatch-render-mode
    (agent-shell-dispatch-render-mode 'toggle))
  (run-hooks 'agent-shell-dispatch-render-teardown-hook)
  (setq agent-shell-dispatch-render--ctx nil
        agent-shell-dispatch-render--task-defs nil
        agent-shell-dispatch-render-buffer nil
        agent-shell-dispatch-render-status-function nil
        agent-shell-dispatch-render-agent-activity-function nil
        agent-shell-dispatch-render-header-function nil
        agent-shell-dispatch-render-reset-function nil
        agent-shell-dispatch-render-busy-p-function nil
        agent-shell-dispatch-render-advice-target nil
        agent-shell-dispatch-render-teardown-hook nil))

(provide 'agent-shell-dispatch-render)
;;; agent-shell-dispatch-render.el ends here
