;;; amble-input.el --- Draft at the end of the conversation -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "31.1"))
;;; Code:
(require 'amble-core)
(declare-function amble "amble" (&optional prompt))
(declare-function amble-session-mode "amble" ())
(defvar amble--busy)
(defvar amble--last-error)
(defvar amble--history nil)

(defvar-local amble-input--prompt nil)
(defvar-local amble-input--start nil)
(defvar-local amble-input--notice nil)
(defvar-local amble-input--history-index nil)
(defvar-local amble-input--saved-draft nil)
(defvar-local amble-input--internal nil)
(defvar-local amble-input--revision 0)

;; Mode changes on reload must not lose the boundary or treat a draft as history.
(dolist (symbol '(amble-input--prompt amble-input--start amble-input--revision))
  (put symbol 'permanent-local t))

(defun amble-input--ready-p ()
  "Whether the draft boundaries are valid in this buffer."
  (and (markerp amble-input--prompt) (markerp amble-input--start)
       (eq (marker-buffer amble-input--prompt) (current-buffer))
       (eq (marker-buffer amble-input--start) (current-buffer))
       (<= (point-min) amble-input--prompt amble-input--start (point-max))))

(defun amble-input--protect (begin _end)
  "Reject edits before the draft at BEGIN, including undo into the transcript."
  (when (and (not amble-input--internal) (amble-input--ready-p)
             (< begin amble-input--start))
    (user-error "Conversation history is read-only; type after You at the end")))

(defun amble-input--edited (&rest _)
  "Track draft edits independently of new assistant output."
  (unless amble-input--internal
    (cl-incf amble-input--revision)
    (setq amble-input--notice nil)
    (force-mode-line-update)))

(defun amble-input-setup ()
  "Ensure this conversation ends with a writable draft, preserving its contents."
  (let ((inhibit-read-only t) (amble-input--internal t) (buffer-undo-list t)
        (modified (buffer-modified-p)))
    (unless (amble-input--ready-p)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (let ((start (point)))
        (insert (propertize "You\n" 'face 'font-lock-keyword-face 'read-only t
                            'front-sticky '(read-only) 'rear-nonsticky t))
        (setq amble-input--prompt (copy-marker start t)
              amble-input--start (copy-marker (point) nil))))
    (add-text-properties (point-min) amble-input--start
                         '(read-only t rear-nonsticky t))
    (set-buffer-modified-p modified))
  (when (eq buffer-undo-list t) (setq buffer-undo-list nil))
  (add-hook 'before-change-functions #'amble-input--protect nil t)
  (add-hook 'after-change-functions #'amble-input--edited nil t)
  (setq-local buffer-read-only nil))

(defun amble-input-buffer ()
  "Return the single conversation buffer, which also holds the unsent draft."
  (let ((buffer (get-buffer-create "*amble*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'amble-session-mode) (amble-session-mode))
      (amble-input-setup))
    buffer))

(defun amble-input--with-history (function)
  "Call FUNCTION on history only; preserve draft, point and draft undo records."
  (if (not (amble-input--ready-p))
      (funcall function)
    (let ((old-start (marker-position amble-input--start))
          (modified (buffer-modified-p)))
      (unwind-protect
          (let ((inhibit-read-only t) (amble-input--internal t) (buffer-undo-list t))
            (save-excursion
              (save-restriction
                (narrow-to-region (point-min) amble-input--prompt)
                (prog1 (funcall function)
                  (add-text-properties (point-min) (point-max)
                                       '(read-only t rear-nonsticky t))))))
        ;; Only the prefix moves. Keep ordinary draft undo positions aligned
        ;; when asynchronous replies are inserted before the unfinished text.
        (let ((delta (- (marker-position amble-input--start) old-start)))
          (when (and (/= delta 0) (listp buffer-undo-list))
            (let ((tail buffer-undo-list) (deltas (list (cons old-start (- delta)))))
              (while (consp tail)
                (setcar tail (undo-adjust-elt (car tail) deltas))
                (setq tail (cdr tail))))))
        (set-buffer-modified-p modified)))))

(defun amble-input-focus ()
  "Move to the draft at the end of the current conversation."
  (interactive)
  (with-current-buffer (amble-input-buffer) (goto-char (point-max))))

(defun amble-input--draft ()
  "Return only the current unsent text."
  (buffer-substring-no-properties amble-input--start (point-max)))

(defun amble-input-send ()
  "Send only the draft following the last You heading."
  (interactive)
  (with-current-buffer (amble-input-buffer)
    (let ((buffer (current-buffer)) (text (amble-input--draft))
          (revision amble-input--revision) accepted)
      (cond
       ((bound-and-true-p amble--busy)
        (setq amble-input--notice "Still working; C-c C-k cancels"))
       ((string-empty-p (string-trim text))
        (setq amble-input--notice "Write a message after You"))
       (t
        ;; Remove the submitted draft before logging You/Agent entries above
        ;; it. Restore it on a failed start, without deleting newer user input.
        (let ((amble-input--internal t) (buffer-undo-list t))
          (delete-region amble-input--start (point-max)))
        (condition-case err
            (progn (amble text) (setq accepted (not amble--last-error)))
          (error (setq amble-input--notice (error-message-string err))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (if accepted
                (progn
                  (add-to-history 'amble--history text)
                  (when (= revision amble-input--revision)
                    (setq buffer-undo-list nil)
                    (set-buffer-modified-p nil))
                  (setq amble-input--history-index nil amble-input--saved-draft nil))
              (let ((amble-input--internal t) (buffer-undo-list t))
                (save-excursion
                  (goto-char amble-input--start)
                  (insert text)
                  (unless (= revision amble-input--revision) (insert "\n"))))
              (setq amble-input--notice (or amble-input--notice "Request failed; draft kept")))))))
      (force-mode-line-update))))

(defun amble-input--replace-draft (text)
  "Replace only the current draft with TEXT, preserving conversation history."
  (undo-boundary)
  (delete-region amble-input--start (point-max))
  (goto-char (point-max))
  (insert text)
  (undo-boundary))

(defun amble-input-previous ()
  "Recall an earlier sent message, remembering the unfinished draft."
  (interactive)
  (with-current-buffer (amble-input-buffer)
    (when amble--history
      (unless amble-input--history-index
        (setq amble-input--saved-draft (amble-input--draft)))
      (setq amble-input--history-index
            (min (1- (length amble--history))
                 (if amble-input--history-index (1+ amble-input--history-index) 0)))
      (amble-input--replace-draft (nth amble-input--history-index amble--history)))))

(defun amble-input-next ()
  "Recall a later message, or restore the draft from before history browsing."
  (interactive)
  (with-current-buffer (amble-input-buffer)
    (when amble-input--history-index
      (if (> amble-input--history-index 0)
          (progn
            (cl-decf amble-input--history-index)
            (amble-input--replace-draft (nth amble-input--history-index amble--history)))
        (amble-input--replace-draft (or amble-input--saved-draft ""))
        (setq amble-input--history-index nil amble-input--saved-draft nil)))))

(defun amble-input-migrate ()
  "Move a previous separate input buffer's draft into the conversation once."
  (when-let* ((old (get-buffer "*amble-input*")))
    (let ((text (with-current-buffer old (buffer-substring-no-properties (point-min) (point-max)))))
      (with-current-buffer (amble-input-buffer)
        (unless (string-empty-p text)
          (goto-char (point-max))
          (unless (= amble-input--start (point-max)) (insert "\n"))
          (insert text)))
      (with-current-buffer old
        (let ((inhibit-read-only t)) (erase-buffer) (set-buffer-modified-p nil)))
      (dolist (window (get-buffer-window-list old nil t))
        (set-window-parameter window 'amble-obsolete-input t))
      (kill-buffer old))))

(provide 'amble-input)
;;; amble-input.el ends here
