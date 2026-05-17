;;; diff-minimap.el --- VSCode-style minimap showing diff regions -*- lexical-binding: t; -*-
;;
;; Author: James Dyer <captainflasmr@gmail.com>
;; Version: 0.7.0
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
`auto' — try Ediff first, then `diff-hl', fall back to git.
`diff-hl' — use diff-hl overlays (requires `diff-hl-mode').
`vc'    — use VC system (currently git only).
`ediff' — use Ediff session diff overlays."
  :type '(choice (const :tag "Auto-detect (ediff > diff-hl > git)" auto)
                 (const :tag "diff-hl overlays" diff-hl)
                 (const :tag "VC (git)" vc)
                 (const :tag "Ediff session" ediff))
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

(defcustom diff-minimap-preview-width 50
  "Width in columns of the inline diff preview window."
  :type 'integer
  :group 'diff-minimap)

(defcustom diff-minimap-preview-side 'right
  "Which side to display the inline diff preview window."
  :type '(choice (const :tag "Left" left)
                 (const :tag "Right" right))
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

(defface diff-minimap-hunk-region
  '((t :inherit highlight :extend t))
  "Face for the highlighted hunk region when showing inline preview."
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

(defvar-local diff-minimap--hunk-overlay nil
  "Overlay for inline diff hunk preview in the source buffer.
When non-nil, the preview is active.  Toggle with `diff-minimap-show-hunk'.")

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
  (if (and diff-minimap--ediff-control-buffer (buffer-live-p diff-minimap--ediff-control-buffer))
      t
    (pcase diff-minimap-diff-backend
      ('diff-hl (bound-and-true-p diff-hl-mode))
      ('vc (and (buffer-file-name) (executable-find "git")))
      ('ediff (diff-minimap--ediff-active-p))
      ('auto (or (diff-minimap--ediff-active-p)
                 (bound-and-true-p diff-hl-mode)
                 (and (buffer-file-name) (executable-find "git")))))))

(defun diff-minimap--collect-diff-data ()
  "Collect diff data from the configured backend.
Returns a list of (TYPE START-LINE END-LINE) where TYPE is
`added', `changed', or `removed', and START-LINE/END-LINE are
1-indexed inclusive line numbers in the current buffer.
Returns nil when no backend is available or no changes exist."
  (pcase diff-minimap-diff-backend
    ('diff-hl (diff-minimap--collect-from-diff-hl))
    ('vc (diff-minimap--collect-from-vc))
    ('ediff (diff-minimap--collect-from-ediff))
    ('auto (or (diff-minimap--collect-from-ediff)
               (diff-minimap--collect-from-diff-hl)
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

(defun diff-minimap--ediff-active-p ()
  "Return t if the current buffer is part of an active Ediff session.
Checks for overlays placed by Ediff on diff regions."
  (catch 'found
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'ediff-diff-num)
        (throw 'found t)))))

(defun diff-minimap--collect-from-ediff (&optional buf)
  "Collect diff data from Ediff overlays in BUF (or current buffer).
Returns a list of (TYPE START-LINE END-LINE) where TYPE is always
`changed', or nil if no Ediff session is active."
  (with-current-buffer (or buf (current-buffer))
    (let ((result nil))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (overlay-get ov 'ediff-diff-num)
          (let* ((st (overlay-start ov))
                 (en (overlay-end ov)))
            (when (and st en (> en st))
              (save-excursion
                (let ((sl (progn (goto-char st) (line-number-at-pos)))
                      (el (progn (goto-char en)
                                 (if (bolp) (1- (line-number-at-pos))
                                   (line-number-at-pos)))))
                  (push (list 'changed sl el) result)))))))
      (diff-minimap--merge-ranges (nreverse result)))))

(defvar diff-minimap--ediff-control-buffer nil
  "The active Ediff control buffer if rendering a dual-column minimap.")

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
  (let* ((mm-buf (get-buffer diff-minimap--buffer-name))
         (this-buf (current-buffer))
         (ediff-active (and diff-minimap--ediff-control-buffer
                            (buffer-live-p diff-minimap--ediff-control-buffer)))
         (a-buf (and ediff-active (with-current-buffer diff-minimap--ediff-control-buffer (bound-and-true-p ediff-buffer-A))))
         (b-buf (and ediff-active (with-current-buffer diff-minimap--ediff-control-buffer (bound-and-true-p ediff-buffer-B))))
         (dual-col (and a-buf (buffer-live-p a-buf) b-buf (buffer-live-p b-buf))))
    (when (and mm-buf (get-buffer-window mm-buf 0))
      (with-current-buffer this-buf
         (let* ((total (if dual-col
                           (nth 0 (with-current-buffer diff-minimap--ediff-control-buffer (diff-minimap--collect-ediff-dual)))
                         (diff-minimap--buffer-lines)))
                (nrows (or diff-minimap--last-nrows 1))
                (scale (/ (float total) nrows))
                (ws-win (if dual-col (get-buffer-window a-buf 0) (get-buffer-window this-buf 0)))
                (pt-line (if dual-col
                             (diff-minimap--physical-to-virtual-A (with-current-buffer a-buf (line-number-at-pos)) diff-minimap--ediff-control-buffer)
                           (line-number-at-pos)))
                (cur-row (min (1- nrows)
                              (floor (/ (1- pt-line) scale))))
                (vis-rows (max 1 (ceiling (window-text-height (or ws-win (selected-window))) scale)))
                (ws-row (let ((from-start (max 0 (floor (/ (1- (if dual-col
                                                                   (diff-minimap--physical-to-virtual-A
                                                                    (with-current-buffer a-buf
                                                                      (line-number-at-pos (window-start ws-win)))
                                                                    diff-minimap--ediff-control-buffer)
                                                                 (line-number-at-pos (window-start ws-win))))
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

(defun diff-minimap--physical-to-virtual-A (phys-A ediff-ctrl)
  "Convert physical line in Buffer A to a virtual aligned line for the dual minimap."
  (let ((v-line phys-A))
    (with-current-buffer ediff-ctrl
      (if (and (boundp 'ediff-number-of-differences) (numberp ediff-number-of-differences))
          (dotimes (i ediff-number-of-differences)
            (let ((ov-A (ediff-get-diff-overlay i 'A))
                  (ov-B (ediff-get-diff-overlay i 'B)))
              (when (and ov-A ov-B)
                (let* ((st-A (overlay-start ov-A)) (en-A (overlay-end ov-A))
                       (st-B (overlay-start ov-B)) (en-B (overlay-end ov-B))
                       (buf-A (overlay-buffer ov-A)) (buf-B (overlay-buffer ov-B)))
                  (when (and st-A en-A st-B en-B buf-A buf-B)
                    (let* ((sl-A (with-current-buffer buf-A (line-number-at-pos st-A)))
                           (el-A (with-current-buffer buf-A (if (= st-A en-A) sl-A (line-number-at-pos (max st-A (1- en-A))))))
                           (sl-B (with-current-buffer buf-B (line-number-at-pos st-B)))
                           (el-B (with-current-buffer buf-B (if (= st-B en-B) sl-B (line-number-at-pos (max st-B (1- en-B))))))
                           (len-A (if (= st-A en-A) 0 (1+ (- el-A sl-A))))
                           (len-B (if (= st-B en-B) 0 (1+ (- el-B sl-B)))))
                      (when (< sl-A phys-A)
                        (let ((diff-gap (- len-B len-A)))
                          (when (> diff-gap 0)
                            (cl-incf v-line diff-gap))))))))))))
    v-line))

(defun diff-minimap--get-line-face (buf line)
  "Get the most relevant Ediff face for physical LINE in BUF."
  (when (and buf (buffer-live-p buf) line)
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-min))
        (when (zerop (forward-line (1- line)))
          (let* ((beg (line-beginning-position))
                 (end (line-end-position))
                 ;; Scan slightly past the end to catch overlays that end at bol of next line
                 (ovs (overlays-in beg (min (point-max) (1+ end))))
                 (best-face nil))
            (dolist (ov ovs)
              (let ((f (overlay-get ov 'face)))
                (when (symbolp f)
                  (let ((name (symbol-name f)))
                    (cond
                     ;; Highest priority: fine diffs
                     ((string-match-p "fine-diff" name) (setq best-face f))
                     ;; Second priority: current diff
                     ((and (not (and best-face (string-match-p "fine-diff" (symbol-name best-face))))
                           (string-match-p "current-diff" name))
                      (setq best-face f))
                     ;; Fallback: any other ediff face
                     ((and (not best-face) (string-match-p "ediff-" name))
                      (setq best-face f)))))))
            best-face))))))

(defun diff-minimap--collect-ediff-dual ()
  "Collect diff-A and diff-B directly from Ediff control buffer.
Returns a list (TOTAL-VIRT DIFF-A DIFF-B).
Each entry in DIFF-A/DIFF-B is (FACE-OR-TYPE VIRT-START VIRT-END)."
  (let ((diff-A nil) (diff-B nil)
        (v-line 1) (a-line 1) (b-line 1)
        (buf-A (bound-and-true-p ediff-buffer-A))
        (buf-B (bound-and-true-p ediff-buffer-B)))
    (when (and (boundp 'ediff-number-of-differences)
               (numberp ediff-number-of-differences))
      (dotimes (i ediff-number-of-differences)
        (let* ((ov-A (ediff-get-diff-overlay i 'A))
               (ov-B (ediff-get-diff-overlay i 'B))
               (st-A (and ov-A (overlay-start ov-A)))
               (en-A (and ov-A (overlay-end ov-A)))
               (st-B (and ov-B (overlay-start ov-B)))
               (en-B (and ov-B (overlay-end ov-B)))
               (sl-A (and st-A buf-A (with-current-buffer buf-A (line-number-at-pos st-A))))
               (el-A (and en-A buf-A (with-current-buffer buf-A (line-number-at-pos (max (or st-A 1) (1- en-A))))))
               (sl-B (and st-B buf-B (with-current-buffer buf-B (line-number-at-pos st-B))))
               (el-B (and en-B buf-B (with-current-buffer buf-B (line-number-at-pos (max (or st-B 1) (1- en-B))))))
               (len-A (if (and st-A en-A (> en-A st-A) sl-A el-A) (1+ (- el-A sl-A)) 0))
               (len-B (if (and st-B en-B (> en-B st-B) sl-B el-B) (1+ (- el-B sl-B)) 0))
               (virt-lines (max 1 (max len-A len-B))))
          ;; Advance v-line past any unchanged lines since the last diff
          (when (and sl-A (> sl-A a-line))
            (cl-incf v-line (- sl-A a-line)))
          ;; Scan each virtual line in this hunk
          (dotimes (kv virt-lines)
            (let* ((curr-v (+ v-line kv))
                   (fA (when (< kv len-A) (diff-minimap--get-line-face buf-A (+ sl-A kv))))
                   (fB (when (< kv len-B) (diff-minimap--get-line-face buf-B (+ sl-B kv)))))
              ;; Fallback if no specific face found on the line (e.g. hunk gap filling)
              (unless fA
                (setq fA (cond ((= len-A 0) 'ediff-current-diff-Ancestor)
                               (t 'ediff-current-diff-A))))
              (unless fB
                (setq fB (cond ((= len-B 0) 'ediff-current-diff-Ancestor)
                               (t 'ediff-current-diff-B))))
              ;; Group into ranges
              (if (and diff-A (eq (caar diff-A) fA) (= (nth 2 (car diff-A)) (1- curr-v)))
                  (setf (nth 2 (car diff-A)) curr-v)
                (push (list fA curr-v curr-v) diff-A))
              (if (and diff-B (eq (caar diff-B) fB) (= (nth 2 (car diff-B)) (1- curr-v)))
                  (setf (nth 2 (car diff-B)) curr-v)
                (push (list fB curr-v curr-v) diff-B))))
          (cl-incf v-line virt-lines)
          (when sl-A (setq a-line (if (> len-A 0) (1+ el-A) sl-A)))
          (when sl-B (setq b-line (if (> len-B 0) (1+ el-B) sl-B))))))
    (let* ((buf-a (and (boundp 'ediff-buffer-A) ediff-buffer-A))
           (rem-A (if buf-a
                      (max 0 (- (with-current-buffer buf-a
                                  (line-number-at-pos (point-max)))
                                a-line))
                    0))
           (tot-virt (+ v-line rem-A)))
      (list tot-virt (nreverse diff-A) (nreverse diff-B)))))


(defun diff-minimap--render ()
  "Render the full minimap content with diff colours only.
Viewport and cursor highlights are applied as overlays by
`diff-minimap--update-viewport'."
  (diff-minimap--cache-faces)
  (let* ((mm-buf (get-buffer-create diff-minimap--buffer-name))
         (ediff-active (and diff-minimap--ediff-control-buffer
                            (buffer-live-p diff-minimap--ediff-control-buffer)))
         ;; During Ediff, always use buffer-A as the reference buffer
         (this-buf (if ediff-active
                      (with-current-buffer diff-minimap--ediff-control-buffer
                        (or (bound-and-true-p ediff-buffer-A) (current-buffer)))
                    (current-buffer))))
    (when (and (diff-minimap--backend-available-p)
               (get-buffer-window mm-buf 0))
      (let* ((a-buf (and ediff-active (with-current-buffer diff-minimap--ediff-control-buffer (bound-and-true-p ediff-buffer-A))))
             (b-buf (and ediff-active (with-current-buffer diff-minimap--ediff-control-buffer (bound-and-true-p ediff-buffer-B))))
             (dual-col (and a-buf (buffer-live-p a-buf) b-buf (buffer-live-p b-buf)))
             ;; NEVER fall back to VC/git when Ediff is active
             (diff-data (unless (or dual-col ediff-active)
                          (with-current-buffer this-buf
                            (diff-minimap--collect-diff-data))))
             (ediff-dual (when dual-col
                           (with-current-buffer diff-minimap--ediff-control-buffer
                             (diff-minimap--collect-ediff-dual))))
             (total (if dual-col
                        (nth 0 ediff-dual)
                      (with-current-buffer this-buf (diff-minimap--buffer-lines))))
             (diff-A (when dual-col (nth 1 ediff-dual)))
             (diff-B (when dual-col (nth 2 ediff-dual)))
             (src-win (if dual-col (get-buffer-window a-buf 0) (get-buffer-window this-buf 0)))
             (mm-win (get-buffer-window mm-buf 0))
             (actual-width (let ((base-w (if mm-win (window-width mm-win) diff-minimap-width)))
                             (if (and (numberp diff-minimap-font-scale) (> diff-minimap-font-scale 0))
                                 (ceiling (/ (float base-w) diff-minimap-font-scale))
                               base-w)))
             (nrows (max 1
                         (let ((row-px (ceiling (* (frame-char-height)
                                                   diff-minimap-font-scale))))
                           (floor (/ (window-body-height
                                      (or mm-win src-win (selected-window)) t)
                                     row-px)))))
             (scale (/ (float total) nrows))
             (row-diff (make-vector nrows nil))
             (row-diff-A (when dual-col (make-vector nrows nil)))
             (row-diff-B (when dual-col (make-vector nrows nil))))
        (setq diff-minimap--last-nrows nrows
              diff-minimap--last-themes (and (boundp 'custom-enabled-themes)
                                              custom-enabled-themes))
        (if dual-col
            (progn
              (dolist (change diff-A)
                (let* ((ty (car change)) (sl (nth 1 change)) (el (nth 2 change))
                       (fr (floor (/ (1- sl) scale)))
                       (lr (min (1- nrows) (floor (/ (1- el) scale)))))
                  (cl-loop for r from fr to lr do (aset row-diff-A r ty))))
              (dolist (change diff-B)
                (let* ((ty (car change)) (sl (nth 1 change)) (el (nth 2 change))
                       (fr (floor (/ (1- sl) scale)))
                       (lr (min (1- nrows) (floor (/ (1- el) scale)))))
                  (cl-loop for r from fr to lr do (aset row-diff-B r ty)))))
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
            (diff-minimap--fringe-update diff-data)))
        (let* ((fbg (lambda (f attr d)
                      (if (facep f)
                          (let ((v (face-attribute f attr nil t)))
                            (if (or (not v) (eq v 'unspecified) (not (stringp v))) d v))
                        d)))
               (resolved-faces (make-hash-table :test 'eq))
               (nrm-face `(:background ,diff-minimap--norm-bg :extend t))
               (ins-face `(:background ,diff-minimap--ins-bg :extend t))
               (chg-face `(:background ,diff-minimap--chg-bg :extend t))
               (del-face `(:background ,diff-minimap--del-bg :extend t))
               ;; Helper to resolve arbitrary face symbols to text properties
               (resolve (lambda (ty fallback)
                          (if (facep ty)
                              (or (gethash ty resolved-faces)
                                  (puthash ty `(:background ,(funcall fbg ty :background (plist-get fallback :background)) :extend t) resolved-faces))
                            fallback))))
          (with-current-buffer mm-buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (diff-minimap--clear-overlays)
              (dotimes (i nrows)
                (let ((sline (1+ (floor (* i scale)))))
                  (insert
                   (propertize " " 'face nrm-face
                               'source-line sline 'source-buf this-buf)
                   (propertize (make-string (max 0 (1- actual-width)) ?\s)
                               'face nrm-face
                               'source-line sline 'source-buf this-buf)
                   (propertize "\n" 'face nrm-face))))
              ;; Diff colour overlays
              (dotimes (i nrows)
                (if dual-col
                    (let ((dtypeA (aref row-diff-A i))
                          (dtypeB (aref row-diff-B i))
                          (wA (ceiling (/ actual-width 2.0)))
                          (pos (diff-minimap--row->pos i)))
                      (when dtypeA
                        (let* ((f (funcall resolve dtypeA chg-face))
                               (ov (make-overlay pos (+ pos wA) mm-buf)))
                          (overlay-put ov 'face f)
                          (overlay-put ov 'priority 3)
                          (overlay-put ov 'diff-minimap-overlay t)))
                      (when dtypeB
                        (let* ((f (funcall resolve dtypeB ins-face))
                               (ov (make-overlay (+ pos wA) (+ pos actual-width) mm-buf)))
                          (overlay-put ov 'face f)
                          (overlay-put ov 'priority 3)
                          (overlay-put ov 'diff-minimap-overlay t))))
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
                        (overlay-put ov 'diff-minimap-overlay t))))))))
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
  (when (get-buffer-window diff-minimap--buffer-name 0)
    (let ((buf (current-buffer))
          (mm-buf (get-buffer diff-minimap--buffer-name)))
      (when mm-buf
        (when (and diff-minimap--ediff-control-buffer
                   (buffer-live-p diff-minimap--ediff-control-buffer)
                   (or (eq buf diff-minimap--ediff-control-buffer)
                       (with-current-buffer diff-minimap--ediff-control-buffer
                         (or (eq buf (bound-and-true-p ediff-buffer-A))
                             (eq buf (bound-and-true-p ediff-buffer-B))
                             (eq buf (bound-and-true-p ediff-buffer-C))))))
          (setq buf diff-minimap--ediff-control-buffer))
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
                  (src-win (get-buffer-window buf 0))
                   (cur-nrows (let ((mm-win (get-buffer-window mm-buf 0)))
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
              (diff-minimap--update-viewport))))))
  ;; Auto-remove hunk overlay when point leaves the hunk range
  (when (and diff-minimap--hunk-overlay
             (overlay-buffer diff-minimap--hunk-overlay)
             (eq (overlay-buffer diff-minimap--hunk-overlay) (current-buffer)))
    (let ((ov-start (overlay-start diff-minimap--hunk-overlay))
          (ov-end (overlay-end diff-minimap--hunk-overlay)))
      (when (and ov-start ov-end
                 (or (< (point) ov-start) (>= (point) ov-end)))
        (delete-overlay diff-minimap--hunk-overlay)
        (setq diff-minimap--hunk-overlay nil)))))

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

(defun diff-minimap--click-show-hunk ()
  "Handle right-click: jump to source and preview the diff hunk."
  (interactive)
  (let* ((pos (event-start last-input-event))
         (line (get-text-property (posn-point pos) 'source-line))
         (buf (get-text-property (posn-point pos) 'source-buf)))
    (when (and line buf (buffer-live-p buf))
      (with-selected-window (get-buffer-window buf)
        (goto-char (point-min))
        (forward-line (1- line))
        (recenter 0)
        (diff-minimap-show-hunk)))))

(defun diff-minimap--extract-hunk-from-patch (patch target-line)
  "Extract from unified diff PATCH the hunk covering TARGET-LINE.
Returns the hunk text as a string, or nil if not found."
  (catch 'done
    (let ((lines (split-string patch "\n"))
          (result nil)
          (new-line nil)
          (hunk-start nil))
      (dolist (line lines)
        (cond
         ((string-match "^@@ -\\([0-9]+\\),?\\([0-9]*\\) \\+\\([0-9]+\\),?\\([0-9]*\\) @@" line)
          (when (and hunk-start (<= hunk-start target-line (1- new-line)))
            (throw 'done (string-join (nreverse result) "\n")))
          (setq hunk-start (string-to-number (match-string 3 line))
                new-line hunk-start
                result (list line)))
         (new-line
          (push line result)
          (when (string-match "^\\([+ ]\\)" line)
            (cl-incf new-line)))))
      (when (and hunk-start (<= hunk-start target-line (1- new-line)))
        (string-join (nreverse result) "\n")))))

(defun diff-minimap--extract-sub-hunk (hunk-text target-line)
  "From unified diff HUNK-TEXT, extract only the change group
containing TARGET-LINE (new-file line number).
A change group is a contiguous block of `-' and `+' lines separated
by context lines.  Returns the condensed hunk or HUNK-TEXT as-is."
  (let* ((lines (split-string hunk-text "\n"))
         (header (car lines))
         (body (cdr lines))
         (new-line nil)
         (groups nil)
         (cur-start nil)
         (cur-lines nil))
    (when (string-match "^@@ -\\([0-9]+\\),?\\([0-9]*\\) \\+\\([0-9]+\\),?\\([0-9]*\\) @@" header)
      (setq new-line (string-to-number (match-string 3 header)))
      (dolist (line body)
        (pcase (and (> (length line) 0) (substring line 0 1))
          (" "
           (when cur-start
             (push (cons cur-start (nreverse cur-lines)) groups)
             (setq cur-start nil cur-lines nil))
           (cl-incf new-line))
          ("-"
           (unless cur-start (setq cur-start new-line))
           (push line cur-lines))
          ("+"
           (unless cur-start (setq cur-start new-line))
           (push line cur-lines)
           (cl-incf new-line))
          (_ nil)))
      (when cur-start
        (push (cons cur-start (nreverse cur-lines)) groups))
      (setq groups (nreverse groups))
      (let ((selected
             (cl-find-if
              (lambda (g)
                (let* ((g-start (car g))
                       (g-lines (cdr g))
                       (n-plus (cl-count-if
                                (lambda (l) (string-prefix-p "+" l))
                                g-lines)))
                  (and (> n-plus 0)
                       (<= g-start target-line)
                       (<= target-line (1- (+ g-start n-plus))))))
              groups)))
        (if selected
            (string-join (cons header (cdr selected)) "\n")
          hunk-text)))))

;;;###autoload
(defun diff-minimap-show-hunk ()
  "Show the diff hunk at point as an inline overlay.
Toggle: if the hunk overlay is already displayed, remove it.
When point moves outside the hunk range, the overlay is removed."
  (interactive)
  (if (and diff-minimap--hunk-overlay
           (overlay-buffer diff-minimap--hunk-overlay)
           (eq (overlay-buffer diff-minimap--hunk-overlay) (current-buffer)))
      (progn
        (delete-overlay diff-minimap--hunk-overlay)
        (setq diff-minimap--hunk-overlay nil))
    (unless (buffer-file-name)
      (user-error "Buffer has no file"))
    (let* ((line (line-number-at-pos))
           (data (diff-minimap--collect-diff-data))
           (hunk (cl-find-if (lambda (h) (<= (nth 1 h) line (nth 2 h))) data)))
      (unless hunk
        (user-error "No diff hunk at line %d" line))
      (let* ((start (nth 1 hunk))
             (end (nth 2 hunk))
             (file (buffer-file-name))
             (rel-file (file-relative-name file))
             (default-directory (file-name-directory file))
             (full-patch (diff-minimap--git-diff
                          (format "diff --no-color --unified=3 HEAD -- %s"
                                  (shell-quote-argument rel-file))))
             (patch (and full-patch
                         (diff-minimap--extract-hunk-from-patch full-patch start)))
             (narrowed (and patch
                            (diff-minimap--extract-sub-hunk patch line))))
        (unless patch
          (user-error "No diff output for hunk at line %d" start))
        (let ((fontified (with-temp-buffer
                           (insert narrowed)
                           (diff-mode)
                           (font-lock-ensure)
                           (concat (buffer-string) "\n"))))
          (save-excursion
            (goto-char (point-min))
            (forward-line (1- start))
            (let ((ov (make-overlay (point)
                                    (progn (forward-line (1+ (- end start)))
                                           (point)))))
              (overlay-put ov 'diff-minimap-hunk t)
              (overlay-put ov 'before-string fontified)
              (overlay-put ov 'face 'diff-minimap-hunk-region)
              (overlay-put ov 'priority 100)
              (setq diff-minimap--hunk-overlay ov))))))))

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
            (define-key map [mouse-3] #'diff-minimap--click-show-hunk)
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

;;;###autoload
(defun diff-minimap-ediff-setup ()
  "Open the diff minimap during an Ediff session."
  (interactive)
  (when (and (boundp 'ediff-buffer-A) (buffer-live-p ediff-buffer-A))
    (setq diff-minimap--ediff-control-buffer (current-buffer))
    (unless (get-buffer-window diff-minimap--buffer-name)
      (diff-minimap-mode 1)
      (run-with-idle-timer 0 nil
        (lambda ()
          (let* ((ed-ctrl diff-minimap--ediff-control-buffer)
                 (a-b (and ed-ctrl (buffer-live-p ed-ctrl) (with-current-buffer ed-ctrl (and (boundp 'ediff-buffer-A) ediff-buffer-A))))
                 (b-b (and ed-ctrl (buffer-live-p ed-ctrl) (with-current-buffer ed-ctrl (and (boundp 'ediff-buffer-B) ediff-buffer-B))))
                 (c-b (and ed-ctrl (buffer-live-p ed-ctrl) (with-current-buffer ed-ctrl (and (boundp 'ediff-buffer-C) ediff-buffer-C)))))
            (when (and a-b b-b (not (get-buffer-window diff-minimap--buffer-name 0)))
              (let ((win (or (get-buffer-window a-b 0)
                             (get-buffer-window b-b 0)
                             (get-buffer-window c-b 0))))
                (when win
                  (with-selected-window win
                    (diff-minimap-toggle)))))))))))

(defun diff-minimap-ediff-teardown ()
  "Hide the minimap when Ediff quits."
  (setq diff-minimap--ediff-control-buffer nil)
  (when (get-buffer-window diff-minimap--buffer-name 0)
    (diff-minimap-toggle)))

(defun diff-minimap-ediff-debug ()
  "Print diagnostic info about the Ediff dual-column minimap state.
Run this from the Ediff control panel (the small \"*Ediff Control Panel*\"
buffer) while an Ediff session is active."
  (interactive)
  (let* ((ctrl diff-minimap--ediff-control-buffer)
         (ctrl-live (and ctrl (buffer-live-p ctrl)))
         (a-buf (and ctrl-live (with-current-buffer ctrl (bound-and-true-p ediff-buffer-A))))
         (b-buf (and ctrl-live (with-current-buffer ctrl (bound-and-true-p ediff-buffer-B))))
         (dual-col (and a-buf (buffer-live-p a-buf) b-buf (buffer-live-p b-buf)))
         (n-diffs (and ctrl-live (with-current-buffer ctrl
                        (and (boundp 'ediff-number-of-differences)
                             ediff-number-of-differences))))
         (ediff-dual (and dual-col
                         (with-current-buffer ctrl
                           (diff-minimap--collect-ediff-dual)))))
    (message "Ediff debug:\n  ctrl-buf: %s (live: %s)\n  buf-A: %s (live: %s)\n  buf-B: %s (live: %s)\n  dual-col: %s\n  n-diffs: %s\n  total-virt: %s\n  diff-A entries: %s\n  diff-B entries: %s\n  diff-A: %s\n  diff-B: %s"
             ctrl ctrl-live
             a-buf (and a-buf (buffer-live-p a-buf))
             b-buf (and b-buf (buffer-live-p b-buf))
             dual-col n-diffs
             (and ediff-dual (nth 0 ediff-dual))
             (and ediff-dual (length (nth 1 ediff-dual)))
             (and ediff-dual (length (nth 2 ediff-dual)))
             (and ediff-dual (nth 1 ediff-dual))
             (and ediff-dual (nth 2 ediff-dual)))))

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


;;; VC diff navigation

(defvar diff-minimap--vc-diff-context nil
  "Cons (BUFFER . LINE) saved before `vc-diff' for hunk navigation.")

(defun diff-minimap--before-vc-diff (&rest _)
  "Save current buffer and line before `vc-diff'."
  (setq diff-minimap--vc-diff-context
        (cons (current-buffer) (line-number-at-pos))))

(defun diff-minimap--after-vc-diff (&rest _)
  "After `vc-diff', jump to the hunk line matching the saved source line."
  (when-let ((context diff-minimap--vc-diff-context)
             (buf (car context))
             (line (cdr context))
             (diff-buf (get-buffer "*vc-diff*")))
    (setq diff-minimap--vc-diff-context nil)
    (with-current-buffer diff-buf
      (goto-char (point-min))
      (let ((hdr-pos nil) (new-start nil))
        (while (re-search-forward "^@@ -\\([0-9]+\\),?\\([0-9]*\\) \\+\\([0-9]+\\),?\\([0-9]*\\) @@" nil t)
          (let* ((ns (string-to-number (match-string 3)))
                 (nc (let ((c (match-string 4)))
                       (if (string-empty-p c) 1 (string-to-number c)))))
            (when (<= ns line (1- (+ ns nc)))
              (setq hdr-pos (match-beginning 0)
                    new-start ns))))
        (if (not hdr-pos)
            (goto-char (point-min))
          (goto-char hdr-pos)
          (forward-line 1)
          (catch 'found
            (while (< (point) (point-max))
              (cond
               ((looking-at "-")
                (forward-line 1))
               ((looking-at "[ +]")
                (when (= new-start line)
                  (throw 'found (recenter 0)))
                (cl-incf new-start)
                (forward-line 1))
               (t (forward-line 1)))
              (when (looking-at "^@@")
                (throw 'found nil))))
          (recenter 0))))))

(defvar diff-minimap-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-]") #'diff-minimap-next-hunk)
    (define-key map (kbd "M-[") #'diff-minimap-previous-hunk)
    (define-key map (kbd "C-c p") #'diff-minimap-show-hunk)
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
        (add-hook 'isearch-mode-end-hook #'diff-minimap--search-clear)
        (advice-add 'vc-diff :before #'diff-minimap--before-vc-diff)
        (advice-add 'vc-diff :after #'diff-minimap--after-vc-diff)
        (if (fboundp 'ediff-setup)
            (diff-minimap--ensure-ediff-advice)
          (with-eval-after-load 'ediff
            (diff-minimap--ensure-ediff-advice))))
    (remove-hook 'post-command-hook #'diff-minimap--post-command)
    (remove-hook 'after-save-hook #'diff-minimap--after-save)
    (remove-hook 'isearch-update-post-hook #'diff-minimap--search-update)
    (remove-hook 'isearch-mode-end-hook #'diff-minimap--search-clear)
    (advice-remove 'vc-diff #'diff-minimap--before-vc-diff)
    (advice-remove 'vc-diff #'diff-minimap--after-vc-diff)
    (diff-minimap--remove-ediff-advice)
    (setq diff-minimap--last-buffer nil)))

(define-key vc-prefix-map (kbd "m") #'diff-minimap-toggle)
(define-key vc-prefix-map (kbd "M") #'diff-minimap-toggle-with-demap)
(define-key vc-prefix-map "]" #'diff-minimap-next-hunk)
(define-key vc-prefix-map "[" #'diff-minimap-previous-hunk)


;;; Ediff integration

(defvar diff-minimap--ediff-advised nil
  "Whether `ediff-setup' has been advised to close the minimap.")

(defun diff-minimap--before-ediff-setup (&rest _)
  "Close the minimap before ediff creates its window layout.
Side windows cannot be split by ediff, so the minimap must be
closed first.  It will be re-opened by `ediff-startup-hook' via
`diff-minimap-ediff-setup'."
  (when-let ((mm-buf (get-buffer diff-minimap--buffer-name))
             (win (get-buffer-window mm-buf)))
    (diff-minimap-toggle)))

(defun diff-minimap--ensure-ediff-advice ()
  "Install `:before' advice on `ediff-setup' if not already done."
  (unless diff-minimap--ediff-advised
    (advice-add 'ediff-setup :before #'diff-minimap--before-ediff-setup)
    (setq diff-minimap--ediff-advised t)))

(defun diff-minimap--remove-ediff-advice ()
  "Remove the `:before' advice on `ediff-setup'."
  (when diff-minimap--ediff-advised
    (advice-remove 'ediff-setup #'diff-minimap--before-ediff-setup)
    (setq diff-minimap--ediff-advised nil)))

(add-hook 'ediff-startup-hook #'diff-minimap-ediff-setup)
(add-hook 'ediff-quit-hook #'diff-minimap-ediff-teardown)

(provide 'diff-minimap)
;;; diff-minimap.el ends here
