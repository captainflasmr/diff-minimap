;;; diff-minimap.el --- VSCode-style minimap showing diff regions -*- lexical-binding: t; -*-
;;
;; Author: James Dyer <captainflasmr@gmail.com>
;; Version: 0.2.1
;; Package-Requires: ((emacs "27.1") (diff-hl "0.9"))
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
;; line according to its diff-hl status (added / changed / removed) while
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

(require 'diff-hl)
(require 'cl-lib)

(defgroup diff-minimap nil
  "VSCode-style minimap showing diff regions across the entire buffer."
  :group 'tools)

(defcustom diff-minimap-font-scale 0.4
  "Fraction of default font height for the minimap. 1.0 = normal, 0.4 = tiny."
  :type 'float
  :group 'diff-minimap)

(defcustom diff-minimap-width 8
  "Width in characters of the diff-minimap side window (at the small font)."
  :type 'integer
  :group 'diff-minimap)

(defcustom diff-minimap-side 'right
  "Which side to display the diff-minimap window."
  :type '(choice (const left) (const right))
  :group 'diff-minimap)

(defcustom diff-minimap-viewport-style 'edge-bar
  "How to render the viewport indicator in the minimap.
`edge-bar' — solid bars at the top and bottom rows of the viewport.
`filled'   — solid background across the entire viewport (obscures diffs).
`outline'  — overline/underline in default foreground (theme-safe).
`stipple'  — bitmap dot pattern over the viewport, lets diffs show through."
  :type '(choice (const :tag "Edge bars (top & bottom rows)" edge-bar)
                 (const :tag "Filled block (full background)" filled)
                 (const :tag "Overline/underline in default foreground" outline)
                 (const :tag "Stipple dot pattern (diffs visible)" stipple))
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

(defcustom diff-minimap-colour-source 'diff-hl
  "Which face colours to use for diff highlights in the minimap.
`diff-hl' — prefer =diff-hl-insert/change/deleted= fringe faces.
`diff'    — prefer built-in =diff-added/changed/removed= faces."
  :type '(choice (const :tag "diff-hl fringe colours" diff-hl)
                 (const :tag "Built-in diff colours" diff))
  :group 'diff-minimap)

(defface diff-minimap-font
  '((t :height 0.4 :inherit default))
  "Face used for the minimap buffer — tiny font for fine-grained display."
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

(defun diff-minimap--cache-faces ()
  "Compute and cache face colours used by the minimap.
Respects `diff-minimap-colour-source' for diff highlight priority."
  (let ((fbg (lambda (f attr d)
               (let ((v (face-attribute f attr nil t)))
                 (if (or (not v) (eq v 'unspecified) (not (stringp v)))
                     d v)))))
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
    (setq diff-minimap--cur-bg  (funcall fbg 'cursor :background "#00ffff"))))

(defun diff-minimap--row->pos (row)
  "Return buffer position at the start of minimap ROW (0-indexed)."
  (save-excursion
    (goto-char (point-min))
    (forward-line row)
    (point)))

(defun diff-minimap--clear-overlays ()
  "Remove viewport edge and cursor overlays from the minimap buffer."
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
        (let* ((total (line-number-at-pos (point-max) t))
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
                                  (>= cur-row (+ from-start vis-rows)))
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
                 (overlay-put diff-minimap--viewport-overlay 'priority 5))
                ('outline
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
                              `(:box (:line-width 2 :color ,diff-minimap--cur-bg)
                                     :extend t))
                 (overlay-put diff-minimap--viewport-overlay 'priority 5))
                ('stipple
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
                              `(:stipple ,(diff-minimap--resolve-stipple) :extend t))
                 (overlay-put diff-minimap--viewport-overlay 'priority 5)))
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
    (when (and (bound-and-true-p diff-hl-mode)
               (get-buffer-window mm-buf))
      (let* ((total (with-current-buffer this-buf
                      (line-number-at-pos (point-max) t)))
             (src-win (get-buffer-window this-buf))
             (mm-win (get-buffer-window mm-buf))
             (nrows (max 1
                         (cond (src-win
                                (floor (/ (window-height src-win)
                                          diff-minimap-font-scale)))
                               (mm-win (window-height mm-win))
                               (t (frame-height)))))
             (scale (/ (float total) nrows))
             (row-diff (make-vector nrows nil)))
        (setq diff-minimap--last-nrows nrows
              diff-minimap--last-themes (and (boundp 'custom-enabled-themes)
                                              custom-enabled-themes))
        (with-current-buffer this-buf
          (setq diff-minimap--last-tick (buffer-chars-modified-tick))
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
                        (let ((fr (floor (/ (1- sl) scale)))
                              (lr (min (1- nrows) (floor (/ el scale)))))
                          (cl-loop for r from fr to lr
                                   do (aset row-diff r ty)))))))))))
        ;; Write minimap content — diff colours only
        (let ((ins-face `(:background ,diff-minimap--ins-bg :extend t))
              (chg-face `(:background ,diff-minimap--chg-bg :extend t))
              (del-face `(:background ,diff-minimap--del-bg :extend t))
              (nrm-face `(:background ,diff-minimap--norm-bg :extend t)))
          (with-current-buffer mm-buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (diff-minimap--clear-overlays)
              (dotimes (i nrows)
                (let* ((dtype (aref row-diff i))
                       (face (cond ((eq dtype 'added) ins-face)
                                   ((eq dtype 'changed) chg-face)
                                   ((eq dtype 'removed) del-face)
                                   (t nrm-face)))
                       (sline (1+ (floor (* i scale)))))
                  (insert
                   (propertize " " 'face face
                               'source-line sline 'source-buf this-buf)
                   (propertize (make-string (1- diff-minimap-width) ?\s)
                                'face face
                                'source-line sline 'source-buf this-buf)
                   (propertize "\n" 'face face))))))
            ;; Recreate viewport/cursor overlays from source buffer context
            (diff-minimap--update-viewport))))))

(defun diff-minimap--post-command ()
  "Immediate post-command-hook: update viewport/cursor overlays or full re-render.
Full re-render only when buffer content or window size changed."
  (when (and (bound-and-true-p diff-hl-mode)
             (get-buffer-window diff-minimap--buffer-name))
    (let ((mm-buf (get-buffer diff-minimap--buffer-name))
          (this-buf (current-buffer)))
      (when mm-buf
        (let* ((tick (with-current-buffer this-buf
                       (buffer-chars-modified-tick)))
               (src-win (get-buffer-window this-buf))
               (cur-nrows (and src-win
                               (floor (/ (window-height src-win)
                                         diff-minimap-font-scale))))
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
  "Force re-render after save (idle delay lets diff-hl catch up)."
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
          (delete-window (get-buffer-window mm-buf)))
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
(define-minor-mode diff-minimap-mode
  "Keep diff minimap in sync on scroll and save."
  :lighter " DMap"
  :global nil
  (if diff-minimap-mode
      (progn
        (add-hook 'after-save-hook #'diff-minimap--after-save nil t)
        (add-hook 'post-command-hook #'diff-minimap--post-command nil t))
    (remove-hook 'after-save-hook #'diff-minimap--after-save t)
    (remove-hook 'post-command-hook #'diff-minimap--post-command t)))

(define-key vc-prefix-map (kbd "m") #'diff-minimap-toggle)

(provide 'diff-minimap)
;;; diff-minimap.el ends here