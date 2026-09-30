;;; amble-input.el --- Draft at the end of the conversation -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "31.1"))
;;; Code:
(require 'amble-core)
(require 'button)
(declare-function amble "amble" (&optional prompt))
(declare-function amble-session-mode "amble" ())
(declare-function amble-keyboard-quit "amble" ())
(defvar amble--busy)
(defvar amble--last-error)
(defvar amble--history nil)
(defvar amble-session-mode-map)

(defvar-local amble-input--prompt nil)
(defvar-local amble-input--start nil)
(defvar-local amble-input--history-index nil)
(defvar-local amble-input--saved-draft nil)
(defvar-local amble-input--internal nil)
(defvar-local amble-input--revision 0)

(defconst amble-input--editing-commands
  '(self-insert-command newline newline-and-indent open-line
    forward-char backward-char right-char left-char next-line previous-line
    forward-word backward-word right-word left-word
    move-beginning-of-line move-end-of-line beginning-of-buffer end-of-buffer
    back-to-indentation forward-paragraph backward-paragraph
    forward-sentence backward-sentence forward-sexp backward-sexp
    scroll-up-command scroll-down-command scroll-up scroll-down
    scroll-left scroll-right recenter-top-bottom move-to-window-line-top-bottom
    set-mark-command exchange-point-and-mark mark-whole-buffer mark-word
    mark-paragraph mark-end-of-sentence mark-sexp
    delete-char delete-forward-char delete-backward-char backward-delete-char
    backward-delete-char-untabify delete-horizontal-space just-one-space
    delete-blank-lines kill-line kill-whole-line kill-word backward-kill-word
    kill-sentence backward-kill-sentence kill-sexp backward-kill-sexp
    kill-region kill-ring-save
    copy-region-as-kill yank yank-pop yank-from-kill-ring
    clipboard-yank clipboard-kill-ring-save clipboard-kill-region
    ns-copy-including-secondary ns-paste-secondary
    undo undo-only undo-redo advertised-undo
    transpose-chars transpose-words transpose-lines transpose-sentences
    upcase-word downcase-word capitalize-word upcase-region downcase-region
    capitalize-region upcase-dwim downcase-dwim capitalize-dwim
    indent-for-tab-command indent-region fill-paragraph fill-region
    isearch-forward isearch-backward isearch-forward-regexp isearch-backward-regexp
    query-replace query-replace-regexp quoted-insert
    toggle-input-method set-input-method universal-argument digit-argument
    negative-argument keyboard-quit delete-selection-repeat-replace-region
    mouse-set-point mouse-set-region mouse-drag-region mouse-save-then-kill
    mouse-drag-region-shift-adjust mouse-yank-primary mouse-yank-secondary
    mwheel-scroll pixel-scroll-precision mouse-wheel-text-scale
    text-scale-adjust text-scale-increase text-scale-decrease
    mouse-drag-header-line mouse-drag-mode-line mouse-select-window
    handle-switch-frame handle-select-window ignore ignore-preserving-kill-region
    amble-toggle-popup amble-show amble-hide amble-input-focus
    amble-input-send amble-input-previous amble-input-next
    amble-cancel amble-new-session amble-keyboard-quit)
  "Global commands usable in the conversation without leaving its editing task.")

(defun amble-input--notify (text)
  "Show TEXT briefly in the echo area without logging it to Messages."
  (let ((message-log-max nil))
    (message "%s" text)))

(defun amble-input--blocked-key ()
  "Report an unrelated shortcut in the echo area."
  (interactive)
  (amble-input--notify "Shortcut disabled here; Esc returns to work"))

(defun amble-input--editing-map (source &optional seen)
  "Copy only editing bindings from SOURCE, blocking all other keys.
Retain prefix maps and character ranges, including Unicode input.  SEEN
prevents recursion when a user's prefix maps refer back to each other."
  (let ((seen (or seen (make-hash-table :test #'eq))))
    (or (gethash source seen)
        (let ((map (make-keymap)))
          (puthash source map seen)
          (define-key map [t] #'amble-input--blocked-key)
          (map-keymap
           (lambda (event binding)
             (unless (memq event '(menu-bar tool-bar tab-bar))
               (let ((allowed
                      (cond ((keymapp binding) (amble-input--editing-map binding seen))
                            ((memq binding amble-input--editing-commands) binding))))
                 (when allowed
                   (if (consp event)
                       (set-char-table-range (cadr map) event allowed)
                     (define-key map (vector event) allowed))))))
           source)
          map))))

(defun amble-input--allow-translated-keys (map)
  "Let native function-key translations run before MAP filters commands.
An explicit nil binding suppresses MAP's catch-all for an otherwise unbound
event.  Emacs can then translate Backspace, Delete, Return and keypad events
normally, including the terminal's configured deletion direction.  The
translated keys are still checked against the isolated command map."
  (map-keymap
   (lambda (event translation)
     (when (and (symbolp event) (arrayp translation)
                (not (lookup-key (current-global-map) (vector event) t)))
       (define-key map (vector event) nil)))
   local-function-key-map))

(defun amble-input-select-all ()
  "Select the whole draft when editing it; otherwise select the transcript."
  (interactive)
  (if (and (amble-input--ready-p) (>= (point) amble-input--start))
      (save-restriction
        (narrow-to-region amble-input--start (point-max))
        (call-interactively #'mark-whole-buffer))
    (call-interactively #'mark-whole-buffer)))

(defun amble-input--mouse-activate (event)
  "Activate a transcript button at EVENT, or paste normally in the draft."
  (interactive "e")
  (let* ((position (event-start event))
         (window (posn-window position))
         (point (posn-point position))
         (button (and (window-live-p window) (integerp point)
                      (with-current-buffer (window-buffer window) (button-at point)))))
    (if button
        (progn (mouse-set-point event) (button-activate button))
      (mouse-yank-primary event))))

(defun amble-input--shift-motion ()
  "Move with Shift held, retaining ordinary region selection."
  (interactive)
  (let* ((event (event-convert-list
                 (append (remq 'shift (event-modifiers last-command-event))
                         (list (event-basic-type last-command-event)))))
         (command (key-binding (vector event)))
         (this-command-keys-shift-translated t))
    (setq this-command command)
    (call-interactively command)))

(defun amble-input-setup-keys ()
  "Isolate conversation keys from unrelated global and minor-mode bindings.
Rebuild on opening to retain the user's current global editing and Amble
shortcuts.  Minibuffers and temporary input/search maps remain independent."
  (let ((editing (amble-input--editing-map (current-global-map))))
    (amble-input--allow-translated-keys editing)
    (define-key editing (kbd "C-g") #'amble-keyboard-quit)
    (define-key editing [remap mark-whole-buffer] #'amble-input-select-all)
    ;; A catch-all stops Emacs's implicit Shift translation.  Preserve the
    ;; standard shifted navigation explicitly, including region activation.
    (dolist (key '("S-<left>" "S-<right>" "S-<up>" "S-<down>"
                   "S-<home>" "S-<end>" "S-<prior>" "S-<next>"
                   "C-S-<left>" "C-S-<right>" "C-S-<up>" "C-S-<down>"
                   "C-S-<home>" "C-S-<end>"))
      (define-key editing (kbd key) #'amble-input--shift-motion))
    ;; The overriding map also bypasses button text-property keymaps.
    (define-key editing [mouse-2] #'amble-input--mouse-activate)
    (setq-local overriding-local-map
                (make-composed-keymap amble-session-mode-map editing))))

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
    (cl-incf amble-input--revision)))

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
          (revision amble-input--revision) accepted failure)
      (cond
       ((bound-and-true-p amble--busy)
        (amble-input--notify "Still working; C-c C-k cancels"))
       ((string-empty-p (string-trim text))
        (amble-input--notify "Write a message after You"))
       (t
        ;; Remove the submitted draft before logging You/Agent entries above
        ;; it. Restore it on a failed start, without deleting newer user input.
        (let ((amble-input--internal t) (buffer-undo-list t))
          (delete-region amble-input--start (point-max)))
        (condition-case err
            (progn (amble text) (setq accepted (not amble--last-error)))
          (error (setq failure (error-message-string err))))
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
              (amble-input--notify (or failure "Request failed; draft kept")))))))
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
