;;; diff-minimap.el --- VSCode-style minimap showing diff regions -*- lexical-binding: t; -*-
;;
;; Author: James Dyer <captainflasmr@gmail.com>
;; Version: 0.12.0
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
;;   C-x v ] / C-x v [            ;; step through diff hunks
;;   C-c r                        ;; revert the hunk at point inline
;;
;; The toggle is deliberately left unbound so loading the package does not
;; shadow stock VC keys (`C-x v m' is `vc-merge').  Bind it in your own
;; configuration if you want a shortcut.  `diff-minimap-mode' is
;; buffer-local: enable it separately in each file where you want the
;; minimap.  Opening the minimap shows every
;; hunk inline; removed lines are read-only virtual text, while
;; added/changed lines stay in the buffer and can be edited in place.  The
;; diff updates live as you type, and reverting text to HEAD removes the
;; inline hunk.  `C-c r' restores the hunk at point to its HEAD text
;; without saving.  The minimap auto-refreshes on scroll and save.  Click a
;; row in the minimap to jump to that line in the source buffer, drag with
;; mouse-1 to scrub the source view, or use the wheel / two-finger scroll
;; over the minimap to scroll the source buffer.
;;
;; Customise `diff-minimap-font-scale', `diff-minimap-width', and
;; `diff-minimap-side' to tweak the appearance.
;;
;;; Code:

(require 'cl-lib)
(require 'pulse)
(require 'subr-x)

(defvar diff-hl-mode)

(declare-function ediff-get-diff-overlay "ediff-util" (n buf-type))

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

(defcustom diff-minimap-wheel-scroll-lines 3
  "Number of source-buffer lines to scroll per wheel notch in the minimap."
  :type 'integer
  :group 'diff-minimap)

(defcustom diff-minimap-inline-preview t
  "Whether opening and navigating the minimap shows editable inline diffs.
When non-nil, opening the minimap shows every diff hunk inline, and
`diff-minimap-next-hunk' / `diff-minimap-previous-hunk' ensure the
destination hunk is shown too.  Removed lines are read-only virtual
text, while added/changed lines remain ordinary editable buffer text."
  :type 'boolean
  :group 'diff-minimap)

(defcustom diff-minimap-live-diff t
  "Whether to recompute the diff from unsaved buffer text while typing.
When non-nil, editing updates the minimap and any inline hunks after
`diff-minimap-live-diff-delay' seconds of idle time.  The live diff
compares the git HEAD version with the current buffer, so reverting the
text to its original state removes the inline hunks without saving."
  :type 'boolean
  :group 'diff-minimap)

(defcustom diff-minimap-live-diff-delay 0.2
  "Idle seconds before recomputing the live diff after an edit."
  :type 'number
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

(defface diff-minimap-inline-removed
  '((((class color) (min-colors 88) (background dark))
     :background "#5a1e1e" :foreground "#ffb3b3" :extend t)
    (((class color) (min-colors 88) (background light))
     :background "#ffd7d5" :foreground "#82071e" :extend t)
    (t :background "#5a1e1e" :extend t))
  "Face for removed lines shown as read-only virtual text inline."
  :group 'diff-minimap)

(defface diff-minimap-inline-added
  '((((class color) (min-colors 88) (background dark))
     :background "#204d26" :extend t)
    (((class color) (min-colors 88) (background light))
     :background "#ccffd8" :extend t)
    (t :background "#204d26" :extend t))
  "Face for added lines in an editable inline diff."
  :group 'diff-minimap)

(defface diff-minimap-inline-changed
  '((((class color) (min-colors 88) (background dark))
     :background "#4d4218" :extend t)
    (((class color) (min-colors 88) (background light))
     :background "#ffe7c2" :extend t)
    (t :background "#4d4218" :extend t))
  "Face for changed lines in an editable inline diff."
  :group 'diff-minimap)

(defvar-local diff-minimap--last-tick nil
  "Buffer tick at last full render — for detecting content changes.")

(defvar-local diff-minimap--live-diff-timer nil
  "Buffer-local idle timer for a pending live diff refresh.")

(defvar-local diff-minimap--inline-active nil
  "Whether this buffer should keep inline hunks in sync with edits.")

(defvar-local diff-minimap--inline-suspended nil
  "Non-nil when inline hunks were hidden for an Ediff session.
The hunks are restored when the buffer is shown outside the Ediff
windows, so leaving the session with `tab-bar-history-back' brings
them back.")

(defvar-local diff-minimap--sidebar-intended nil
  "Whether this buffer wants the minimap sidebar shown.
The sidebar is hidden for buffers without local changes while this
remains non-nil, so switching back to a changed file restores it.
Only buffers with `diff-minimap-mode' enabled set this.")

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

(defvar diff-minimap--ediff-control-buffer nil
  "The active Ediff control buffer if rendering a dual-column minimap.")

(defvar diff-minimap--global-hooks-installed nil
  "Whether the global hooks and advice used by enabled buffers are installed.")

(defvar diff-minimap--ediff-visible nil
  "Whether the current Ediff session was visible at the last command.")

;; Cached face colours — recomputed in `diff-minimap--cache-faces'.
(defvar diff-minimap--norm-bg "#1a1a1a")
(defvar diff-minimap--view-bg "#404060")
(defvar diff-minimap--ins-bg  "#2ea043")
(defvar diff-minimap--chg-bg  "#d29922")
(defvar diff-minimap--del-bg  "#da3633")
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
                     (if (and (stringp v) (color-name-to-rgb v))
                         v d))
                 d))))
    (setq diff-minimap--norm-bg
          (funcall fbg 'default :background
                   (let ((bg (frame-parameter nil 'background-color)))
                     (if (and (stringp bg) (color-name-to-rgb bg))
                         bg
                       "#1a1a1a"))))
    (setq diff-minimap--view-bg (funcall fbg 'region :background "#404060"))
    (if (eq diff-minimap-colour-source 'diff-hl)
        (progn
          (setq diff-minimap--ins-bg (funcall fbg 'diff-hl-insert :background
                                              (funcall fbg 'diff-added :background "#2ea043")))
          (setq diff-minimap--chg-bg (funcall fbg 'diff-hl-change :background
                                              (funcall fbg 'diff-changed :background "#d29922")))
          (setq diff-minimap--del-bg (funcall fbg 'diff-hl-delete :background
                                              (funcall fbg 'diff-removed :background "#da3633"))))
      (setq diff-minimap--ins-bg  (funcall fbg 'diff-added :background
                                           (funcall fbg 'diff-hl-insert :background "#2ea043")))
      (setq diff-minimap--chg-bg  (funcall fbg 'diff-changed :background
                                           (funcall fbg 'diff-hl-change :background "#d29922")))
      (setq diff-minimap--del-bg  (funcall fbg 'diff-removed :background
                                           (funcall fbg 'diff-hl-delete :background "#da3633"))))
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

(defun diff-minimap--git-output (&rest args)
  "Run git with ARGS and return its stdout as a string, or nil.
ARGS is passed directly to `process-file', so file names containing
spaces or shell metacharacters are safe."
  (ignore-errors
    (with-temp-buffer
      (let ((exit-code (apply #'process-file "git" nil t nil args)))
        (unless (<= exit-code 1)
          (error "git command failed: exit %d" exit-code)))
      (let ((s (buffer-string)))
        (unless (string-empty-p s) s)))))

(defun diff-minimap--git-toplevel ()
  "Return the absolute git work tree root for `default-directory', or nil."
  (let ((root (diff-minimap--git-output "rev-parse" "--show-toplevel")))
    (when root
      (string-trim root))))

(defun diff-minimap--git-file-context (file)
  "Return (ROOT . REL-FILE) for FILE in its git work tree, or nil.
ROOT is the absolute work tree root and REL-FILE is relative to it."
  (let* ((default-directory (file-name-directory file))
         (root (diff-minimap--git-toplevel)))
    (when root
      (cons root (file-relative-name file root)))))

(defun diff-minimap--collect-from-vc ()
  "Collect diff data using git.
Returns a list of (TYPE START-LINE END-LINE) or nil."
  (when-let* ((file (buffer-file-name))
              (context (diff-minimap--git-file-context file))
              (root (car context))
              (rel-file (cdr context)))
    (let ((default-directory root))
      (let ((output (or (diff-minimap--current-patch file)
                        ;; Only fall back to the index when the live buffer
                        ;; is not the source: otherwise reverted unsaved text
                        ;; would keep showing staged changes.
                        (unless (and diff-minimap-live-diff
                                     (buffer-modified-p))
                          (diff-minimap--git-output
                           "diff" "--no-color" "--unified=0" "--cached"
                           "--" rel-file)))))
        (when output
          (diff-minimap--parse-git-diff (split-string output "\n" t)))))))

(defun diff-minimap--buffer-diff (rel-file)
  "Return a unified diff between HEAD and the current buffer text.
REL-FILE is relative to the git work tree root in `default-directory'.
Returns nil outside a git work tree or when the buffer matches HEAD."
  (when (diff-minimap--git-output "rev-parse" "--is-inside-work-tree")
    (let* ((head (or (ignore-errors
                       (diff-minimap--git-output
                        "show" (concat "HEAD:" rel-file)))
                     ""))
           (content (save-restriction
                      (widen)
                      (buffer-substring-no-properties (point-min) (point-max))))
           (old-file (make-temp-file "diff-minimap-old-"))
           (new-file (make-temp-file "diff-minimap-new-")))
      (unwind-protect
          (progn
            (let ((diff-minimap-live-diff nil))
              (with-temp-file old-file
                (insert head))
              (with-temp-file new-file
                (insert content)))
            (diff-minimap--git-output
             "diff" "--no-index" "--no-color" "--unified=0"
             old-file new-file))
        (ignore-errors (delete-file old-file))
        (ignore-errors (delete-file new-file))))))

(defun diff-minimap--current-patch (file)
  "Return a unified diff for FILE, using the live buffer when appropriate.
When `diff-minimap-live-diff' is non-nil and the current buffer is
modified, compare HEAD with the buffer text.  Otherwise compare HEAD
with the saved file."
  (when-let* ((context (diff-minimap--git-file-context file))
              (root (car context))
              (rel-file (cdr context)))
    (let ((default-directory root))
      (if (and diff-minimap-live-diff
               (buffer-modified-p))
          (diff-minimap--buffer-diff rel-file)
        (diff-minimap--git-output
         "diff" "--no-color" "--unified=0" "HEAD" "--" rel-file)))))

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
      (push (list 'removed (1+ hunk-new-start) (1+ hunk-new-start)) result))
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
    (let ((last-line (diff-minimap--buffer-lines)))
      (dolist (change diff-data)
        (let* ((ty (car change))
               (start (max 1 (min last-line (nth 1 change))))
               (end (max 1 (min last-line (nth 2 change))))
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
                       do (let* ((beg (line-beginning-position))
                                 (ov-end (min (point-max) (1+ beg)))
                                 (ov (make-overlay beg ov-end)))
                            (overlay-put ov 'before-string
                                         (propertize " " 'display
                                                     (diff-minimap--fringe-display bmp face)))
                            (overlay-put ov 'diff-minimap-fringe t))
                       (forward-line 1)))))))))

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


(defun diff-minimap--minimap-row-height (win)
  "Return the pixel height of one minimap row in WIN, or nil."
  (when (and win (window-live-p win))
    (or (let ((lh (ignore-errors
                    (window-line-height (window-start win) win))))
          (and lh (numberp (car lh)) (> (car lh) 0) (car lh)))
        (with-current-buffer (window-buffer win)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t))
            (unless (> (buffer-size) 0)
              (insert " \n"))
            (let* ((size (ignore-errors
                           (window-text-pixel-size
                            win (point-min)
                            (min (point-max) (1+ (line-end-position)))
                            nil nil)))
                   (height (and size (cdr size))))
              (and (numberp height) (> height 0) height)))))))

(defun diff-minimap--render (&optional window)
  "Render the full minimap content with diff colours only.
Viewport and cursor highlights are applied as overlays by
`diff-minimap--update-viewport'.  Optional WINDOW is the minimap
window to use when it has just been created and is not yet
registered with `get-buffer-window'."
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
             (mm-win (or window (get-buffer-window mm-buf 0)))
             (actual-width (let ((base-w (if mm-win (window-width mm-win) diff-minimap-width)))
                             (if (and (numberp diff-minimap-font-scale) (> diff-minimap-font-scale 0))
                                 (ceiling (/ (float base-w) diff-minimap-font-scale))
                               base-w)))
             (nrows (max 1
                         (if mm-win
                             (let ((row-px (diff-minimap--minimap-row-height mm-win))
                                   (body-px (window-body-height mm-win t)))
                               (if (and row-px (> body-px 0))
                                   (floor (/ body-px row-px))
                                 (let ((row-px (ceiling (* (frame-char-height)
                                                           diff-minimap-font-scale))))
                                   (floor (/ body-px row-px)))))
                           (let ((row-px (ceiling (* (frame-char-height)
                                                     diff-minimap-font-scale))))
                             (floor (/ (window-body-height
                                        (or src-win (selected-window)) t)
                                       row-px))))))
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
                     (sl (min total (nth 1 change)))
                     (el (min total (nth 2 change)))
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
  "Global post-command hook for enabled buffers.
Update the sidebar for the selected buffer when that buffer has
`diff-minimap-mode' enabled.  A buffer without the mode hides the
sidebar so it never shows another file's minimap."
  ;; Ediff hides inline hunks while its own windows are visible.  Restore
  ;; them as soon as the user leaves the Ediff windows (for example with
  ;; `tab-bar-history-back'), and hide them again when returning.
  (when diff-minimap--inline-suspended
    (diff-minimap--restore-suspended-inline-hunks))
  (let ((ediff-visible (diff-minimap--ediff-session-visible-p)))
    (when (and ediff-visible
               (or (not diff-minimap--ediff-visible)
                   (memq (current-buffer)
                         (diff-minimap--ediff-session-buffers))))
      (diff-minimap--suspend-ediff-inline-hunks))
    (setq diff-minimap--ediff-visible ediff-visible))
  (let* ((mm-buf (get-buffer diff-minimap--buffer-name))
         (ediff-session (and diff-minimap--ediff-control-buffer
                             (buffer-live-p diff-minimap--ediff-control-buffer)))
         (ediff-buf (and ediff-session
                         (or (eq (current-buffer) diff-minimap--ediff-control-buffer)
                             (memq (current-buffer)
                                   (diff-minimap--ediff-session-buffers)))))
         (enabled (or (bound-and-true-p diff-minimap-mode)
                      (and ediff-buf
                           (cl-some (lambda (b)
                                      (buffer-local-value 'diff-minimap-mode b))
                                    (diff-minimap--ediff-session-buffers)))))
         (intended (or diff-minimap--sidebar-intended ediff-buf))
         (buf (current-buffer)))
    (unless (or (eq buf mm-buf)
                (minibufferp buf))
      (cond
       ((not enabled)
        (when (and mm-buf (get-buffer-window mm-buf 0))
          (diff-minimap--close-sidebar))
        (setq diff-minimap--last-buffer nil))
       ((not intended)
        (when (and mm-buf (get-buffer-window mm-buf 0))
          (diff-minimap--close-sidebar))
        (setq diff-minimap--last-buffer nil))
       (t
        (when ediff-buf
          (setq buf diff-minimap--ediff-control-buffer))
        (unless (eq buf diff-minimap--last-buffer)
          (setq diff-minimap--last-buffer buf)
          (cond
           ((with-current-buffer buf
              (diff-minimap--current-buffer-has-changes-p))
            (if (and mm-buf (get-buffer-window mm-buf 0))
                (diff-minimap--render)
              (diff-minimap--open-sidebar))
            (run-with-timer
             0.2 nil
             (lambda ()
               (when (and (buffer-live-p buf)
                          (eq diff-minimap--last-buffer buf)
                          (get-buffer-window diff-minimap--buffer-name 0))
                 (with-current-buffer buf
                   (diff-minimap--render))))))
           (t
            (diff-minimap--remove-hunk-overlays)
            (diff-minimap--fringe-clear)
            (when (and mm-buf (get-buffer-window mm-buf 0))
              (diff-minimap--close-sidebar)))))
        (when (and mm-buf
                   (get-buffer-window mm-buf 0)
                   (diff-minimap--backend-available-p)
                   (eq buf diff-minimap--last-buffer))
          (let* ((tick (with-current-buffer buf
                         (buffer-chars-modified-tick)))
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
                                             diff-minimap--last-themes))))
                 (live-pending (and diff-minimap-live-diff
                                    (with-current-buffer buf
                                      (and (buffer-modified-p)
                                           (timerp diff-minimap--live-diff-timer))))))
            (if (and needs-full (not live-pending))
                (diff-minimap--render)
              (diff-minimap--update-viewport)))))))))

(defun diff-minimap--after-save ()
  "Force a re-render after save when this buffer owns the sidebar."
  (let ((buf (current-buffer)))
    (run-with-idle-timer
     0.05 nil
     (lambda ()
       (when (and (buffer-live-p buf)
                  (with-current-buffer buf
                    (bound-and-true-p diff-minimap-mode))
                  (eq buf diff-minimap--last-buffer)
                  (get-buffer-window diff-minimap--buffer-name 0))
         (with-current-buffer buf
           (diff-minimap--render)))))))

(defun diff-minimap--event-source (event)
  "Return (LINE . BUF) for the minimap row under EVENT, or nil.
Reads the `source-line'/`source-buf' text properties from the minimap
buffer at the EVENT position — explicitly from that buffer, not the
current one, since mouse commands run with the source buffer current.
Falls back to the row's first column for clicks landing on the trailing
newline, which carries no properties."
  (let* ((pos (event-start event))
         (win (posn-window pos))
         (pt (posn-point pos)))
    (when (and pt (windowp win))
      (let* ((mmbuf (window-buffer win))
             (bol (with-current-buffer mmbuf
                    (save-excursion (goto-char pt) (line-beginning-position))))
             (line (or (get-text-property pt 'source-line mmbuf)
                       (get-text-property bol 'source-line mmbuf)))
             (buf (or (get-text-property pt 'source-buf mmbuf)
                      (get-text-property bol 'source-buf mmbuf))))
        (when (and line buf (buffer-live-p buf))
          (cons line buf))))))

(defun diff-minimap--scroll-source-to-event (event)
  "Scroll the source buffer so the row under EVENT maps to the window top.
Moves the source window to the line decoded from EVENT and refreshes the
viewport indicator so it tracks live.  Returns non-nil when a scroll
happened."
  (let* ((info (diff-minimap--event-source event))
         (line (car info))
         (buf (cdr info))
         (win (and buf (get-buffer-window buf 0))))
    (when (window-live-p win)
      (with-selected-window win
        (goto-char (point-min))
        (forward-line (1- line))
        (recenter 0)
        (diff-minimap--update-viewport))
      t)))

(defun diff-minimap--click-handler (event)
  "Handle mouse click: scroll source to the line under EVENT."
  (interactive "e")
  (diff-minimap--scroll-source-to-event event))

(defun diff-minimap--drag-handler (event)
  "Scroll the source buffer while dragging mouse-1 within the minimap.
The grabbed row scrolls the original buffer immediately, then following
the pointer up or down scrubs the source view to track the row beneath
it until the button is released."
  (interactive "e")
  (diff-minimap--scroll-source-to-event event)
  (track-mouse
    (let ((ev (read-event)))
      (while (mouse-movement-p ev)
        (diff-minimap--scroll-source-to-event ev)
        (setq ev (read-event))))))

(defun diff-minimap--scroll-source-window (lines)
  "Scroll the source window by LINES (negative scrolls up) and refresh viewport."
  (when (and diff-minimap--last-buffer
             (buffer-live-p diff-minimap--last-buffer))
    (let ((win (get-buffer-window diff-minimap--last-buffer 0)))
      (when (window-live-p win)
        (with-selected-window win
          (condition-case nil
              (scroll-up lines)
            ((beginning-of-buffer end-of-buffer) nil))
          (diff-minimap--update-viewport))))))

(defun diff-minimap-mouse-wheel-down (_event)
  "Scroll the source buffer forward a notch from the minimap."
  (interactive "e")
  (diff-minimap--scroll-source-window diff-minimap-wheel-scroll-lines))

(defun diff-minimap-mouse-wheel-up (_event)
  "Scroll the source buffer backward a notch from the minimap."
  (interactive "e")
  (diff-minimap--scroll-source-window (- diff-minimap-wheel-scroll-lines)))

(defun diff-minimap--click-show-hunk (event)
  "Handle right-click: jump to source and preview the diff hunk."
  (interactive "e")
  (let* ((info (diff-minimap--event-source event))
         (line (car info))
         (buf (cdr info))
         (win (and buf (get-buffer-window buf 0))))
    (when (window-live-p win)
      (with-selected-window win
        (goto-char (point-min))
        (forward-line (1- line))
        (recenter 0)
        (diff-minimap-show-hunk)))))

(defun diff-minimap--hunk-last-line (start count)
  "Return the last new-file line in a hunk starting at START with COUNT lines.
A zero-length hunk covers the insertion point after START."
  (if (zerop count)
      (1+ start)
    (+ start (1- count))))

(defun diff-minimap--extract-hunk-from-patch (patch target-line)
  "Extract from unified diff PATCH the hunk covering TARGET-LINE.
Returns the hunk text as a string, or nil if not found."
  (catch 'done
    (let ((lines (split-string patch "\n"))
          (result nil)
          (hunk-start nil)
          (hunk-count nil))
      (dolist (line lines)
        (cond
         ((string-match
           "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
           line)
          (when hunk-start
            (when (<= hunk-start target-line
                      (diff-minimap--hunk-last-line hunk-start hunk-count))
              (throw 'done (string-join (nreverse result) "\n"))))
          (setq hunk-start (string-to-number (match-string 3 line))
                hunk-count (if (match-string 4 line)
                               (string-to-number (match-string 4 line))
                             1)
                result (list line)))
         (hunk-start
          (push line result))))
      (when hunk-start
        (when (<= hunk-start target-line
                  (diff-minimap--hunk-last-line hunk-start hunk-count))
          (string-join (nreverse result) "\n"))))))

(defun diff-minimap--extract-sub-hunk (hunk-text target-line)
  "From unified diff HUNK-TEXT, extract only the changes (+) and deletions (-)
containing or nearest to TARGET-LINE (new-file line number).
Context lines (starting with ' ') are strictly excluded.  No-newline
markers are kept with their change group so reverting can reproduce a
missing final newline."
  (let* ((lines (split-string hunk-text "\n"))
         (header (car lines))
         (body (cdr lines))
         (new-line 0)
         (groups nil)
         (cur-lines nil)
         (cur-start nil))
    (when (and header (string-match "^@@ -\\([0-9]+\\),?\\([0-9]*\\) \\+\\([0-9]+\\),?\\([0-9]*\\) @@" header))
      (setq new-line (string-to-number (match-string 3 header)))
      (dolist (line body)
        (let ((char (and (> (length line) 0) (substring line 0 1))))
          (cond
           ((string= char " ")
            ;; Context line: end current group and increment tracking
            (when cur-lines
              (push (list cur-start (max cur-start (1- new-line)) (nreverse cur-lines)) groups)
              (setq cur-lines nil cur-start nil))
            (cl-incf new-line))
           ((string= char "-")
            ;; Deletion: belongs to a group, does not increment new-line
            (unless cur-start (setq cur-start new-line))
            (push line cur-lines))
           ((string= char "+")
            ;; Insertion: belongs to a group, increments new-line
            (unless cur-start (setq cur-start new-line))
            (push line cur-lines)
            (cl-incf new-line))
           ((string= char "\\")
            ;; No-newline marker: keep it with the group it belongs to.
            (when cur-lines
              (push line cur-lines)))
           (t nil))))
      ;; Capture last group
      (when cur-lines
        (push (list cur-start (max cur-start (1- new-line)) (nreverse cur-lines)) groups))
      (setq groups (nreverse groups))
      ;; Find the group containing or nearest to target-line
      (let ((selected
             (or (cl-find-if (lambda (g) (<= (nth 0 g) target-line (nth 1 g))) groups)
                 (cl-find-if (lambda (g) (= (nth 0 g) target-line)) groups))))
        (if selected
            (string-join (cons header (nth 2 selected)) "\n")
          ;; Fallback: show all diff lines if no specific group matched
          (let ((diff-lines
                 (cl-remove-if-not
                  (lambda (l)
                    (and (> (length l) 0)
                         (memq (aref l 0) '(?- ?+ ?\\))))
                  body)))
            (string-join (cons header diff-lines) "\n")))))))

(defun diff-minimap--parse-inline-hunk (narrowed)
  "Return (OLD-LINES NEW-START NEW-COUNT OLD-NO-NEWLINE) parsed from NARROWED.
NARROWED is a unified diff sub-hunk as returned by
`diff-minimap--extract-sub-hunk' — a header followed only by
removed and added lines.  OLD-NO-NEWLINE is non-nil when the removed
text ended without a final newline (a no-newline marker follows a
removed line)."
  (let ((lines (split-string narrowed "\n" t))
        (old-lines nil)
        (new-start 1)
        (new-count 1)
        (last-prefix nil)
        (old-no-newline nil))
    (when (and lines
               (string-match
                "^@@ -[0-9]+\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
                (car lines)))
      (setq new-start (string-to-number (match-string 1 (car lines)))
            new-count (if (match-string 2 (car lines))
                          (string-to-number (match-string 2 (car lines)))
                        1)))
    (dolist (line (cdr lines))
      (when (> (length line) 0)
        (let ((prefix (aref line 0)))
          (cond
           ((eq prefix ?\\)
            (when (eq last-prefix ?-)
              (setq old-no-newline t)))
           (t
            (setq last-prefix prefix)
            (when (eq prefix ?-)
              (push (substring line 1) old-lines)))))))
    (list (nreverse old-lines) new-start new-count old-no-newline)))

(defun diff-minimap--change-region-at-line (line &optional full-patch)
  "Return the diff change region at LINE in the current buffer.
The value has the form (OLD-LINES NEW-START NEW-COUNT
OLD-NO-NEWLINE) as returned by `diff-minimap--parse-inline-hunk',
or nil when LINE is not part of a diff change.  FULL-PATCH, when
non-nil, is a unified diff to use instead of running git again."
  (when-let* ((file (buffer-file-name))
              (patch (or full-patch (diff-minimap--current-patch file)))
              (hunk (diff-minimap--extract-hunk-from-patch patch line))
              (narrowed (diff-minimap--extract-sub-hunk hunk line)))
    (diff-minimap--parse-inline-hunk narrowed)))

(defun diff-minimap--revert-change-region (region)
  "Restore the original text of the diff change described by REGION.
REGION is (OLD-LINES NEW-START NEW-COUNT OLD-NO-NEWLINE) as returned
by `diff-minimap--change-region-at-line'.  The buffer is modified but
not saved; undo restores the reverted text."
  (let* ((old-lines (nth 0 region))
         (new-start (nth 1 region))
         (new-count (nth 2 region))
         (old-no-newline (nth 3 region))
         (start-line (max 1 (if (zerop new-count)
                                (1+ new-start)
                              new-start)))
         (text (and old-lines (mapconcat #'identity old-lines "\n"))))
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- start-line))
      (let ((beg (point))
            (end (if (> new-count 0)
                     (progn (forward-line new-count) (point))
                   (point))))
        (when text
          ;; Lines in the middle of a file end with a newline.  Only the
          ;; final line of the original file may lack one.
          (unless old-no-newline
            (setq text (concat text "\n")))
          ;; Inserting whole lines at an unterminated final line needs a
          ;; separator before the restored text.
          (when (and (zerop new-count) (not (bolp)))
            (setq text (concat "\n" text))))
        (delete-region beg end)
        (when text (insert text))
        t))))

(defun diff-minimap--delete-hunk-overlay (ov)
  "Delete inline hunk overlay OV and release its saved marker."
  (when-let* ((marker (overlay-get ov 'diff-minimap-hunk-marker)))
    (when (markerp marker)
      (set-marker marker nil)))
  (delete-overlay ov))

(defun diff-minimap--remove-hunk-overlays ()
  "Remove all inline diff hunk overlays from the current buffer."
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'diff-minimap-hunk)
      (diff-minimap--delete-hunk-overlay ov))))

(defun diff-minimap--show-hunk-overlay (hunk target-line &optional full-patch)
  "Create an editable inline overlay for HUNK at TARGET-LINE.
HUNK is a list (TYPE START END).  Removed lines are rendered as
read-only virtual text above the hunk; the added/changed lines stay
in the buffer as ordinary editable text and are highlighted.
FULL-PATCH, when non-nil, is a precomputed unified diff to use instead
of running git again.  Return the overlay, or nil when no patch could
be produced — e.g. the buffer visits no file, or git produced no diff
for the hunk (the inline diff is git-only)."
  (when-let* ((file (buffer-file-name))
              (start (nth 1 hunk)))
    (let* ((full-patch (or full-patch (diff-minimap--current-patch file)))
           (patch (and full-patch
                       (diff-minimap--extract-hunk-from-patch full-patch start)))
           (narrowed (and patch
                          (diff-minimap--extract-sub-hunk patch target-line))))
      (when narrowed
        (let* ((parsed (diff-minimap--parse-inline-hunk narrowed))
               (old-lines (nth 0 parsed))
               (new-start (nth 1 parsed))
               (new-count (nth 2 parsed))
               (start-line (max 1 (if (zerop new-count)
                                      (1+ new-start)
                                    new-start))))
          (save-excursion
            (goto-char (point-min))
            (forward-line (1- start-line))
            (let* ((ov-start (point))
                   (ov-end (if (> new-count 0)
                               (progn (forward-line new-count) (point))
                             ov-start))
                   (ov (make-overlay ov-start ov-end))
                   (hunk-marker (save-excursion
                                  (goto-char (point-min))
                                  (forward-line (1- (max 1 start)))
                                  (copy-marker (point)))))
              (overlay-put ov 'diff-minimap-hunk t)
              (overlay-put ov 'diff-minimap-hunk-marker hunk-marker)
              (when old-lines
                (overlay-put ov 'before-string
                             (mapconcat
                              (lambda (line)
                                (propertize (concat "-" line "\n")
                                            'face 'diff-minimap-inline-removed))
                              old-lines "")))
              (when (> new-count 0)
                (overlay-put ov 'face (if old-lines
                                          'diff-minimap-inline-changed
                                        'diff-minimap-inline-added)))
              (overlay-put ov 'priority 100)
              ov)))))))

(defun diff-minimap--hunk-overlay-at-line (line)
  "Return the inline hunk overlay whose start line is LINE."
  (cl-find-if (lambda (ov)
                (and (overlay-get ov 'diff-minimap-hunk)
                     (= (line-number-at-pos (overlay-start ov)) line)))
              (overlays-in (point-min) (point-max))))

(defun diff-minimap--show-all-inline-hunks ()
  "Ensure every diff hunk in the current buffer has an inline overlay.
Existing inline hunks are left alone; missing ones are added."
  (setq diff-minimap--inline-active t)
  (let* ((data (diff-minimap--collect-diff-data))
         (full-patch (and data
                          (buffer-file-name)
                          (diff-minimap--current-patch (buffer-file-name)))))
    (dolist (hunk data)
      (unless (diff-minimap--hunk-overlay-at-line (nth 1 hunk))
        (ignore-errors
          (diff-minimap--show-hunk-overlay hunk (nth 1 hunk) full-patch))))))

(defun diff-minimap--refresh-display (&optional use-buffer-diff)
  "Recompute inline hunks and the minimap from the current buffer text.
Unlike `diff-minimap--refresh-live-diff', this does not consult
`diff-minimap-live-diff', so explicit edits such as reverting a hunk
refresh the display immediately.  When USE-BUFFER-DIFF is non-nil,
compare HEAD with the unsaved buffer text instead of the saved file,
so an explicit revert is reflected even if `diff-minimap-live-diff'
is nil."
  (let ((diff-minimap-live-diff (or use-buffer-diff diff-minimap-live-diff)))
    (when (and diff-minimap--inline-active
               (bound-and-true-p diff-minimap-mode))
      (diff-minimap--remove-hunk-overlays)
      (diff-minimap--show-all-inline-hunks))
    (when (and (eq (current-buffer)
                   (window-buffer (selected-window)))
               (or (null diff-minimap--last-buffer)
                   (eq (current-buffer) diff-minimap--last-buffer)))
      (cond
       ((not diff-minimap--sidebar-intended)
        (when (get-buffer-window diff-minimap--buffer-name 0)
          (diff-minimap--close-sidebar)))
       ((diff-minimap--current-buffer-has-changes-p)
        (if (get-buffer-window diff-minimap--buffer-name 0)
            (diff-minimap--render)
          (diff-minimap--open-sidebar)))
       (t
        (diff-minimap--remove-hunk-overlays)
        (diff-minimap--fringe-clear)
        (when (get-buffer-window diff-minimap--buffer-name 0)
          (diff-minimap--close-sidebar)))))))

(defun diff-minimap--refresh-live-diff ()
  "Recompute inline hunks and the minimap from the current buffer text."
  (when (and (bound-and-true-p diff-minimap-mode)
             diff-minimap-live-diff
             (buffer-file-name)
             (not (string-prefix-p " " (buffer-name)))
             (not diff-minimap--ediff-control-buffer))
    (diff-minimap--refresh-display)))

(defun diff-minimap--after-change (&rest _)
  "Schedule a live diff refresh after the buffer text changes."
  (when (and (bound-and-true-p diff-minimap-mode)
             diff-minimap-live-diff
             (buffer-file-name)
             (not (string-prefix-p " " (buffer-name)))
             (not diff-minimap--ediff-control-buffer))
    (let ((buf (current-buffer)))
      (when (timerp diff-minimap--live-diff-timer)
        (cancel-timer diff-minimap--live-diff-timer))
      (setq diff-minimap--live-diff-timer
            (run-with-idle-timer
             diff-minimap-live-diff-delay nil
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq diff-minimap--live-diff-timer nil)
                   (diff-minimap--refresh-live-diff)))))))))

(defun diff-minimap--ensure-mode ()
  "Signal a user error unless `diff-minimap-mode' is enabled here."
  (unless (bound-and-true-p diff-minimap-mode)
    (user-error "diff-minimap-mode is not enabled in this buffer")))

(defun diff-minimap-show-all-hunks ()
  "Show or hide all editable inline diff hunks in the current buffer.
Toggles: if any hunk overlays exist, remove them all. Otherwise, show all."
  (interactive)
  (diff-minimap--ensure-mode)
  (let ((ovs (cl-remove-if-not (lambda (ov) (overlay-get ov 'diff-minimap-hunk))
                               (overlays-in (point-min) (point-max)))))
    (if ovs
        (progn
          (diff-minimap--remove-hunk-overlays)
          (setq diff-minimap--inline-active nil))
      (diff-minimap--show-all-inline-hunks))))

(defun diff-minimap-show-hunk ()
  "Show or hide the diff hunk at point as an editable inline diff.
Removed lines are read-only virtual text; added/changed lines stay in
the buffer and can be edited normally.  Other inline hunks are left
alone; use `diff-minimap-show-all-hunks' to toggle every hunk."
  (interactive)
  (diff-minimap--ensure-mode)
  (let* ((line (line-number-at-pos))
         ;; Find ANY hunk overlay at point (including batch-created ones)
         (hunk-ov (cl-find-if (lambda (ov) (overlay-get ov 'diff-minimap-hunk))
                              (overlays-at (point)))))
    (if hunk-ov
        (progn
          (diff-minimap--delete-hunk-overlay hunk-ov)
          (unless (cl-some (lambda (ov) (overlay-get ov 'diff-minimap-hunk))
                           (overlays-in (point-min) (point-max)))
            (setq diff-minimap--inline-active nil)))
      (unless (buffer-file-name)
        (user-error "Buffer has no file"))
      (let* ((data (diff-minimap--collect-diff-data))
             (hunk (cl-find-if (lambda (h) (<= (nth 1 h) line (max (nth 1 h) (nth 2 h)))) data)))
        (unless hunk
          (user-error "No diff hunk at line %d" line))
        (if (diff-minimap--show-hunk-overlay hunk line)
            (setq diff-minimap--inline-active t)
          (user-error "No git diff available to show for this hunk"))))))

;;;###autoload
(defun diff-minimap-revert-hunk ()
  "Revert the diff hunk at point to its original HEAD text.
The change group shown as an inline diff is replaced by its original
lines without saving the buffer; undo restores the reverted text.
The minimap and any remaining inline hunks are refreshed immediately,
even when `diff-minimap-live-diff' is nil."
  (interactive)
  (unless (buffer-file-name)
    (user-error "Buffer has no file"))
  (when buffer-read-only
    (user-error "Buffer is read-only"))
  ;; Revert what is currently visible in the buffer, even when live diff
  ;; updates are disabled and the saved file no longer matches it.
  (let* ((diff-minimap-live-diff t)
         (line (line-number-at-pos))
         (region (diff-minimap--change-region-at-line line)))
    (unless region
      (user-error "No diff hunk at line %d" line))
    (diff-minimap--revert-change-region region)
    (when (bound-and-true-p diff-minimap-mode)
      (diff-minimap--refresh-display t))
    (message "Reverted hunk at line %d" line)))

(defun diff-minimap--refresh-inline-hunk ()
  "Recompute inline hunk overlays after saving the current buffer.
Each overlay records a marker at its hunk start, so it follows edits.
Overlays whose hunk no longer exists in the new diff are dropped."
  (let ((markers nil)
        (found nil))
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'diff-minimap-hunk)
        (setq found t)
        (let ((marker (overlay-get ov 'diff-minimap-hunk-marker)))
          (when (markerp marker)
            (push marker markers)))
        (delete-overlay ov)))
    (when found
      (let* ((data (diff-minimap--collect-diff-data))
             (full-patch (and data
                              (buffer-file-name)
                              (diff-minimap--current-patch (buffer-file-name)))))
        (dolist (marker markers)
          (when (marker-position marker)
            (let* ((line (line-number-at-pos marker))
                   (hunk (cl-find-if
                          (lambda (h)
                            (<= (nth 1 h) line (max (nth 1 h) (nth 2 h))))
                          data)))
              (when hunk
                (ignore-errors
                  (diff-minimap--show-hunk-overlay hunk (nth 1 hunk) full-patch)))))
          (set-marker marker nil))))))

(defun diff-minimap--current-buffer-has-changes-p ()
  "Return non-nil if the current buffer has local changes.
During an Ediff session, always return non-nil so the dual-column
minimap is not hidden."
  (or diff-minimap--ediff-control-buffer
      (and (diff-minimap--backend-available-p)
           (ignore-errors (diff-minimap--collect-diff-data)))))

(defun diff-minimap--activate-buffer ()
  "Show the sidebar and inline hunks for the current enabled buffer."
  (when (and diff-minimap--sidebar-intended
             (bound-and-true-p diff-minimap-mode)
             (eq (current-buffer) (window-buffer (selected-window))))
    (cond
     ((diff-minimap--current-buffer-has-changes-p)
      (if (and (get-buffer-window diff-minimap--buffer-name 0)
               (eq diff-minimap--last-buffer (current-buffer)))
          (when (and diff-minimap-inline-preview
                     (not diff-minimap--ediff-control-buffer)
                     (not diff-minimap--inline-suspended))
            (diff-minimap--show-all-inline-hunks))
        (diff-minimap--open-sidebar)))
     ((eq diff-minimap--last-buffer (current-buffer))
      (diff-minimap--close-sidebar)))))

(defun diff-minimap--clear-sidebar-display ()
  "Erase the minimap buffer contents."
  (when-let* ((mm-buf (get-buffer diff-minimap--buffer-name)))
    (with-current-buffer mm-buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (diff-minimap--clear-overlays)))))

(defun diff-minimap--close-sidebar ()
  "Delete the minimap side window and clear its display."
  (when-let* ((win (get-buffer-window diff-minimap--buffer-name 0)))
    (delete-window win))
  (diff-minimap--fringe-clear)
  (diff-minimap--clear-sidebar-display)
  (setq diff-minimap--last-buffer nil))

(defun diff-minimap--open-sidebar ()
  "Create, configure, and render the minimap side window."
  (let* ((mm-buf (get-buffer-create diff-minimap--buffer-name))
         (win (or (get-buffer-window mm-buf 0)
                  (display-buffer-in-side-window
                   mm-buf
                   `((side . ,diff-minimap-side)
                     (window-width . ,diff-minimap-width)
                     (no-delete-other-windows . t)
                     (no-other-window . t)
                     (preserve-size . (t . nil)))))))
    (when win
      (set-window-parameter win 'no-delete-other-windows t)
      (set-window-parameter win 'no-other-window t))
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
        (define-key map [down-mouse-1] #'diff-minimap--drag-handler)
        (define-key map [mouse-1] #'diff-minimap--click-handler)
        (define-key map [mouse-3] #'diff-minimap--click-show-hunk)
        (define-key map [wheel-up] #'diff-minimap-mouse-wheel-up)
        (define-key map [wheel-down] #'diff-minimap-mouse-wheel-down)
        (define-key map [mouse-4] #'diff-minimap-mouse-wheel-up)
        (define-key map [mouse-5] #'diff-minimap-mouse-wheel-down)
        (use-local-map map))
      (setq-local mode-line-format nil)
      (setq-local header-line-format nil))
    (setq diff-minimap--last-buffer (current-buffer))
    (diff-minimap--render win)
    (when win
      (let ((buf (current-buffer)))
        (run-with-timer
         0.2 nil
         (lambda ()
           (when (and (buffer-live-p buf)
                      (window-live-p win)
                      (get-buffer-window diff-minimap--buffer-name 0)
                      (eq buf diff-minimap--last-buffer))
             (with-current-buffer buf
               (diff-minimap--render win)))))))
    (when (and diff-minimap-inline-preview
               (not diff-minimap--ediff-control-buffer))
      (let ((buf (current-buffer)))
        (run-with-timer
         0 nil
         (lambda ()
           (when (and (buffer-live-p buf)
                      (with-current-buffer buf
                        (bound-and-true-p diff-minimap-mode)))
             (with-current-buffer buf
               (diff-minimap--show-all-inline-hunks)))))))
    win))

;;;###autoload
(defun diff-minimap-toggle ()
  "Toggle the diff minimap for the current buffer.
The mode is buffer-local: enabling it affects only the file where it
was invoked, and other files with their own minimap stay untouched.
The sidebar is only shown for buffers with local changes; in a
buffer without changes, opening it is refused."
  (interactive)
  (cond
   ((bound-and-true-p diff-minimap-mode)
    (diff-minimap-mode -1))
   ((not (diff-minimap--current-buffer-has-changes-p))
    (user-error "No local changes in this file"))
   (t
    (diff-minimap-mode 1))))

;;;###autoload
(defun diff-minimap-ediff-setup ()
  "Open the diff minimap during an Ediff session.
The mode stays buffer-local: the dual-column minimap is only shown
when at least one of the Ediff file buffers already enables it."
  (interactive)
  (let ((session-buffers
         (delq nil
               (list (and (boundp 'ediff-buffer-A)
                          (buffer-live-p ediff-buffer-A)
                          ediff-buffer-A)
                     (and (boundp 'ediff-buffer-B)
                          (buffer-live-p ediff-buffer-B)
                          ediff-buffer-B)
                     (and (boundp 'ediff-buffer-C)
                          (buffer-live-p ediff-buffer-C)
                          ediff-buffer-C)))))
    (when (cl-some (lambda (buf)
                     (buffer-local-value 'diff-minimap-mode buf))
                   session-buffers)
      (setq diff-minimap--ediff-control-buffer (current-buffer))
      ;; Inline hunks would mask Ediff's own highlights.  Hide them for the
      ;; session, but keep `diff-minimap--inline-active' so they come back
      ;; when the Ediff windows are left.
      (diff-minimap--suspend-ediff-inline-hunks)
      (unless (get-buffer-window diff-minimap--buffer-name)
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
                      (when (bound-and-true-p diff-minimap-mode)
                        (setq diff-minimap--sidebar-intended t)
                        (diff-minimap--open-sidebar)))))))))))))

(defun diff-minimap-ediff-teardown ()
  "Hide the minimap when Ediff quits.
The file buffers keep their buffer-local `diff-minimap-mode' state;
the sidebar is re-opened by the next command when an enabled file is
selected again."
  (when diff-minimap--ediff-control-buffer
    (setq diff-minimap--ediff-control-buffer nil
          diff-minimap--ediff-visible nil)
    (when (get-buffer-window diff-minimap--buffer-name 0)
      (diff-minimap--close-sidebar))))

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
             (eq (current-buffer) diff-minimap--last-buffer)
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
  (diff-minimap--ensure-mode)
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
          (when (and (bound-and-true-p diff-minimap-mode)
                     diff-minimap-inline-preview
                     (not (diff-minimap--hunk-overlay-at-line (nth 1 next))))
            (ignore-errors
              (diff-minimap--show-hunk-overlay next (nth 1 next))))
          (recenter)
          (diff-minimap--pulse-range start end))
      (user-error "No next hunk"))))

;;;###autoload
(defun diff-minimap-previous-hunk ()
  "Move point to the previous diff hunk.
Uses the configured `diff-minimap-diff-backend' to find hunks."
  (interactive)
  (diff-minimap--ensure-mode)
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
          (when (and (bound-and-true-p diff-minimap-mode)
                     diff-minimap-inline-preview
                     (not (diff-minimap--hunk-overlay-at-line (nth 1 prev))))
            (ignore-errors
              (diff-minimap--show-hunk-overlay prev (nth 1 prev))))
          (recenter)
          (diff-minimap--pulse-range start end))
      (user-error "No previous hunk"))))


;;; VC diff navigation

(defvar diff-minimap--vc-diff-context nil
  "Cons (BUFFER . LINE) saved before `vc-diff' for hunk navigation.")

(defun diff-minimap--before-vc-diff (&rest _)
  "Save current buffer and line before `vc-diff'."
  (setq diff-minimap--vc-diff-context
        (and (bound-and-true-p diff-minimap-mode)
             (cons (current-buffer) (line-number-at-pos)))))

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

(defun diff-minimap--file-buffer-filter (binding)
  "Return BINDING in file buffers, nil elsewhere.
Used for inline-diff commands so the minibuffer and buffers without a
file keep their normal bindings."
  (unless (or (minibufferp)
              (not (buffer-file-name)))
    binding))

(defvar diff-minimap-mode-map nil
  "Keymap for `diff-minimap-mode'.")

(setq diff-minimap-mode-map
      (let ((map (make-sparse-keymap)))
        (define-key map (kbd "C-c e")
          '(menu-item "" diff-minimap-show-hunk :filter diff-minimap--file-buffer-filter))
        (define-key map (kbd "C-c E")
          '(menu-item "" diff-minimap-show-all-hunks :filter diff-minimap--file-buffer-filter))
        (define-key map (kbd "C-c r")
          '(menu-item "" diff-minimap-revert-hunk :filter diff-minimap--file-buffer-filter))
        (define-key map (kbd "M-n")
          '(menu-item "" diff-minimap-next-hunk :filter diff-minimap--file-buffer-filter))
        (define-key map (kbd "M-p")
          '(menu-item "" diff-minimap-previous-hunk :filter diff-minimap--file-buffer-filter))
        (define-key map (kbd "M-<f5>")
          '(menu-item "" diff-minimap-next-hunk :filter diff-minimap--file-buffer-filter))
        (define-key map (kbd "M-S-<f5>")
          '(menu-item "" diff-minimap-previous-hunk :filter diff-minimap--file-buffer-filter))
        (define-key map (kbd "C-x v ]")
          '(menu-item "" diff-minimap-next-hunk :filter diff-minimap--file-buffer-filter))
        (define-key map (kbd "C-x v [")
          '(menu-item "" diff-minimap-previous-hunk :filter diff-minimap--file-buffer-filter))
        map))

(defun diff-minimap--any-enabled-buffer-p (&optional excluding)
  "Return non-nil when a live buffer other than EXCLUDING enables the mode."
  (cl-some (lambda (buf)
             (and (buffer-live-p buf)
                  (not (eq buf excluding))
                  (buffer-local-value 'diff-minimap-mode buf)))
           (buffer-list)))

(defun diff-minimap--install-global-integration ()
  "Install the global hooks and advice shared by enabled buffers."
  (unless diff-minimap--global-hooks-installed
    (add-hook 'post-command-hook #'diff-minimap--post-command)
    (add-hook 'ediff-startup-hook #'diff-minimap-ediff-setup)
    (add-hook 'ediff-quit-hook #'diff-minimap-ediff-teardown)
    (advice-add 'vc-diff :before #'diff-minimap--before-vc-diff)
    (advice-add 'vc-diff :after #'diff-minimap--after-vc-diff)
    (if (fboundp 'ediff-setup)
        (diff-minimap--ensure-ediff-advice)
      (with-eval-after-load 'ediff
        (diff-minimap--ensure-ediff-advice)))
    (setq diff-minimap--global-hooks-installed t)))

(defun diff-minimap--remove-global-integration ()
  "Remove the global hooks and advice when no buffer enables the mode."
  (when diff-minimap--global-hooks-installed
    (remove-hook 'post-command-hook #'diff-minimap--post-command)
    (remove-hook 'ediff-startup-hook #'diff-minimap-ediff-setup)
    (remove-hook 'ediff-quit-hook #'diff-minimap-ediff-teardown)
    (advice-remove 'vc-diff #'diff-minimap--before-vc-diff)
    (advice-remove 'vc-diff #'diff-minimap--after-vc-diff)
    (diff-minimap--remove-ediff-advice)
    (setq diff-minimap--global-hooks-installed nil
          diff-minimap--ediff-control-buffer nil
          diff-minimap--ediff-visible nil)))

(defun diff-minimap--maybe-remove-global-integration (&optional excluding)
  "Remove shared integration when no buffer except EXCLUDING enables the mode."
  (unless (diff-minimap--any-enabled-buffer-p excluding)
    (when (get-buffer-window diff-minimap--buffer-name 0)
      (diff-minimap--close-sidebar))
    (diff-minimap--remove-global-integration)))

(defun diff-minimap--buffer-killed ()
  "Clean up timers and the sidebar when an enabled buffer is killed."
  (when (timerp diff-minimap--live-diff-timer)
    (cancel-timer diff-minimap--live-diff-timer)
    (setq diff-minimap--live-diff-timer nil))
  (when (eq diff-minimap--last-buffer (current-buffer))
    (diff-minimap--close-sidebar))
  (diff-minimap--maybe-remove-global-integration (current-buffer)))

;;;###autoload
(define-minor-mode diff-minimap-mode
  "Buffer-local minor mode keeping the diff minimap in sync.
When enabled, the minimap follows this buffer and updates on scroll,
edit, save, and hunk navigation.  The sidebar is only shown for
buffers with local changes.  The mode is buffer-local: other buffers
are unaffected and must enable it themselves.  When
`diff-minimap-inline-preview' is non-nil, opening the minimap and hunk
navigation show editable inline diffs; `C-c r' reverts the hunk at
point to its HEAD text without saving.
\\{diff-minimap-mode-map}"
  :lighter " DMap"
  :keymap diff-minimap-mode-map
  (if diff-minimap-mode
      (progn
        (setq diff-minimap--sidebar-intended t)
        (add-hook 'after-change-functions #'diff-minimap--after-change nil t)
        (add-hook 'after-save-hook #'diff-minimap--after-save nil t)
        (add-hook 'after-save-hook #'diff-minimap--refresh-inline-hunk nil t)
        (add-hook 'isearch-update-post-hook #'diff-minimap--search-update nil t)
        (add-hook 'isearch-mode-end-hook #'diff-minimap--search-clear nil t)
        (add-hook 'kill-buffer-hook #'diff-minimap--buffer-killed nil t)
        (diff-minimap--install-global-integration)
        (diff-minimap--activate-buffer))
    (remove-hook 'after-change-functions #'diff-minimap--after-change t)
    (remove-hook 'after-save-hook #'diff-minimap--after-save t)
    (remove-hook 'after-save-hook #'diff-minimap--refresh-inline-hunk t)
    (remove-hook 'isearch-update-post-hook #'diff-minimap--search-update t)
    (remove-hook 'isearch-mode-end-hook #'diff-minimap--search-clear t)
    (remove-hook 'kill-buffer-hook #'diff-minimap--buffer-killed t)
    (when (timerp diff-minimap--live-diff-timer)
      (cancel-timer diff-minimap--live-diff-timer)
      (setq diff-minimap--live-diff-timer nil))
    (diff-minimap--remove-hunk-overlays)
    (diff-minimap--fringe-clear)
    (setq diff-minimap--sidebar-intended nil
          diff-minimap--inline-active nil
          diff-minimap--inline-suspended nil)
    (when (and (get-buffer-window diff-minimap--buffer-name 0)
               (or (eq diff-minimap--last-buffer (current-buffer))
                   (eq (current-buffer) (window-buffer (selected-window)))))
      (diff-minimap--close-sidebar))
    (diff-minimap--maybe-remove-global-integration)))

;;
;; Do not bind `C-x v m' or `C-x v M' here: they are stock VC keys
;; (`vc-merge' and the `vc-diff-mergebase'/`vc-log-mergebase' prefix).
;; Toggle the minimap from `M-x diff-minimap-toggle' or bind it yourself.
;; Hunk navigation (`C-x v ]'/`C-x v [') lives in `diff-minimap-mode-map'
;; so it only applies in buffers where the mode is enabled.

(defvar diff-minimap-hunk-repeat-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "]") #'diff-minimap-next-hunk)
    (define-key map (kbd "[") #'diff-minimap-previous-hunk)
    map)
  "Repeat map for `diff-minimap-next-hunk' and `diff-minimap-previous-hunk'.
When `repeat-mode' is enabled, after `C-x v ]' or `C-x v [', pressing
`]' or `[' again repeats the hunk navigation without the prefix." )

(dolist (cmd '(diff-minimap-next-hunk diff-minimap-previous-hunk))
  (put cmd 'repeat-map 'diff-minimap-hunk-repeat-map))


;;; Ediff integration

(defvar diff-minimap--ediff-advised nil
  "Whether `ediff-setup' has been advised to close the minimap.")

(defun diff-minimap--ediff-session-buffers ()
  "Return the live buffers that belong to the current Ediff session."
  (when (and diff-minimap--ediff-control-buffer
             (buffer-live-p diff-minimap--ediff-control-buffer))
    (with-current-buffer diff-minimap--ediff-control-buffer
      (delq nil
            (list (and (bound-and-true-p ediff-buffer-A)
                       (buffer-live-p ediff-buffer-A)
                       ediff-buffer-A)
                  (and (bound-and-true-p ediff-buffer-B)
                       (buffer-live-p ediff-buffer-B)
                       ediff-buffer-B)
                  (and (bound-and-true-p ediff-buffer-C)
                       (buffer-live-p ediff-buffer-C)
                       ediff-buffer-C))))))

(defun diff-minimap--ediff-session-visible-p ()
  "Return non-nil when the current Ediff session is visible.
Only windows in the selected frame and tab are considered, so
leaving the Ediff tab with `tab-bar-history-back' counts as
leaving the session even though its control buffer is still live."
  (and diff-minimap--ediff-control-buffer
       (buffer-live-p diff-minimap--ediff-control-buffer)
       (get-buffer-window diff-minimap--ediff-control-buffer)))

(defun diff-minimap--suspend-ediff-inline-hunks ()
  "Hide inline hunks in the current Ediff session's buffers.
The buffers keep `diff-minimap--inline-active' and record the
suspension in `diff-minimap--inline-suspended', so
`diff-minimap--restore-suspended-inline-hunks' can bring the hunks
back after the Ediff windows are left."
  (dolist (buf (diff-minimap--ediff-session-buffers))
    (with-current-buffer buf
      (when (and diff-minimap--inline-active
                 (not diff-minimap--inline-suspended)
                 (cl-some (lambda (ov) (overlay-get ov 'diff-minimap-hunk))
                          (overlays-in (point-min) (point-max))))
        (diff-minimap--remove-hunk-overlays)
        (setq diff-minimap--inline-suspended t)))))

(defun diff-minimap--restore-suspended-inline-hunks ()
  "Restore inline hunks hidden for Ediff in the current buffer.
Does nothing while the Ediff windows are visible."
  (when diff-minimap--inline-suspended
    (cond
     ((or (not diff-minimap--inline-active)
          (not (bound-and-true-p diff-minimap-mode)))
      (setq diff-minimap--inline-suspended nil))
     ((not (diff-minimap--ediff-session-visible-p))
      (setq diff-minimap--inline-suspended nil)
      ;; Inline hunks are git-only; ignore the Ediff backend here so the
      ;; hunk line numbers match the git patch even while the Ediff
      ;; control buffer is still live.
      (let ((diff-minimap-diff-backend 'vc))
        (diff-minimap--show-all-inline-hunks))))))

(defun diff-minimap--before-ediff-setup (&rest _)
  "Close the minimap before ediff creates its window layout.
Side windows cannot be split by ediff, so the minimap must be
closed first.  It will be re-opened by `ediff-startup-hook' via
`diff-minimap-ediff-setup'.  Only the sidebar is closed here;
inline hunks are suspended by the startup hook and restored when
the Ediff windows are left."
  (when (get-buffer-window diff-minimap--buffer-name 0)
    (diff-minimap--close-sidebar)))

(defun diff-minimap--ensure-ediff-advice ()
  "Install `:before' advice on `ediff-setup' if not already done."
  (when (diff-minimap--any-enabled-buffer-p)
    (unless diff-minimap--ediff-advised
      (advice-add 'ediff-setup :before #'diff-minimap--before-ediff-setup)
      (setq diff-minimap--ediff-advised t))))

(defun diff-minimap--remove-ediff-advice ()
  "Remove the `:before' advice on `ediff-setup'."
  (when diff-minimap--ediff-advised
    (advice-remove 'ediff-setup #'diff-minimap--before-ediff-setup)
    (setq diff-minimap--ediff-advised nil)))

(provide 'diff-minimap)
;;; diff-minimap.el ends here
