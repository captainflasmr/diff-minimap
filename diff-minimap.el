;;; diff-minimap.el --- VSCode-style minimap showing diff regions -*- lexical-binding: t; -*-
;;
;; Author: James Dyer <captainflasmr@gmail.com>
;; Version: 0.1.0
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

(defface diff-minimap-font
  '((t :height 0.4 :inherit default))
  "Face used for the minimap buffer — tiny font for fine-grained display."
  :group 'diff-minimap)

(defvar-local diff-minimap--last-ws nil
  "Last window-start to skip truly redundant re-renders.")

(defvar diff-minimap--buffer-name " *diff-minimap*"
  "Name of the hidden minimap buffer.")

(defun diff-minimap--render ()
  "Render the full-file diff minimap for the current buffer."
  (let ((mm-buf (get-buffer-create diff-minimap--buffer-name)))
    (when (and (bound-and-true-p diff-hl-mode)
               (get-buffer-window mm-buf))
      (let* ((this-buf (current-buffer))
             (total (with-current-buffer this-buf
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
             (row-diff (make-vector nrows nil))
             ws-line we-line cur-row
             (hunk-count 0))
        (with-current-buffer this-buf
          (save-excursion
            (setq ws-line (line-number-at-pos (window-start)))
            (goto-char (window-end nil t))
            (setq we-line (line-number-at-pos)))
          (setq cur-row (max 0 (min (floor (/ (1- (line-number-at-pos)) scale))
                                    (1- nrows))))
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
                             (el (if (eq ty 'removed)
                                     sl
                                   (progn (goto-char en)
                                          (if (bolp) (1- (line-number-at-pos))
                                            (line-number-at-pos))))))
                        (setq hunk-count (1+ hunk-count))
                        (let ((fr (floor (/ (1- sl) scale)))
                              (lr (min (1- nrows) (floor (/ el scale)))))
                          (cl-loop for r from fr to lr
                                   do (aset row-diff r ty)))))))))))
        (let* ((fbg (lambda (f attr d)
                      (let ((v (face-attribute f attr nil t)))
                        (if (or (not v) (eq v 'unspecified) (not (stringp v)))
                            d v))))
               (norm-bg (funcall fbg 'fringe :background "#1a1a1a"))
               (view-bg (funcall fbg 'region :background "#404060"))
               (ins-bg  (funcall fbg 'diff-added :background (funcall fbg 'diff-hl-insert :background "#006600")))
               (chg-bg  (funcall fbg 'diff-changed :background (funcall fbg 'diff-hl-change :background "#666600")))
               (del-bg  (funcall fbg 'diff-removed :background (funcall fbg 'diff-hl-delete :background "#660000")))
               (ins-fg  (funcall fbg 'diff-added :foreground (funcall fbg 'diff-hl-insert :foreground "#00ff00")))
               (chg-fg  (funcall fbg 'diff-changed :foreground (funcall fbg 'diff-hl-change :foreground "#ffff00")))
               (del-fg  (funcall fbg 'diff-removed :foreground (funcall fbg 'diff-hl-delete :foreground "#ff0000")))
               (cur-bg  (funcall fbg 'cursor :background "#00ffff")))
          (with-current-buffer mm-buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (dotimes (i nrows)
                (let* ((sline (1+ (floor (* i scale))))
                       (dtype (aref row-diff i))
                       (invp (and (>= sline ws-line) (<= sline we-line)))
                       (row-bg (cond ((eq dtype 'added) ins-bg)
                                     ((eq dtype 'changed) chg-bg)
                                     ((eq dtype 'removed) del-bg)
                                     (invp view-bg)
                                     (t norm-bg))))
                  (let ((ind-face (cond ((= i cur-row) `(:foreground ,cur-bg :background ,cur-bg))
                                        (dtype (cond ((eq dtype 'added) `(:foreground ,ins-fg :background ,ins-bg))
                                                     ((eq dtype 'changed) `(:foreground ,chg-fg :background ,chg-bg))
                                                     ((eq dtype 'removed) `(:foreground ,del-fg :background ,del-bg))
                                                     (t `(:foreground ,norm-bg :background ,norm-bg))))
                                        (invp `(:foreground ,view-bg :background ,view-bg))
                                        (t `(:foreground ,norm-bg :background ,norm-bg))))
                        (bg-face `(:background ,row-bg :extend t)))
                    (insert
                     (propertize " " 'face ind-face
                                 'source-line sline 'source-buf this-buf)
                     (propertize (make-string (1- diff-minimap-width) ?\s)
                                 'face bg-face
                                 'source-line sline 'source-buf this-buf)
                     (propertize "\n" 'face bg-face))))))))))))

(defun diff-minimap--update ()
  "Re-render the minimap unconditionally."
  (when (and (bound-and-true-p diff-hl-mode)
             (get-buffer-window diff-minimap--buffer-name))
    (diff-minimap--render)))

(defun diff-minimap--schedule ()
  "Post-command-hook: schedule an idle re-render."
  (let ((buf (current-buffer)))
    (run-with-idle-timer
     0.02 nil
     (lambda ()
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (diff-minimap--update)))))))

(defun diff-minimap--after-save ()
  "Force re-render after save."
  (let ((buf (current-buffer)))
    (run-with-idle-timer
     0.1 nil
     (lambda ()
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq diff-minimap--last-ws nil)
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
      (setq diff-minimap--last-ws nil)
      (display-buffer-in-side-window
       mm-buf
       `((side . ,diff-minimap-side)
         (window-width . ,diff-minimap-width)
         (no-delete-other-windows . t)
         (preserve-size . (t . nil))))
      (with-current-buffer mm-buf
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
      (diff-minimap-mode 1))))

;;;###autoload
(define-minor-mode diff-minimap-mode
  "Keep diff minimap in sync on scroll and save."
  :lighter " DMap"
  :global nil
  (if diff-minimap-mode
      (progn
        (setq diff-minimap--last-ws (window-start))
        (add-hook 'after-save-hook #'diff-minimap--after-save nil t)
        (add-hook 'post-command-hook #'diff-minimap--schedule nil t))
    (remove-hook 'after-save-hook #'diff-minimap--after-save t)
    (remove-hook 'post-command-hook #'diff-minimap--schedule t)))

(define-key vc-prefix-map (kbd "m") #'diff-minimap-toggle)

(provide 'diff-minimap)
;;; diff-minimap.el ends here