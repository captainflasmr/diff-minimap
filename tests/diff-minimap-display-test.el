;;; diff-minimap-display-test.el --- Display mapping tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'diff-minimap)
(require 'isearch)

(defconst diff-minimap-test--markers
  '((42 . 1) (113 . 1) (589 . 1) (707 . 100) (736 . 1)))

(defconst diff-minimap-test--collapsed-ranges
  '((8 . 14) (39 . 53) (110 . 116) (586 . 592) (704 . 716) (733 . 739)))

(ert-deftest diff-minimap-geometry-ignores-pixel-jitter ()
  "Navigation-sized pixel changes do not rescale the overview."
  (let ((old '(278 559 6 2)))
    (should-not (diff-minimap--minimap-geometry-changed-p '(279 560 6 2) old 1))
    (should-not (diff-minimap--minimap-geometry-changed-p '(278 558 6 2) old 1))
    (should-not (diff-minimap--minimap-geometry-changed-p '(279 561 6 2) old 2))
    (should (diff-minimap--minimap-geometry-changed-p '(280 562 6 2) old 2))
    (should (diff-minimap--minimap-geometry-changed-p '(277 557 6 2) old 1))
    (should (diff-minimap--minimap-geometry-changed-p '(279 560 6 2) old 0))
    (should (diff-minimap--minimap-geometry-changed-p '(278 559 7 2) old 1))
    (should (diff-minimap--minimap-geometry-changed-p '(278 559 6 3) old 1))
    (should (diff-minimap--minimap-geometry-changed-p old nil 1))
    (should-not (diff-minimap--minimap-geometry-changed-p nil old 1))))

(ert-deftest diff-minimap-geometry-reserves-graphical-row ()
  "A small graphical height change cannot clip the last overview row."
  (let ((window (selected-window))
        (height 560))
    (cl-letf (((symbol-function 'window-body-height)
               (lambda (_window &optional _pixels) height))
              ((symbol-function 'diff-minimap--minimap-row-height)
               (lambda (_window) 2))
              ((symbol-function 'window-width)
               (lambda (_window) 6))
              ((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t)))
      (should (equal (diff-minimap--minimap-geometry window) '(279 560 6 2)))
      (setq height 559)
      (should (<= (* 279 2) height))
      (should (equal (diff-minimap--minimap-geometry window) '(278 559 6 2))))))

(ert-deftest diff-minimap-display-scales-large-deletion ()
  "Deleted lines share the same scale as surviving source lines."
  (dolist (ranges (list '((1 . 942)) diff-minimap-test--collapsed-ranges))
    (let* ((deletions (diff-minimap--display-deletions
                       ranges diff-minimap-test--markers))
           (total (diff-minimap--display-line-total ranges deletions))
           (nrows 300)
           (scale (/ (float total) nrows))
           (block (cl-find 707 (diff-minimap--deletion-block-ranges
                                deletions scale nrows)
                           :key (lambda (item) (nth 2 item))))
           (height (1+ (- (nth 1 block) (car block))))
           (expected (* nrows (/ 100.0 total)))
           (before (diff-minimap--line-to-display 706 ranges deletions))
           (added (diff-minimap--line-to-display 707 ranges deletions)))
      (should (< (abs (- height expected)) 2.0))
      (should (> (car block) 0))
      ;; The red block begins after line 706 and ends just before line 707.
      (should (= (- added before) 101))
      (should (= (diff-minimap--display-to-line (1+ before) ranges deletions) 707))
      (should (= (diff-minimap--display-to-line (1- added) ranges deletions) 707))
      (should (= (diff-minimap--display-to-line added ranges deletions) 707)))))

(ert-deftest diff-minimap-display-deletions-at-boundaries ()
  "Beginning, end, and repeated deletion markers map to their insertion lines."
  (let* ((ranges '((1 . 5)))
         (deletions (diff-minimap--display-deletions
                     ranges '((6 . 2) (3 . 2) (1 . 1) (3 . 1)))))
    (should (equal deletions '((1 1 1) (3 2 3) (3 1 3) (6 2 6))))
    (should (= 11 (diff-minimap--display-line-total ranges deletions)))
    (should (= 2 (diff-minimap--line-to-display 1 ranges deletions)))
    (should (= 7 (diff-minimap--line-to-display 3 ranges deletions)))
    (should (= 9 (diff-minimap--line-to-display 5 ranges deletions)))
    (should (= 1 (diff-minimap--display-to-line 1 ranges deletions)))
    (should (= 3 (diff-minimap--display-to-line 4 ranges deletions)))
    (should (= 3 (diff-minimap--display-to-line 6 ranges deletions)))
    (should (= 6 (diff-minimap--display-to-line 10 ranges deletions)))
    (should (= 6 (diff-minimap--display-to-line 11 ranges deletions)))))

(ert-deftest diff-minimap-display-snaps-hidden-lines ()
  "Collapsed ranges and deletions use the same visible coordinates."
  (let* ((ranges '((1 . 3) (50 . 52)))
         (deletions (diff-minimap--display-deletions ranges '((51 . 2)))))
    (should (equal deletions '((5 2 51))))
    (should (= 8 (diff-minimap--display-line-total ranges deletions)))
    (should (= 4 (diff-minimap--line-to-display 50 ranges deletions)))
    (should (= 7 (diff-minimap--line-to-display 51 ranges deletions)))
    (should (= 51 (diff-minimap--display-to-line 5 ranges deletions)))
    (should (= 51 (diff-minimap--display-to-line 6 ranges deletions)))
    (should (= 52 (diff-minimap--display-to-line 8 ranges deletions)))))

(ert-deftest diff-minimap-collapse-deletion-at-end-of-file ()
  "A pure EOF deletion retains a valid preceding source line."
  (with-temp-buffer
    (insert "one\ntwo\nthree\n")
    (let* ((diff-minimap--collapse-context 0)
           (ranges (diff-minimap--collapse-visible-ranges '((removed 4 4))))
           (deletions (diff-minimap--display-deletions ranges '((4 . 2)))))
      (should (equal ranges '((3 . 3))))
      (should (equal deletions '((2 2 4))))
      (should (equal (diff-minimap--deletion-block-ranges deletions 1.0 3)
                     '((1 2 4))))
      (should (= 3 (diff-minimap--display-to-line 1 ranges deletions)))
      (should (= 4 (diff-minimap--display-to-line 2 ranges deletions))))))

(ert-deftest diff-minimap-render-deletion-targets-source-hunk ()
  "Red rows map to their hunk, and a shared row keeps both colours."
  (let ((source (generate-new-buffer " *diff-minimap-test-source*"))
        (mm (get-buffer-create diff-minimap--buffer-name))
        (original-window (selected-window))
        (original-buffer (window-buffer))
        (data '((added 11 11) (changed 42 46) (added 49 50)
                (changed 113 113) (changed 589 589)
                (changed 707 713) (changed 736 736)))
        mm-window)
    (unwind-protect
        (progn
          (with-current-buffer source
            (dotimes (n 942) (insert (format "source line %d\n" (1+ n))))
            (setq-local diff-minimap--collapsed t)
            (setq-local diff-minimap--collapsed-ranges
                        diff-minimap-test--collapsed-ranges)
            (goto-char (point-min))
            (forward-line 706)
            (let* ((start (point))
                   (end (progn (forward-line 7) (point)))
                   (hunk (make-overlay start end)))
              (overlay-put hunk 'diff-minimap-hunk t)
              (overlay-put hunk 'before-string
                           (apply #'concat (make-list 100 "-old text\n")))))
          (set-window-buffer original-window source)
          (setq mm-window (split-window-right))
          (set-window-buffer mm-window mm)
          (with-current-buffer source
            (cl-letf (((symbol-function 'diff-minimap--backend-available-p)
                       (lambda () t))
                      ((symbol-function 'diff-minimap--collect-diff-data)
                       (lambda ()
                         (setq diff-minimap--deletion-markers
                               diff-minimap-test--markers)
                         data))
                      ((symbol-function 'diff-minimap--fringe-update)
                       (lambda (_data) nil)))
              (diff-minimap--render mm-window)
              (let* ((deletions diff-minimap--last-display-deletions)
                     (total (diff-minimap--display-line-total
                             diff-minimap-test--collapsed-ranges deletions))
                     (scale (/ (float total) diff-minimap--last-nrows))
                     (block (cl-find 707 (diff-minimap--deletion-block-ranges
                                          deletions scale diff-minimap--last-nrows)
                                     :key (lambda (item) (nth 2 item))))
                     (red-row (car block))
                     (added-row (car (diff-minimap--visible-range-rows
                                      (diff-minimap--line-to-display
                                       707 diff-minimap-test--collapsed-ranges deletions)
                                      (diff-minimap--line-to-display
                                       713 diff-minimap-test--collapsed-ranges deletions)
                                      scale diff-minimap--last-nrows))))
                (let* ((red-pos (with-current-buffer mm
                                  (diff-minimap--row->pos red-row)))
                       (event (list 'mouse-1 (list mm-window red-pos '(0 . 0) 0))))
                  (should (equal (diff-minimap--event-source event)
                                 (cons 707 source)))
                  (should (diff-minimap--scroll-source-to-event event))
                  (should (= 707 (line-number-at-pos)))
                  (should (= 0 (current-column)))
                  (should (= (window-start original-window) (point)))
                  (let* ((hunk (diff-minimap--hunk-overlay-at-line 707))
                         (deletion (overlay-get hunk 'diff-minimap-deletion-overlay)))
                    (should (overlay-buffer deletion))
                    (should (= (overlay-start deletion) (1- (point))))
                    (should-not (overlay-get hunk 'before-string))
                    (should (equal (overlay-get deletion 'before-string)
                                   (concat "\n" (string-remove-suffix
                                                 "\n" (diff-minimap--hunk-removed-text
                                                         hunk))))))
                  (diff-minimap--update-viewport)
                  (let ((isearch-mode t)
                        (isearch-string "source line 707")
                        (isearch-regexp nil)
                        (diff-minimap--last-buffer source))
                    (diff-minimap--search-update))
                  (with-current-buffer mm
                    (let ((added-pos (diff-minimap--row->pos added-row)))
                      (should (= 707 (get-text-property red-pos 'source-line)))
                      (should (eq source (get-text-property red-pos 'source-buf)))
                      (should (= (1+ added-row)
                                 (line-number-at-pos (overlay-start
                                                      diff-minimap--cursor-overlay))))
                      (should (cl-some (lambda (ov)
                                         (and (overlay-get ov 'diff-minimap-search)
                                              (= (1+ added-row)
                                                 (line-number-at-pos
                                                  (overlay-start ov)))))
                                       (overlays-in (point-min) (point-max))))
                      (should (cl-some (lambda (ov)
                                         (equal (plist-get (overlay-get ov 'face)
                                                           :background)
                                                diff-minimap--ins-bg))
                                       (overlays-in added-pos
                                                    (diff-minimap--row->pos
                                                     (1+ added-row)))))
                      (when (<= added-row (nth 1 block))
                        (should (cl-some (lambda (ov)
                                           (equal (plist-get (overlay-get ov 'face)
                                                             :background)
                                                  diff-minimap--del-bg))
                                         (overlays-at added-pos))))))
                  ;; Editing the source keeps the separate deletion preview
                  ;; attached to the preceding newline, without fake text.
                  (insert "X")
                  (should (looking-back "X" (line-beginning-position)))
                  (let* ((hunk (diff-minimap--hunk-overlay-at-line 707))
                         (deletion (overlay-get hunk 'diff-minimap-deletion-overlay)))
                    (should (overlay-buffer deletion))
                    (diff-minimap--delete-hunk-overlay hunk)
                    (should-not (overlay-buffer deletion))))))))
      (when (window-live-p mm-window) (delete-window mm-window))
      (when (window-live-p original-window)
        (set-window-buffer original-window original-buffer))
      (when (buffer-live-p source) (kill-buffer source))
      (when (buffer-live-p mm) (kill-buffer mm)))))

(ert-deftest diff-minimap-anchor-deletion-after-collapse ()
  "A zero-context fold retains a visible boundary for deletion previews."
  (with-temp-buffer
    (insert "keep\nunchanged\nadded\n")
    (let ((original (buffer-string))
          (diff-minimap--collapse-context 0)
          (diff-minimap--collapsed t))
      (goto-char (point-min))
      (forward-line 2)
      (let* ((start (point))
             (hunk (make-overlay start (line-end-position))))
        (overlay-put hunk 'diff-minimap-hunk t)
        (overlay-put hunk 'before-string "-old\n")
        (diff-minimap--update-collapse '((changed 3 3)))
        (should (invisible-p (point-min)))
        (should-not (invisible-p (1- start)))
        (let ((deletion (diff-minimap--anchor-hunk-deletion hunk)))
          (should (overlay-buffer deletion))
          (should (equal (overlay-get deletion 'before-string) "\n-old"))
          (should (equal (diff-minimap--hunk-removed-text hunk) "-old\n"))
          (should (equal (buffer-string) original))
          (diff-minimap--delete-hunk-overlay hunk)
          (should-not (overlay-buffer deletion)))))))

(ert-deftest diff-minimap-focus-first-line-with-deletion ()
  "A first-line deletion is hidden only while point remains there."
  (let ((source (generate-new-buffer " *diff-minimap-first-line-test*"))
        (window (selected-window))
        (original-buffer (window-buffer)))
    (unwind-protect
        (progn
          (set-window-buffer window source)
          (with-current-buffer source
            ;; Also cover a blank first added line: point must remain on it.
            (insert "\nadded\n")
            (goto-char (point-min))
            (let ((hunk (make-overlay (point-min) (point-max)))
                  (preview (apply #'concat (make-list 100 "-old\n"))))
              (overlay-put hunk 'diff-minimap-hunk t)
              (overlay-put hunk 'before-string preview)
              (diff-minimap--focus-source-line 1)
              (should (= (point-min) (point)))
              (should-not (overlay-get hunk 'before-string))
              (should (eq hunk (car diff-minimap--suspended-jump-preview)))
              (should (memq #'diff-minimap--maybe-restore-jump-preview post-command-hook))
              (forward-line 1)
              (diff-minimap--maybe-restore-jump-preview)
              (should (equal preview (overlay-get hunk 'before-string)))
              (should-not diff-minimap--suspended-jump-preview)
              (diff-minimap--delete-hunk-overlay hunk))))
      (when (window-live-p window) (set-window-buffer window original-buffer))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest diff-minimap-refresh-keeps-anchored-preview ()
  "Refreshing an inline hunk preserves its virtual deletion and cleans up old overlays."
  (with-temp-buffer
    (insert "context\nnew words\nend\n")
    (setq-local buffer-file-name
                (expand-file-name "diff-minimap-refresh-fixture.txt" temporary-file-directory))
    (setq-local diff-minimap-mode t)
    (let ((patch (concat "diff --git a/test b/test\n--- a/test\n+++ b/test\n"
                         "@@ -2 +2 @@\n-old words\n+new words\n"))
          (data '((changed 2 2))))
      (cl-letf (((symbol-function 'diff-minimap--collect-diff-data)
                 (lambda () data))
                ((symbol-function 'diff-minimap--current-patch)
                 (lambda (_file) patch)))
        (diff-minimap--show-all-inline-hunks)
        (let* ((hunk (diff-minimap--hunk-overlay-at-line 2))
               (old-deletion (overlay-get hunk 'diff-minimap-deletion-overlay)))
          (should (overlay-buffer old-deletion))
          (should (equal (substring-no-properties
                          (diff-minimap--hunk-removed-text hunk))
                         "-old words\n"))
          (diff-minimap--refresh-inline-hunk)
          (should-not (overlay-buffer old-deletion))
          (setq hunk (diff-minimap--hunk-overlay-at-line 2))
          (let ((new-deletion (overlay-get hunk 'diff-minimap-deletion-overlay)))
            (should (overlay-buffer new-deletion))
            (should (equal (substring-no-properties
                            (overlay-get new-deletion 'before-string))
                           "\n-old words"))
            (let ((removed (diff-minimap--hunk-removed-text hunk))
                  (displayed (overlay-get new-deletion 'before-string)))
              (dotimes (index (1- (length removed)))
                (should (equal (get-text-property index 'face removed)
                               (get-text-property (1+ index) 'face displayed)))))
            (diff-minimap--remove-hunk-overlays)
            (should-not (overlay-buffer new-deletion))))))))

(ert-deftest diff-minimap-refresh-keeps-first-line-focused ()
  "Refreshing a first-line hunk keeps its preview out of the focused line."
  (let ((source (generate-new-buffer " *diff-minimap-first-line-refresh-test*"))
        (window (selected-window))
        (original-buffer (window-buffer))
        (patch (concat "diff --git a/test b/test\n--- a/test\n+++ b/test\n"
                       "@@ -1,2 +1 @@\n-old one\n-old two\n+new\n"))
        (data '((changed 1 1))))
    (unwind-protect
        (progn
          (set-window-buffer window source)
          (with-current-buffer source
            (insert "new\nnext\n")
            (setq-local buffer-file-name
                        (expand-file-name "diff-minimap-first-line-fixture.txt"
                                          temporary-file-directory))
            (setq-local diff-minimap-mode t)
            (cl-letf (((symbol-function 'diff-minimap--collect-diff-data)
                       (lambda () data))
                      ((symbol-function 'diff-minimap--current-patch)
                       (lambda (_file) patch)))
              (diff-minimap--show-all-inline-hunks)
              (goto-char (point-min))
              (diff-minimap--focus-source-line 1)
              (insert "X")
              (diff-minimap--refresh-display)
              (let ((hunk (diff-minimap--hunk-overlay-at-line 1)))
                (should (eq hunk (car diff-minimap--suspended-jump-preview)))
                (should-not (overlay-get hunk 'before-string)))
              (diff-minimap--refresh-inline-hunk)
              (let ((hunk (diff-minimap--hunk-overlay-at-line 1)))
                (should (eq hunk (car diff-minimap--suspended-jump-preview)))
                (should-not (overlay-get hunk 'before-string))
                (forward-line 1)
                (diff-minimap--maybe-restore-jump-preview)
                (should (overlay-get hunk 'before-string))))))
      (when (window-live-p window) (set-window-buffer window original-buffer))
      (when (buffer-live-p source)
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source)))))

(provide 'diff-minimap-display-test)
;;; diff-minimap-display-test.el ends here
