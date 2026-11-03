;;; diff-minimap-redisplay-test.el --- Interactive display tests -*- lexical-binding: t; -*-

;; Run in a real terminal or GUI frame, for example:
;;   emacs -Q -nw -L . -L tests -l diff-minimap-redisplay-test \
;;     --eval '(kill-emacs (if (zerop (ert-stats-completed-unexpected
;;                                      (ert-run-tests-batch))) 0 1))'

(require 'ert)
(require 'diff-minimap)

(defun diff-minimap-test--line (number)
  "Move point to source line NUMBER."
  (goto-char (point-min))
  (forward-line (1- number)))

(defun diff-minimap-test--assert-added-visible (window line)
  "Assert that LINE and its first two characters are visible in WINDOW."
  (should (= (line-number-at-pos) line))
  (should (= (current-column) 0))
  (should (pos-visible-in-window-p (point) window t))
  (should (pos-visible-in-window-p (1+ (point)) window t)))

(defun diff-minimap-test--overview (buffer rows)
  "Return the source mappings and diff-colour overlays in BUFFER for ROWS."
  (with-current-buffer buffer
    (let (lines colours)
      (dotimes (row rows)
        (push (get-text-property (diff-minimap--row->pos row) 'source-line) lines))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (and (overlay-get ov 'diff-minimap-overlay)
                   (memq (overlay-get ov 'priority) '(3 4)))
          (push (list (overlay-start ov) (overlay-end ov)
                      (overlay-get ov 'priority) (overlay-get ov 'face))
                colours)))
      (list (nreverse lines)
            (sort colours (lambda (a b) (string< (prin1-to-string a)
                                                  (prin1-to-string b))))))))

(defun diff-minimap-test--assert-overview-visible (window rows)
  "Assert that every one of ROWS minimap rows is visible in WINDOW."
  (with-current-buffer (window-buffer window)
    (should (= (window-start window) (point-min)))
    (should (zerop (window-vscroll window t)))
    (let ((height (diff-minimap--minimap-row-height window))
          (last (window-line-height (1- rows) window)))
      (should last)
      (should (zerop (nth 3 last)))
      (dotimes (row rows)
        (let ((line (window-line-height row window)))
          (should line)
          (should (= height (car line))))))))

(ert-deftest diff-minimap-redisplay-large-deletion-jump ()
  "Hunk jumps stay on the added line after multiple real redisplays."
  (skip-unless (not noninteractive))
  (let* ((diff-minimap--buffer-name " *diff-minimap-ui-test-sidebar*")
         (source (generate-new-buffer " *diff-minimap-ui-test-source*"))
         (mm (get-buffer-create diff-minimap--buffer-name))
         (source-window (selected-window))
         (original-buffer (window-buffer source-window))
         (original-last diff-minimap--last-buffer)
         (data '((changed 20 20) (changed 120 122) (changed 180 180)))
         mm-window)
    (unwind-protect
        (progn
          (with-current-buffer source
            (dotimes (n 220) (insert (format "source line %d\n" (1+ n))))
            ;; The minor-mode key filter deliberately applies only to files.
            (setq-local buffer-file-name
                        (expand-file-name "diff-minimap-ui-fixture.txt" temporary-file-directory))
            (setq-local diff-minimap-mode t)
            (setq-local diff-minimap--inline-active t)
            (setq-local diff-minimap--sidebar-intended t)
            (add-hook 'post-command-hook #'diff-minimap--post-command nil t)
            (diff-minimap-test--line 120)
            (let* ((start (point))
                   (end (progn (forward-line 3) (point)))
                   (hunk (make-overlay start end)))
              (overlay-put hunk 'diff-minimap-hunk t)
              (overlay-put hunk 'before-string
                           (apply #'concat (make-list 100 "-old text\n")))
              (should (diff-minimap--anchor-hunk-deletion hunk))))
          (set-window-buffer source-window source)
          (setq mm-window (split-window-right))
          (set-window-buffer mm-window mm)
          (with-current-buffer mm
            (setq-local truncate-lines t)
            (setq-local line-spacing 0)
            (setq-local mode-line-format nil)
            (setq-local header-line-format nil)
            (face-remap-set-base 'default :height diff-minimap-font-scale))
          (select-window source-window)
          (setq diff-minimap--last-buffer source)
          (with-current-buffer source
            (cl-letf (((symbol-function 'diff-minimap--backend-available-p)
                       (lambda () t))
                      ((symbol-function 'diff-minimap--collect-diff-data)
                       (lambda ()
                         (setq diff-minimap--deletion-markers '((120 . 100)))
                         data))
                      ((symbol-function 'diff-minimap--fringe-update)
                       (lambda (_data) nil)))
              (diff-minimap--render mm-window)
              (dolist (collapsed '(nil t))
                (when collapsed (diff-minimap-toggle-collapse 0))
                ;; Settle the sidebar after opening or deliberately collapsing.
                (redisplay t)
                (diff-minimap--post-command)
                (redisplay t)
                (let ((rows diff-minimap--last-nrows)
                      (overview (diff-minimap-test--overview mm diff-minimap--last-nrows))
                      (initial-geometry diff-minimap--last-geometry))
                  (diff-minimap-test--assert-overview-visible mm-window rows)
                  (diff-minimap-test--line 20)
                  (recenter)
                  (redisplay t)
                  (execute-kbd-macro (kbd "M-n"))
                  (dotimes (_ 3) (redisplay t))
                  (diff-minimap-test--assert-added-visible source-window 120)
                  (unless (= rows diff-minimap--last-nrows)
                    (message "After next: collapsed=%S initial=%S current=%S"
                             collapsed initial-geometry diff-minimap--last-geometry))
                  (should (= rows diff-minimap--last-nrows))
                  (should (equal overview (diff-minimap-test--overview mm rows)))
                  (let* ((hunk (diff-minimap--hunk-overlay-at-line 120))
                         (deletion (overlay-get hunk 'diff-minimap-deletion-overlay)))
                    (should (overlay-buffer deletion))
                    (should-not (invisible-p (overlay-start deletion)))
                    (should (= 100 (cl-count ?\n
                                             (diff-minimap--hunk-removed-text hunk)))))
                  (diff-minimap-test--line 180)
                  (recenter)
                  (redisplay t)
                  (execute-kbd-macro (kbd "M-p"))
                  (dotimes (_ 3) (redisplay t))
                  (diff-minimap-test--assert-added-visible source-window 120)
                  (unless (= rows diff-minimap--last-nrows)
                    (message "After previous: collapsed=%S initial=%S current=%S"
                             collapsed initial-geometry diff-minimap--last-geometry))
                  (should (= rows diff-minimap--last-nrows))
                  (should (equal overview (diff-minimap-test--overview mm rows)))
                  ;; Clicking a red row also lands on the real added text.
                  (let* ((deletions diff-minimap--last-display-deletions)
                         (total (diff-minimap--display-line-total
                                 diff-minimap--last-visible-ranges deletions))
                         (scale (/ (float total) rows))
                         (block (car (diff-minimap--deletion-block-ranges
                                      deletions scale rows)))
                         (pos (with-current-buffer mm
                                (diff-minimap--row->pos (car block))))
                         (event (list 'mouse-1 (list mm-window pos '(0 . 0) 0))))
                    (should (diff-minimap--scroll-source-to-event event))
                    (dotimes (_ 3) (redisplay t))
                    (diff-minimap-test--assert-added-visible source-window 120))
                  ;; Repeated attempts to move above the first line must not
                  ;; rescale or scroll the overview.
                  (goto-char (point-min))
                  (recenter 0)
                  (redisplay t)
                  (dotimes (_ 2)
                    (condition-case nil
                        (execute-kbd-macro (kbd "C-p"))
                      (beginning-of-buffer nil))
                    (diff-minimap--post-command)
                    (dotimes (_ 3) (redisplay t))
                    (unless (= rows diff-minimap--last-nrows)
                      (message "After top: collapsed=%S initial=%S current=%S"
                               collapsed initial-geometry diff-minimap--last-geometry))
                    (should (= rows diff-minimap--last-nrows))
                    (should (equal overview (diff-minimap-test--overview mm rows)))
                    (diff-minimap-test--assert-overview-visible mm-window rows))
                  ;; Even if Emacs scrolls the nonselected sidebar, the next
                  ;; viewport update returns it to the full overview.
                  (with-current-buffer mm
                    (let ((pos (diff-minimap--row->pos (min 5 (1- rows)))))
                      (set-window-point mm-window pos)
                      (set-window-start mm-window pos)))
                  (diff-minimap--update-viewport)
                  (dotimes (_ 3) (redisplay t))
                  (should (equal overview (diff-minimap-test--overview mm rows)))
                  (diff-minimap-test--assert-overview-visible mm-window rows)))
              ;; A deliberate sidebar resize must still trigger a rebuild.
              (let ((old-width (window-width mm-window)))
                (window-resize mm-window 1 t)
                (redisplay t)
                (diff-minimap--post-command)
                (redisplay t)
                (should (/= old-width (window-width mm-window)))
                (should (= (window-width mm-window)
                           (nth 2 diff-minimap--last-geometry)))
                (diff-minimap-test--assert-overview-visible
                 mm-window diff-minimap--last-nrows)))))
      (setq diff-minimap--last-buffer original-last)
      (when (window-live-p mm-window) (delete-window mm-window))
      (when (window-live-p source-window)
        (set-window-buffer source-window original-buffer))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (when (buffer-live-p mm) (kill-buffer mm)))))

(ert-deftest diff-minimap-redisplay-first-line-jump ()
  "A first-line deletion is restored after point moves to real text."
  (skip-unless (not noninteractive))
  (let ((source (generate-new-buffer " *diff-minimap-first-line-ui-test*"))
        (window (selected-window))
        (original-buffer (window-buffer)))
    (unwind-protect
        (progn
          (set-window-buffer window source)
          (with-current-buffer source
            (insert "\nadded text\nafter\n")
            (goto-char (point-min))
            (let ((hunk (make-overlay (point-min) (point-max)))
                  (preview (apply #'concat (make-list 100 "-old text\n"))))
              (overlay-put hunk 'diff-minimap-hunk t)
              (overlay-put hunk 'before-string preview)
              (diff-minimap--focus-source-line 1)
              (dotimes (_ 3) (redisplay t))
              (should (= (line-number-at-pos) 1))
              (should (pos-visible-in-window-p (point) window t))
              (should-not (overlay-get hunk 'before-string))
              (execute-kbd-macro (kbd "C-n"))
              (dotimes (_ 3) (redisplay t))
              (should (= (line-number-at-pos) 2))
              (should (pos-visible-in-window-p (point) window t))
              (should (equal preview (overlay-get hunk 'before-string))))))
      (when (window-live-p window) (set-window-buffer window original-buffer))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source)))))

(ert-deftest diff-minimap-redisplay-first-line-refresh ()
  "Refreshing an edited first-line hunk keeps its source line visible."
  (skip-unless (not noninteractive))
  (let* ((source (generate-new-buffer " *diff-minimap-first-line-refresh-ui-test*"))
         (window (selected-window))
         (original-buffer (window-buffer))
         (preview (apply #'concat (make-list 100 "-old text\n")))
         (patch (concat "diff --git a/test b/test\n--- a/test\n+++ b/test\n"
                        "@@ -1,100 +1,2 @@\n" preview "+\n+added text\n"))
         (data '((changed 1 2))))
    (unwind-protect
        (progn
          (set-window-buffer window source)
          (with-current-buffer source
            (insert "\nadded text\nafter\n")
            (setq-local buffer-file-name
                        (expand-file-name "diff-minimap-ui-first-line.txt"
                                          temporary-file-directory))
            (setq-local diff-minimap-mode t)
            (cl-letf (((symbol-function 'diff-minimap--collect-diff-data)
                       (lambda () data))
                      ((symbol-function 'diff-minimap--current-patch)
                       (lambda (_file) patch)))
              (diff-minimap--show-all-inline-hunks)
              (goto-char (point-min))
              (diff-minimap--focus-source-line 1)
              (execute-kbd-macro "X")
              (diff-minimap--refresh-display)
              (dotimes (_ 3) (redisplay t))
              (should (= (line-number-at-pos) 1))
              (should (pos-visible-in-window-p (point) window t))
              (let ((hunk (diff-minimap--hunk-overlay-at-line 1)))
                (should (eq hunk (car diff-minimap--suspended-jump-preview)))
                (should-not (overlay-get hunk 'before-string))
                (execute-kbd-macro (kbd "C-n"))
                (dotimes (_ 3) (redisplay t))
                (should (= (line-number-at-pos) 2))
                (should (pos-visible-in-window-p (point) window t))
                (should (overlay-get hunk 'before-string))))))
      (when (window-live-p window) (set-window-buffer window original-buffer))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source)))))

(provide 'diff-minimap-redisplay-test)
;;; diff-minimap-redisplay-test.el ends here
