;;; amble-input.el --- Editable draft inside the Amble panel -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "31.1"))
;;; Code:
(require 'amble-core)
(declare-function amble "amble" (&optional prompt))
(declare-function amble-cancel "amble" ())
(declare-function amble-new-session "amble" ())
(declare-function amble-hide "amble-frame" ())
(defvar amble--busy)
(defvar amble--last-error)
(defvar amble--history nil)

(defvar-local amble-input--notice nil)
(defvar-local amble-input--history-index nil)
(defvar-local amble-input--saved-draft nil)

(defvar amble-input-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "RET") #'newline)
    (define-key map (kbd "C-c C-c") #'amble-input-send)
    (define-key map (kbd "C-c C-k") #'amble-cancel)
    (define-key map (kbd "C-c C-n") #'amble-new-session)
    (define-key map (kbd "M-p") #'amble-input-previous)
    (define-key map (kbd "M-n") #'amble-input-next)
    (define-key map (kbd "<escape>") #'amble-hide)
    map))

(defun amble-input--edited (&rest _)
  "Clear a stale input notice when the draft changes."
  (setq amble-input--notice nil)
  (force-mode-line-update))

(define-derived-mode amble-input-mode text-mode "Amble Input"
  "Edit a message. RET inserts a newline; C-c C-c sends the draft."
  (setq-local truncate-lines nil word-wrap t
              mode-line-format nil
              header-line-format
              '(:eval (concat " Message · C-c C-c send · RET newline"
                              (cond (amble-input--notice (concat " · " amble-input--notice))
                                    ((bound-and-true-p amble--busy) " · working; draft kept")
                                    (t "")))))
  (buffer-enable-undo)
  (add-hook 'after-change-functions #'amble-input--edited nil t))

(defun amble-input-buffer ()
  "Return the editable draft buffer, preserving any existing contents."
  (let ((buffer (get-buffer-create "*amble-input*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'amble-input-mode) (amble-input-mode)))
    buffer))

(defun amble-input-send ()
  "Send the current draft without opening a minibuffer or discarding edits."
  (interactive)
  (with-current-buffer (amble-input-buffer)
    (let ((draft (current-buffer))
          (text (buffer-substring-no-properties (point-min) (point-max)))
          (tick (buffer-chars-modified-tick)))
      (cond
       ((bound-and-true-p amble--busy)
        (setq amble-input--notice "Still working; C-c C-k cancels"))
       ((string-empty-p (string-trim text))
        (setq amble-input--notice "Write a message first"))
       (t
        (condition-case err
            (progn
              (amble text)
              (when (buffer-live-p draft)
                (with-current-buffer draft
                  (if amble--last-error
                      (setq amble-input--notice "Request failed; draft kept")
                    (add-to-history 'amble--history text)
                    ;; Clear only the exact draft submitted, never newer edits.
                    (when (= tick (buffer-chars-modified-tick))
                      (erase-buffer)
                      (set-buffer-modified-p nil)
                      (setq amble-input--history-index nil amble-input--saved-draft nil))))))
          (error
           (when (buffer-live-p draft)
             (with-current-buffer draft
               (setq amble-input--notice (error-message-string err))))))))
      (force-mode-line-update))))

(defun amble-input--replace-draft (text)
  "Replace the draft with TEXT as an undoable history navigation step."
  (undo-boundary)
  (erase-buffer)
  (insert text)
  (undo-boundary))

(defun amble-input-previous ()
  "Recall an earlier sent message, remembering the unfinished draft."
  (interactive)
  (when amble--history
    (unless amble-input--history-index
      (setq amble-input--saved-draft (buffer-string)))
    (setq amble-input--history-index
          (min (1- (length amble--history))
               (if amble-input--history-index (1+ amble-input--history-index) 0)))
    (amble-input--replace-draft (nth amble-input--history-index amble--history))))

(defun amble-input-next ()
  "Recall a later message, or restore the draft from before history browsing."
  (interactive)
  (when amble-input--history-index
    (if (> amble-input--history-index 0)
        (progn
          (cl-decf amble-input--history-index)
          (amble-input--replace-draft (nth amble-input--history-index amble--history)))
      (amble-input--replace-draft (or amble-input--saved-draft ""))
      (setq amble-input--history-index nil amble-input--saved-draft nil))))

(provide 'amble-input)
;;; amble-input.el ends here
