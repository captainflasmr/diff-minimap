;;; diff-minimap.el --- VSCode-style minimap showing diff regions -*- lexical-binding: t; -*-
;;
;; Author: James Dyer <captainflasmr@gmail.com>
;; Version: 0.4.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: vc, tools, convenience
;; URL: https://github.com/captainflasmr/diff-minimap
;;
;; This file is not part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;; diff-minimap renders a tiny side-window minimap that colour-codes every
;; line according to its diff status (added / changed / removed) while
;; also marking the visible viewport and current cursor row.
;;
;; Quick start:
;;
;;   (require 'diff-minimap)
;;   M-x diff-minimap-toggle      ;; open/close the minimap
;;   C-x v m                      ;; same, under the VC prefix map
;;
;; The minimap auto-refreshes on scroll and save.  Click a row in the
;; minimap to jump to that line in the source buffer.
;;
;; Customise `diff-minimap-font-scale', `diff-minimap-width', and
;; `diff-minimap-side' to tweak the appearance.
;;
;;; Code:

(require 'cl-lib)
(require 'pulse)

(defvar diff-hl-mode)

(defgroup diff-minimap nil
  "VSCode-style minimap showing diff regions across the entire buffer."
  :group 'tools)

(defcustom diff-minimap-font-scale 0.1
  "Fraction of default font height for the minimap. 1.0 = normal, 0.1 = tiny."
  :type 'float
  :group 'diff-minimap)

(defcustom diff-minimap-width 6
  "Width in characters of the diff-minimap side window (at the small font)."
  :type 'integer
  :group 'diff-minimap)

(defcustom diff-minimap-side 'right
  "Which side to display the diff-minimap window."
  :type '(choice (const left) (const right))
  :group 'diff-minimap)

(defcustom diff-minimap-viewport-style 'filled
  "How to render the viewport indicator in the minimap.
`edge-bar' — solid bars at the top and bottom rows of the viewport.
`filled'   — solid background across the entire viewport (diffs visible on top).
`stipple'  — bitmap dot pattern fill + edge bars (diffs visible through)."
  :type '(choice (const :tag "Edge bars (top & bottom rows)" edge-bar)
                  (const :tag "Filled block (full background)" filled)
                  (const :tag "Stipple + edge bars (diffs visible)" stipple))
  :group 'diff-minimap)

(defcustom diff-minimap-stipple-pattern 'dots-sparse
  "Stipple bitmap for the `stipple' viewport style.
Predefined patterns or a custom plist (WIDTH HEIGHT DATA) where DATA
is a string of XBM bitmap bytes (left-to-right, top-to-bottom)."
  :type '(choice (const :tag "Sparse dots (~12%)" dots-sparse)
                 (const :tag "Diagonal lines (~25%)" diagonal)
                 (const :tag "Cross-hatch (~50%)" crosshatch)
                 (const :tag "Checkerboard (~25%)" checkerboard)
                 (const :tag "Dense dots (~25%)" dots-dense)
                 (list :tag "Custom"
                       (integer :tag "Width in pixels")
                       (integer :tag "Height in pixels")
                       (string :tag "XBM data")))
  :group 'diff-minimap)

(defcustom diff-minimap-diff-backend 'auto
  "Which backend to use for collecting diff data.
`auto' — try `diff-hl' first, fall back to git.
`diff-hl' — use diff-hl overlays (requires `diff-hl-mode').
`vc'    — use VC system (currently git only)."
  :type '(choice (const :tag "Auto-detect (diff-hl > git)" auto)
                 (const :tag "diff-hl overlays" diff-hl)
                 (const :tag "VC (git)" vc))
  :group 'diff-minimap)

(defcustom diff-minimap-fringe-indicators t
  "Whether to show diff indicators in the fringe of the source buffer.
When enabled, coloured fringe bitmaps appear on lines with changes,
using the same diff data backend as the minimap."
  :type 'boolean
  :group 'diff-minimap)

(defcustom diff-minimap-fringe-side 'left
  "Which fringe to show diff indicators in."
  :type '(choice (const :tag "Left fringe" left)
                 (const :tag "Right fringe" right))
  :group 'diff-minimap)

(defcustom diff-minimap-search-highlights t
  "Highlight isearch matches in the minimap as yellow bars.
Disabled when nil."
  :type 'boolean
  :group 'diff-minimap)

(defcustom diff-minimap-colour-source 'diff-hl
  "Which face colours to use for diff highlights in the minimap.
`diff-hl' — prefer =diff-hl-insert/change/deleted= fringe faces (fallback
            to built-in diff faces, then hardcoded defaults).
`diff'    — prefer built-in =diff-added/changed/removed= faces."
  :type '(choice (const :tag "diff-hl fringe colours" diff-hl)
                  (const :tag "Built-in diff colours" diff))
  :group 'diff-minimap)

(defface diff-minimap-font
  '((t :height 0.4 :inherit default))
  "Face used for the minimap buffer — tiny font for fine-grained display."
  :group 'diff-minimap)

(defface diff-minimap-fringe-added
  '((t :foreground "#006600"))
  "Face for added-line fringe indicator."
  :group 'diff-minimap)

(defface diff-minimap-fringe-changed
  '((t :foreground "#666600"))
  "Face for changed-line fringe indicator."
  :group 'diff-minimap)

(defface diff-minimap-fringe-removed
  '((t :foreground "#660000"))
  "Face for removed-line fringe indicator."
  :group 'diff-minimap)

(defface diff-minimap-search-face
  '((t :background "#ffff00" :extend t))
  "Face for search-match highlights in the minimap."
  :group 'diff-minimap)

(defvar-local diff-minimap--last-tick nil
  "Buffer tick at last full render — for detecting content changes.")

(defvar-local diff-minimap--last-nrows nil
  "Minimap row count at last full render — for detecting window resizes.")

(defvar-local diff-minimap--last-themes nil
  "Snapshot of `custom-enabled-themes' at last full render.")

(defvar-local diff-minimap--viewport-edge-top nil
  "Overlay for the top edge of the viewport region (edge-bar style).")

(defvar-local diff-minimap--viewport-edge-bottom nil
  "Overlay for the bottom edge of the viewport region (edge-bar style).")

(defvar-local diff-minimap--viewport-overlay nil
  "Overlay covering the full viewport (filled/outline/stipple styles).")

(defvar-local diff-minimap--cursor-overlay nil
  "Overlay highlighting the cursor row in the minimap buffer.")

(defvar diff-minimap--last-buffer nil
  "Last buffer shown in the minimap; used to detect switches.")

(defvar diff-minimap--buffer-name " *diff-minimap*"
  "Name of the hidden minimap buffer.")

;; Cached face colours — recomputed in `diff-minimap--cache-faces'.
(defvar diff-minimap--norm-bg "#1a1a1a")
(defvar diff-minimap--view-bg "#404060")
(defvar diff-minimap--ins-bg  "#006600")
(defvar diff-minimap--chg-bg  "#666600")
(defvar diff-minimap--del-bg  "#660000")
(defvar diff-minimap--cur-bg  "#00ffff")

;; Stipple bitmap patterns for the `stipple' viewport style.
(defconst diff-minimap--stipple-dots-sparse
  (list 8 8 (apply #'string '(#x80 #x40 #x20 #x10 #x08 #x04 #x02 #x01)))
  "Diagonal single-pixel dots, ~12% coverage.")

(defconst diff-minimap--stipple-diagonal
  (list 8 8 (apply #'string '(#x81 #x42 #x24 #x18 #x18 #x24 #x42 #x81)))
  "Thin diagonal lines, ~25% coverage.")

(defconst diff-minimap--stipple-crosshatch
  (list 8 8 (apply #'string '(#xAA #x55 #xAA #x55 #xAA #x55 #xAA #x55)))
  "Cross-hatch (alternating pixel inversion), 50% coverage.")

(defconst diff-minimap--stipple-checkerboard
  (list 8 8 (apply #'string '(#xAA #x00 #xAA #x00 #xAA #x00 #xAA #x00)))
  "Checkerboard, 25% coverage.")

(defconst diff-minimap--stipple-dots-dense
  (list 8 8 (apply #'string '(#x88 #x22 #x88 #x22 #x88 #x22 #x88 #x22)))
  "Denser dot pattern, ~25% coverage.")

;; Fringe bitmaps for diff indicators.
(define-fringe-bitmap 'diff-minimap--bmp-added
  [255 255 255 255 255 255 255 255]
  nil nil '(center t))

(define-fringe-bitmap 'diff-minimap--bmp-changed
  [126 126 126 126 126 126 126 126]
  nil nil '(center t))

(define-fringe-bitmap 'diff-minimap--bmp-removed
  [60 60 60 60 60 60 60 60]
  nil nil '(center t))

(defun diff-minimap--resolve-stipple ()
  "Return the stipple bitmap data for `diff-minimap-stipple-pattern'."
  (pcase diff-minimap-stipple-pattern
    ('dots-sparse    diff-minimap--stipple-dots-sparse)
    ('diagonal       diff-minimap--stipple-diagonal)
    ('crosshatch     diff-minimap--stipple-crosshatch)
    ('checkerboard   diff-minimap--stipple-checkerboard)
    ('dots-dense     diff-minimap--stipple-dots-dense)
    ((and (pred listp) pat) pat)    ; custom (WIDTH HEIGHT DATA)
    (_               diff-minimap--stipple-dots-sparse)))

(defun diff-minimap--buffer-lines ()
  "Return the number of content lines in the current buffer.
Accounts for the trailing newline that Emacs adds on save."
  (let ((n (line-number-at-pos (point-max) t)))
    (if (save-excursion (goto-char (point-max)) (bolp))
        (max 1 (1- n))
      (max 1 n))))

(defun diff-minimap--cache-faces ()
  "Compute and cache face colours used by the minimap.
Respects `diff-minimap-colour-source' for diff highlight priority."
  (let ((fbg (lambda (f attr d)
               (if (facep f)
                   (let ((v (face-attribute f attr nil t)))
                     (if (or (not v) (eq v 'unspecified) (not (stringp v)))
                         d v))
                 d))))
    (setq diff-minimap--norm-bg (funcall fbg 'fringe :background "#1a1a1a"))
    (setq diff-minimap--view-bg (funcall fbg 'region :background "#404060"))
    (if (eq diff-minimap-colour-source 'diff-hl)
        (progn
          (setq diff-minimap--ins-bg (funcall fbg 'diff-hl-insert :background
                                              (funcall fbg 'diff-added :background "#006600")))
          (setq diff-minimap--chg-bg (funcall fbg 'diff-hl-change :background
                                              (funcall fbg 'diff-changed :background "#666600")))
          (setq diff-minimap--del-bg (funcall fbg 'diff-hl-delete :background
                                              (funcall fbg 'diff-removed :background "#660000"))))
      (setq diff-minimap--ins-bg  (funcall fbg 'diff-added :background
                                           (funcall fbg 'diff-hl-insert :background "#006600")))
      (setq diff-minimap--chg-bg  (funcall fbg 'diff-changed :background
                                           (funcall fbg 'diff-hl-change :background "#666600")))
      (setq diff-minimap--del-bg  (funcall fbg 'diff-removed :background
                                           (funcall fbg 'diff-hl-delete :background "#660000"))))
    (setq diff-minimap--cur-bg  (funcall fbg 'cursor :background "#00ffff"))
    (when diff-minimap-fringe-indicators
      (set-face-foreground 'diff-minimap-fringe-added diff-minimap--ins-bg nil)
      (set-face-foreground 'diff-minimap-fringe-changed diff-minimap--chg-bg nil)
      (set-face-foreground 'diff-minimap-fringe-removed diff-minimap--del-bg nil))))


;;; Diff data backends

(defun diff-minimap--backend-available-p ()
  "Return t if the configured diff backend is available."
  (pcase diff-minimap-diff-backend
    ('diff-hl (bound-and-true-p diff-hl-mode))
    ('vc (and (buffer-file-name) (executable-find "git")))
    ('auto (or (bound-and-true-p diff-hl-mode)
               (and (buffer-file-name) (executable-find "git"))))))

(defun diff-minimap--collect-diff-data ()
  "Collect diff data from the configured backend.
Returns a list of (TYPE START-LINE END-LINE) where TYPE is
`added', `changed', or `removed', and START-LINE/END-LINE are
1-indexed inclusive line numbers in the current buffer.
Returns nil when no backend is available or no changes exist."
  (pcase diff-minimap-diff-backend
    ('diff-hl (diff-minimap--collect-from-diff-hl))
    ('vc (diff-minimap--collect-from-vc))
    ('auto (or (diff-minimap--collect-from-diff-hl)
               (diff-minimap--collect-from-vc)))))

(defun diff-minimap--collect-from-diff-hl ()
  "Collect diff data from `diff-hl' overlays.
Returns a list of (TYPE START-LINE END-LINE) or nil."
  (when (bound-and-true-p diff-hl-mode)
    (let ((result nil))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (let ((ty (overlay-get ov 'diff-hl-hunk-type)))
          (when (or ty (overlay-get ov 'diff-hl-hunk))
            (let* ((st (overlay-start ov))
                   (en (overlay-end ov))
                   (raw-ty (or ty 'change))
                   (ty (pcase (format "%s" raw-ty)
                        ((or "insert" "add" "added") 'added)
                        ((or "delete" "removed" "remove") 'removed)
                        (_ 'changed))))
              (when (and st en)
                (save-excursion
                  (goto-char st)
                  (let* ((sl (line-number-at-pos))
                         (el (if (eq ty 'removed) sl
                               (progn (goto-char en)
                                      (if (bolp) (1- (line-number-at-pos))
                                        (line-number-at-pos))))))
                    (push (list ty sl el) result))))))))
      result)))

(defun diff-minimap--collect-from-vc ()
  "Collect diff data using git.
Returns a list of (TYPE START-LINE END-LINE) or nil."
  (when-let ((file (buffer-file-name)))
    (let* ((default-directory (file-name-directory file))
           (git (executable-find "git")))
      (when git
        (let* ((rel-file (file-relative-name file))
               (output
                (or (diff-minimap--git-diff
                     (format "diff --no-color --unified=0 HEAD -- %s"
                             (shell-quote-argument rel-file)))
                    (diff-minimap--git-diff
                     (format "diff --no-color --unified=0 --cached -- %s"
                             (shell-quote-argument rel-file))))))
          (when output
            (diff-minimap--parse-git-diff (split-string output "\n" t))))))))

(defun diff-minimap--git-diff (command)
  "Run git COMMAND and return stdout as string, or nil on failure."
  (ignore-errors
    (with-temp-buffer
      (let ((exit-code (apply #'process-file "git" nil t nil
                              (split-string-and-unquote command))))
        (unless (<= exit-code 1)
          (error "git command failed: exit %d" exit-code)))
      (let ((s (buffer-string)))
        (unless (string-empty-p s) s)))))

(defun diff-minimap--parse-git-diff (lines)
  "Parse git diff LINES and return list of (TYPE START END).
Each type is `added', `changed', or `removed' with 1-indexed
inclusive line numbers in the current buffer."
  (let ((result nil)
        (new-line nil)
        (hunk-lines nil)
        (hunk-new-start nil))
    (dolist (line lines)
      (cond
       ((string-match "^@@ -\\([0-9]+\\),?\\([0-9]*\\) \\+\\([0-9]+\\),?\\([0-9]*\\) @@" line)
        (when hunk-lines
          (setq result (nconc result
                              (diff-minimap--process-hunk-lines
                               (nreverse hunk-lines) hunk-new-start)))
          (setq hunk-lines nil))
        (setq new-line (string-to-number (match-string 3 line))
              hunk-new-start new-line))
       (new-line
        (push (cons (substring line 0 1) new-line) hunk-lines)
        (when (string-match "^\\([+ ]\\)" line)
          (cl-incf new-line)))))
    (when hunk-lines
      (setq result (nconc result
                          (diff-minimap--process-hunk-lines
                           (nreverse hunk-lines) hunk-new-start))))
    (diff-minimap--merge-ranges result)))

(defun diff-minimap--process-hunk-lines (hunk-lines hunk-new-start)
  "Process HUNK-LINES and return changes list.
HUNK-LINES is a list of (PREFIX . NEW-LINE-NUM).
HUNK-NEW-START is the starting new-line number."
  (let ((has-minus (cl-some (lambda (l) (string= (car l) "-")) hunk-lines))
        (has-plus (cl-some (lambda (l) (string= (car l) "+")) hunk-lines))
        (result nil)
        (current-type nil)
        (current-start nil)
        (current-end nil))
    (when has-plus
      (let ((type (if has-minus 'changed 'added)))
        (dolist (hl hunk-lines)
          (when (string= (car hl) "+")
            (let ((line (cdr hl)))
              (if (and (eq type current-type) (= line (1+ current-end)))
                  (setq current-end line)
                (when current-type
                  (push (list current-type current-start current-end) result))
                (setq current-type type
                      current-start line
                      current-end line)))))
        (when current-type
          (push (list current-type current-start current-end) result))))
    (when (and has-minus (not has-plus))
      (push (list 'removed hunk-new-start hunk-new-start) result))
    (nreverse result)))

(defun diff-minimap--merge-ranges (changes)
  "Merge adjacent ranges of the same type in CHANGES."
  (when changes
    (let ((merged (list (car changes))))
      (dolist (c (cdr changes) (nreverse merged))
        (let* ((last (car merged))
               (l-type (car last))
               (l-end (nth 2 last))
               (c-type (car c))
               (c-start (nth 1 c))
               (c-end (nth 2 c)))
          (if (and (eq l-type c-type) (<= c-start (1+ l-end)))
              (setcdr (cdr last) (list (max l-end c-end)))
            (push c merged)))))))


;;; Fringe indicators

(defun diff-minimap--fringe-display (bmp face)
  "Return fringe display spec for bitmap BMP using FACE."
  (if (eq diff-minimap-fringe-side 'left)
      `(left-fringe ,bmp ,face)
    `(right-fringe ,bmp ,face)))

(defun diff-minimap--fringe-clear ()
  "Remove all fringe indicator overlays from the current buffer."
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'diff-minimap-fringe)
      (delete-overlay ov))))

(defun diff-minimap--fringe-update (diff-data)
  "Create fringe indicator overlays from DIFF-DATA.
DIFF-DATA is a list of (TYPE START END) as returned by
`diff-minimap--collect-diff-data'.  Removes old fringe overlays first."
  (diff-minimap--fringe-clear)
  (when diff-minimap-fringe-indicators
    (dolist (change diff-data)
      (let* ((ty (car change))
             (start (nth 1 change))
             (end (nth 2 change))
             (bmp (pcase ty
                    ('added 'diff-minimap--bmp-added)
                    ('changed 'diff-minimap--bmp-changed)
                    ('removed 'diff-minimap--bmp-removed)))
             (face (pcase ty
                     ('added 'diff-minimap-fringe-added)
                     ('changed 'diff-minimap-fringe-changed)
                     ('removed 'diff-minimap-fringe-removed))))
        (when bmp
          (save-excursion
            (goto-char (point-min))
            (forward-line (1- start))
            (cl-loop for l from start to end
                     do (let ((ov (make-overlay (line-beginning-position)
                                                (1+ (line-beginning-position)))))
                          (overlay-put ov 'before-string
                                       (propertize " " 'display
                                                   (diff-minimap--fringe-display bmp face)))
                          (overlay-put ov 'diff-minimap-fringe t))
                     (forward-line 1))))))))

(defun diff-minimap--row->pos (row)
  "Return buffer position at the start of minimap ROW (0-indexed)."
  (save-excursion
    (goto-char (point-min))
    (forward-line row)
    (point)))

(defun diff-minimap--clear-overlays ()
  "Remove all diff-minimap overlays (viewport, cursor, diff colours) from the minimap buffer."
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'diff-minimap-overlay)
      (delete-overlay ov)))
  (setq diff-minimap--viewport-edge-top nil
        diff-minimap--viewport-edge-bottom nil
        diff-minimap--viewport-overlay nil
        diff-minimap--cursor-overlay nil))

(defun diff-minimap--update-viewport ()
  "Update viewport and cursor overlays in the minimap buffer.
Called on every command — cheap overlay moves, not a full rebuild."
  (let ((mm-buf (get-buffer diff-minimap--buffer-name))
        (this-buf (current-buffer)))
    (when (and mm-buf (get-buffer-window mm-buf))
      (with-current-buffer this-buf
         (let* ((total (diff-minimap--buffer-lines))
                (nrows (or diff-minimap--last-nrows 1))
               (scale (/ (float total) nrows))
                (ws-win (get-buffer-window this-buf))
                (pt-line (line-number-at-pos))
                (cur-row (min (1- nrows)
                              (floor (/ (1- pt-line) scale))))
                (vis-rows (max 1 (ceiling (window-text-height ws-win) scale)))
                (ws-row (let ((from-start (max 0 (floor (/ (1- (line-number-at-pos
                                                                (window-start ws-win)))
                                                          scale)))))
                          ;; When window-start is stale (e.g. after
                          ;; beginning-of-buffer during post-command-hook)
                          ;; the cursor falls outside the old viewport.
                          ;; Fall back to centering around the cursor.
                           (if (or (< cur-row from-start)
                                   (> cur-row (+ from-start vis-rows)))
                              (max 0 (- cur-row (/ vis-rows 2)))
                            from-start)))
                (we-row (min (1- nrows) (+ ws-row vis-rows))))
            (with-current-buffer mm-buf
              (pcase diff-minimap-viewport-style
                ('edge-bar
                 (when diff-minimap--viewport-overlay
                   (delete-overlay diff-minimap--viewport-overlay)
                   (setq diff-minimap--viewport-overlay nil))
                 (if diff-minimap--viewport-edge-top
                     (move-overlay diff-minimap--viewport-edge-top
                                   (diff-minimap--row->pos ws-row)
                                   (diff-minimap--row->pos (1+ ws-row))
                                   mm-buf)
                   (setq diff-minimap--viewport-edge-top
                         (make-overlay (diff-minimap--row->pos ws-row)
                                       (diff-minimap--row->pos (1+ ws-row))
                                       mm-buf))
                   (overlay-put diff-minimap--viewport-edge-top
                                'diff-minimap-overlay t))
                  (overlay-put diff-minimap--viewport-edge-top 'face
                               '(:overline t :extend t))
                 (overlay-put diff-minimap--viewport-edge-top 'priority 5)
                 (if diff-minimap--viewport-edge-bottom
                     (move-overlay diff-minimap--viewport-edge-bottom
                                   (diff-minimap--row->pos we-row)
                                   (diff-minimap--row->pos (1+ we-row))
                                   mm-buf)
                   (setq diff-minimap--viewport-edge-bottom
                         (make-overlay (diff-minimap--row->pos we-row)
                                       (diff-minimap--row->pos (1+ we-row))
                                       mm-buf))
                   (overlay-put diff-minimap--viewport-edge-bottom
                                'diff-minimap-overlay t))
                 (overlay-put diff-minimap--viewport-edge-bottom 'face
                              '(:underline t :extend t))
                 (overlay-put diff-minimap--viewport-edge-bottom 'priority 5))
                ('filled
                 (when diff-minimap--viewport-edge-top
                   (delete-overlay diff-minimap--viewport-edge-top)
                   (setq diff-minimap--viewport-edge-top nil))
                 (when diff-minimap--viewport-edge-bottom
                   (delete-overlay diff-minimap--viewport-edge-bottom)
                   (setq diff-minimap--viewport-edge-bottom nil))
                 (if diff-minimap--viewport-overlay
                     (move-overlay diff-minimap--viewport-overlay
                                   (diff-minimap--row->pos ws-row)
                                   (diff-minimap--row->pos (1+ we-row))
                                   mm-buf)
                   (setq diff-minimap--viewport-overlay
                         (make-overlay (diff-minimap--row->pos ws-row)
                                       (diff-minimap--row->pos (1+ we-row))
                                       mm-buf))
                   (overlay-put diff-minimap--viewport-overlay
                                'diff-minimap-overlay t))
                 (overlay-put diff-minimap--viewport-overlay 'face
                               `(:background ,diff-minimap--view-bg :extend t))
                  ;; Below diff overlays (priority 3) so diffs show through.
                  (overlay-put diff-minimap--viewport-overlay 'priority 1))
                 ('stipple
                 (if diff-minimap--viewport-overlay
                     (move-overlay diff-minimap--viewport-overlay
                                   (diff-minimap--row->pos ws-row)
                                   (diff-minimap--row->pos (1+ we-row))
                                   mm-buf)
                   (setq diff-minimap--viewport-overlay
                         (make-overlay (diff-minimap--row->pos ws-row)
                                       (diff-minimap--row->pos (1+ we-row))
                                       mm-buf))
                   (overlay-put diff-minimap--viewport-overlay
                                'diff-minimap-overlay t))
                 (overlay-put diff-minimap--viewport-overlay 'face
                               `(:stipple ,(diff-minimap--resolve-stipple) :extend t))
                  ;; Below diff overlays (priority 3) so diffs show through.
                  (overlay-put diff-minimap--viewport-overlay 'priority 2)
                 ;; Edge bars on top of the stipple fill
                 (if diff-minimap--viewport-edge-top
                     (move-overlay diff-minimap--viewport-edge-top
                                   (diff-minimap--row->pos ws-row)
                                   (diff-minimap--row->pos (1+ ws-row))
                                   mm-buf)
                   (setq diff-minimap--viewport-edge-top
                         (make-overlay (diff-minimap--row->pos ws-row)
                                       (diff-minimap--row->pos (1+ ws-row))
                                       mm-buf))
                   (overlay-put diff-minimap--viewport-edge-top
                                'diff-minimap-overlay t))
                 (overlay-put diff-minimap--viewport-edge-top 'face
                               `(:background ,diff-minimap--view-bg :extend t))
                 (overlay-put diff-minimap--viewport-edge-top 'priority 5)
                 (if diff-minimap--viewport-edge-bottom
                     (move-overlay diff-minimap--viewport-edge-bottom
                                   (diff-minimap--row->pos we-row)
                                   (diff-minimap--row->pos (1+ we-row))
                                   mm-buf)
                   (setq diff-minimap--viewport-edge-bottom
                         (make-overlay (diff-minimap--row->pos we-row)
                                       (diff-minimap--row->pos (1+ we-row))
                                       mm-buf))
                   (overlay-put diff-minimap--viewport-edge-bottom
                                'diff-minimap-overlay t))
                 (overlay-put diff-minimap--viewport-edge-bottom 'face
                               `(:background ,diff-minimap--view-bg :extend t))
                  (overlay-put diff-minimap--viewport-edge-bottom 'priority 5)))
              ;; Cursor — 2-char left marker, always refresh face colour
             (let ((cursor-end (+ (diff-minimap--row->pos cur-row) 2)))
               (if diff-minimap--cursor-overlay
                   (move-overlay diff-minimap--cursor-overlay
                                 (diff-minimap--row->pos cur-row)
                                 (min cursor-end (diff-minimap--row->pos (1+ cur-row)))
                                 mm-buf)
                 (setq diff-minimap--cursor-overlay
                       (make-overlay (diff-minimap--row->pos cur-row)
                                     (min cursor-end (diff-minimap--row->pos (1+ cur-row)))
                                     mm-buf))
                 (overlay-put diff-minimap--cursor-overlay 'diff-minimap-overlay t))
               (overlay-put diff-minimap--cursor-overlay 'face
                            `(:background ,diff-minimap--cur-bg))
               (overlay-put diff-minimap--cursor-overlay 'priority 10))))))))

(defun diff-minimap--render ()
  "Render the full minimap content with diff colours only.
Viewport and cursor highlights are applied as overlays by
`diff-minimap--update-viewport'."
  (diff-minimap--cache-faces)
  (let ((mm-buf (get-buffer-create diff-minimap--buffer-name))
        (this-buf (current-buffer)))
    (when (and (diff-minimap--backend-available-p)
               (get-buffer-window mm-buf))
      (let* ((total (with-current-buffer this-buf
                       (diff-minimap--buffer-lines)))
             (src-win (get-buffer-window this-buf))
             (mm-win (get-buffer-window mm-buf))
               (nrows (max 1
                           (let ((row-px (ceiling (* (frame-char-height)
                                                     diff-minimap-font-scale))))
                             (floor (/ (window-body-height
                                        (or mm-win src-win) t)
                                       row-px)))))
             (scale (/ (float total) nrows))
             (row-diff (make-vector nrows nil))
             (diff-data (with-current-buffer this-buf
                          (diff-minimap--collect-diff-data))))
        (setq diff-minimap--last-nrows nrows
              diff-minimap--last-themes (and (boundp 'custom-enabled-themes)
                                              custom-enabled-themes))
        (with-current-buffer this-buf
          (setq diff-minimap--last-tick (buffer-chars-modified-tick))
          (dolist (change diff-data)
            (let* ((ty (car change))
                   (sl (nth 1 change))
                   (el (nth 2 change))
                   (fr (floor (/ (1- sl) scale)))
                   (lr (min (1- nrows) (floor (/ (1- el) scale)))))
              (cl-loop for r from fr to lr
                       do (aset row-diff r ty))))
          (diff-minimap--fringe-update diff-data))
        ;; Write minimap content — normal background as text props,
        ;; then diff colours as overlays for proper priority layering.
        (let ((nrm-face `(:background ,diff-minimap--norm-bg :extend t))
              (ins-face `(:background ,diff-minimap--ins-bg :extend t))
              (chg-face `(:background ,diff-minimap--chg-bg :extend t))
              (del-face `(:background ,diff-minimap--del-bg :extend t)))
          (with-current-buffer mm-buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (diff-minimap--clear-overlays)
              (dotimes (i nrows)
                (let ((sline (1+ (floor (* i scale)))))
                  (insert
                   (propertize " " 'face nrm-face
                               'source-line sline 'source-buf this-buf)
                   (propertize (make-string (1- diff-minimap-width) ?\s)
                               'face nrm-face
                               'source-line sline 'source-buf this-buf)
                   (propertize "\n" 'face nrm-face))))
              ;; Diff colour overlays at priority 3 — above viewport fill (1)
              ;; and stipple (2), below cursor (10) and edge/outline bars (5).
              (dotimes (i nrows)
                (let* ((dtype (aref row-diff i))
                       (face (cond ((eq dtype 'added) ins-face)
                                   ((eq dtype 'changed) chg-face)
                                   ((eq dtype 'removed) del-face))))
                  (when face
                    (let ((ov (make-overlay (diff-minimap--row->pos i)
                                            (diff-minimap--row->pos (1+ i))
                                            mm-buf)))
                      (overlay-put ov 'face face)
                      (overlay-put ov 'priority 3)
                       (overlay-put ov 'diff-minimap-overlay t)))))))
            ;; Recreate viewport/cursor overlays from source buffer context
            (diff-minimap--update-viewport)
            ;; Insert pushes point to point-max — move it back so redisplay
            ;; doesn't try to chase it.  nrows now exactly matches the
            ;; window height, so all rows are always visible.
            (with-current-buffer mm-buf
              (goto-char (point-min))))))))

(defun diff-minimap--post-command ()
  "Immediate post-command-hook: update viewport/cursor overlays or full re-render.
Detects buffer switches and re-renders for the new buffer automatically.
Clears the minimap when entering a buffer with no diff backend."
  (when (get-buffer-window diff-minimap--buffer-name)
    (let ((buf (current-buffer))
          (mm-buf (get-buffer diff-minimap--buffer-name)))
      (when mm-buf
        (unless (eq buf diff-minimap--last-buffer)
          (setq diff-minimap--last-buffer buf)
          (if (diff-minimap--backend-available-p)
              (progn
                (diff-minimap--render)
                (run-with-timer
                 0.2 nil
                 (lambda ()
                   (when (and (buffer-live-p buf)
                              (eq diff-minimap--last-buffer buf))
                     (with-current-buffer buf
                       (diff-minimap--render))))))
            (with-current-buffer buf
              (diff-minimap--fringe-clear))
            (with-current-buffer mm-buf
              (let ((inhibit-read-only t))
                (erase-buffer)
                (diff-minimap--clear-overlays))))))
        (when (and (diff-minimap--backend-available-p)
                   (eq buf diff-minimap--last-buffer))
          (let* ((tick (with-current-buffer buf
                         (buffer-chars-modified-tick)))
                  (src-win (get-buffer-window buf))
                   (cur-nrows (let ((mm-win (get-buffer-window mm-buf)))
                                (when mm-win
                                  (let ((row-px (ceiling
                                                 (* (frame-char-height)
                                                    diff-minimap-font-scale))))
                                    (floor (/ (window-body-height mm-win t)
                                              row-px))))))
                 (cur-themes (and (boundp 'custom-enabled-themes)
                                  custom-enabled-themes))
                 (needs-full (or (not (eq tick diff-minimap--last-tick))
                                  (and cur-nrows
                                       (not (= cur-nrows
                                               (or diff-minimap--last-nrows 0))))
                                  (not (equal cur-themes
                                              diff-minimap--last-themes)))))
            (if needs-full
                (diff-minimap--render)
              (diff-minimap--update-viewport)))))))

(defun diff-minimap--after-save ()
  "Force re-render after save (idle delay lets the backend catch up)."
  (let ((buf (current-buffer)))
    (run-with-idle-timer
     0.05 nil
     (lambda ()
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (diff-minimap--render)))))))

(defun diff-minimap--click-handler ()
  "Handle mouse click: scroll source to clicked line."
  (interactive)
  (let* ((pos (event-start last-input-event))
         (line (get-text-property (posn-point pos) 'source-line))
         (buf (get-text-property (posn-point pos) 'source-buf)))
    (when (and line buf (buffer-live-p buf))
      (with-selected-window (get-buffer-window buf)
        (goto-char (point-min))
        (forward-line (1- line))
        (recenter 0)))))

;;;###autoload
(defun diff-minimap-toggle ()
  "Toggle the diff minimap side window."
  (interactive)
  (let ((mm-buf (get-buffer-create diff-minimap--buffer-name)))
    (if (get-buffer-window mm-buf)
        (progn
          (diff-minimap-mode -1)
          (delete-window (get-buffer-window mm-buf))
          (diff-minimap--fringe-clear))
      (let ((win (display-buffer-in-side-window
                  mm-buf
                  `((side . ,diff-minimap-side)
                    (window-width . ,diff-minimap-width)
                    (no-delete-other-windows . t)
                    (preserve-size . (t . nil))))))
        (when win
          (set-window-parameter win 'no-delete-other-windows t))
        (with-current-buffer mm-buf
          (setq window-size-fixed 'width)
          (setq buffer-read-only t)
          (setq cursor-type nil)
          (setq line-spacing 0)
          (setq-local truncate-lines t)
          (setq-local left-fringe-width 0)
          (setq-local right-fringe-width 0)
          (face-remap-set-base 'default :height diff-minimap-font-scale)
          (let ((map (make-sparse-keymap)))
            (define-key map [mouse-1] #'diff-minimap--click-handler)
            (define-key map [down-mouse-1] #'ignore)
            (use-local-map map))
          (setq-local mode-line-format nil)
          (setq-local header-line-format nil))
        (diff-minimap--render)
        (diff-minimap-mode 1)))))

;;;###autoload
(defun diff-minimap-toggle-with-demap ()
  "Toggle this minimap and `demap' together, one on each side.
Opens both if neither is visible; closes both if either is.
Demap should be configured on the right, this minimap on the left
\(via `diff-minimap-side') to match the VSCode layout.
When `demap' is absent, behaves as `diff-minimap-toggle'."
  (interactive)
  (if (not (fboundp 'demap-open))
      (diff-minimap-toggle)
    (let* ((mm-buf (get-buffer diff-minimap--buffer-name))
           (demap-buf (get-buffer "*Minimap*"))
           (mm-win (and mm-buf (get-buffer-window mm-buf)))
           (demap-win (and demap-buf (get-buffer-window demap-buf))))
      (if (or mm-win demap-win)
          (progn
            (when mm-win (diff-minimap-toggle))
            (when demap-win (demap-close)))
        (diff-minimap-toggle)
        (demap-open)))))

(defun diff-minimap--pulse-range (start end)
  "Momentarily highlight lines from START to END (1-indexed, inclusive)."
  (ignore-errors
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- start))
      (let ((ov (make-overlay (point)
                              (progn (forward-line (1+ (- end start)))
                                     (point)))))
        (pulse-momentary-highlight-overlay ov)))))


;;; Search-match highlights in the minimap

(defun diff-minimap--search-clear ()
  "Remove all search-match overlays from the minimap buffer."
  (let ((mm-buf (get-buffer diff-minimap--buffer-name)))
    (when mm-buf
      (with-current-buffer mm-buf
        (dolist (ov (overlays-in (point-min) (point-max)))
          (when (overlay-get ov 'diff-minimap-search)
            (delete-overlay ov)))))))

(defun diff-minimap--search-update ()
  "Update search-match highlights in the minimap buffer."
  (when (and diff-minimap-search-highlights
             isearch-mode
             (not (string-empty-p isearch-string))
             (get-buffer-window diff-minimap--buffer-name))
    (let ((mm-buf (get-buffer diff-minimap--buffer-name)))
      (when (and mm-buf diff-minimap--last-nrows)
        (diff-minimap--search-clear)
        (let* ((total (diff-minimap--buffer-lines))
               (scale (/ (float total) diff-minimap--last-nrows))
               (regexp (if isearch-regexp isearch-string
                         (regexp-quote isearch-string))))
          (save-excursion
            (goto-char (point-min))
            (while (re-search-forward regexp nil t)
              (let* ((line (line-number-at-pos (match-beginning 0)))
                     (row (min (1- diff-minimap--last-nrows)
                               (floor (/ (1- line) scale)))))
                (with-current-buffer mm-buf
                  (let ((ov (make-overlay (diff-minimap--row->pos row)
                                          (diff-minimap--row->pos (1+ row))
                                          mm-buf)))
                    (overlay-put ov 'face 'diff-minimap-search-face)
                    (overlay-put ov 'priority 4)
                    (overlay-put ov 'diff-minimap-search t)))))))))))

;;;###autoload
(defun diff-minimap-next-hunk ()
  "Move point to the next diff hunk.
Uses the configured `diff-minimap-diff-backend' to find hunks."
  (interactive)
  (let* ((data (diff-minimap--collect-diff-data))
         (current (line-number-at-pos))
         (next (catch 'found
                 (dolist (h data)
                   (let ((start (nth 1 h)))
                     (when (> start current)
                       (throw 'found h)))))))
    (if next
        (let ((start (nth 1 next))
              (end (nth 2 next)))
          (goto-char (point-min))
          (forward-line (1- start))
          (recenter)
          (diff-minimap--pulse-range start end))
      (user-error "No next hunk"))))

;;;###autoload
(defun diff-minimap-previous-hunk ()
  "Move point to the previous diff hunk.
Uses the configured `diff-minimap-diff-backend' to find hunks."
  (interactive)
  (let* ((data (diff-minimap--collect-diff-data))
         (current (line-number-at-pos))
         (prev nil))
    (dolist (h data)
      (let ((start (nth 1 h)))
        (when (< start current)
          (setq prev h))))
    (if prev
        (let ((start (nth 1 prev))
              (end (nth 2 prev)))
          (goto-char (point-min))
          (forward-line (1- start))
          (recenter)
          (diff-minimap--pulse-range start end))
      (user-error "No previous hunk"))))

(defvar diff-minimap-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-]") #'diff-minimap-next-hunk)
    (define-key map (kbd "M-[") #'diff-minimap-previous-hunk)
    map)
  "Keymap for `diff-minimap-mode'.
Bound keys:
\\{diff-minimap-mode-map}")

;;;###autoload
(define-minor-mode diff-minimap-mode
  "Global minor mode keeping the diff minimap in sync.
When active, the minimap follows the selected buffer and updates on
scroll, edit, save, buffer switch, and hunk navigation — no need to
toggle per buffer.
\\{diff-minimap-mode-map}"
  :lighter " DMap"
  :global t
  :keymap diff-minimap-mode-map
  (if diff-minimap-mode
      (progn
        (add-hook 'post-command-hook #'diff-minimap--post-command)
        (add-hook 'after-save-hook #'diff-minimap--after-save)
        (add-hook 'isearch-update-post-hook #'diff-minimap--search-update)
        (add-hook 'isearch-mode-end-hook #'diff-minimap--search-clear))
    (remove-hook 'post-command-hook #'diff-minimap--post-command)
    (remove-hook 'after-save-hook #'diff-minimap--after-save)
    (remove-hook 'isearch-update-post-hook #'diff-minimap--search-update)
    (remove-hook 'isearch-mode-end-hook #'diff-minimap--search-clear)
    (setq diff-minimap--last-buffer nil)))

(define-key vc-prefix-map (kbd "m") #'diff-minimap-toggle)
(define-key vc-prefix-map (kbd "M") #'diff-minimap-toggle-with-demap)
(define-key vc-prefix-map "]" #'diff-minimap-next-hunk)
(define-key vc-prefix-map "[" #'diff-minimap-previous-hunk)

(provide 'diff-minimap)
;;; diff-minimap.el ends here
