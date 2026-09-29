;;; amble-workspace.el --- Buffers and windows -*- lexical-binding: t; -*-
(require 'amble-core)
(defun amble--stale-p (buffer minutes)
  "Whether BUFFER is safe to close and has been idle for MINUTES."
  (with-current-buffer buffer
    (and (not (minibufferp buffer))
         (not (eq buffer amble-origin-buffer))
         (not (string-match-p
               "\\`\\(?: \\|\\*\\(?:scratch\\|Messages\\|Warnings\\|Backtrace\\|amble\\)\\)"
               (buffer-name buffer)))
         (not (buffer-modified-p))
         (not (get-buffer-window buffer t))
         (not (get-buffer-process buffer))
         (not (bound-and-true-p server-buffer-clients))
         amble--last-used
         (> (- (float-time) (max amble--last-used
                                 (if buffer-display-time
                                     (float-time buffer-display-time) 0)))
            (* 60 minutes)))))

(defun amble-clean-buffers (dry-run &optional minutes)
  "Preview or close stale buffers.  DRY-RUN never closes anything.
Honor kill hooks and vetoes; never disable save prompts to force a close."
  (let ((age (or minutes amble-stale-minutes)) candidates closed skipped)
    (unless (and (numberp age) (> age 0)) (user-error "Idle minutes must be positive"))
    (dolist (b (buffer-list))
      (when (amble--stale-p b age)
        (push (buffer-name b) candidates)
        (unless dry-run
          (let ((name (buffer-name b)) (file (buffer-file-name b)))
            (if (kill-buffer b)
                (progn (push name closed)
                       (when file (cl-pushnew file amble--reopen-files :test #'equal)))
              (push name skipped))))))
    `((dry_run . ,(if dry-run t :false)) (idle_minutes . ,age)
      (candidates . ,(vconcat (nreverse candidates)))
      (closed . ,(vconcat (nreverse closed)))
      (vetoed . ,(vconcat (nreverse skipped))))))

(defun amble-reopen-cleaned ()
  "Reopen file buffers closed by the agent in this Emacs session."
  (interactive)
  (let ((inhibit-message t) (message-log-max nil) (count 0))
    (dolist (file amble--reopen-files)
      (when (file-exists-p file)
        (find-file-noselect file)
        (cl-incf count)))
    (when (fboundp 'amble--log)
      (amble--log "Reopened" (format "Reopened %d file buffers" count)))))

(defvar amble-workspace--window-serial 0)
(defvar amble-workspace--layouts (make-hash-table :test 'equal))
(defvar amble-workspace--layout-serial 0)

(defun amble-workspace--window-id (window)
  "Return a stable session ID for WINDOW."
  (or (window-parameter window 'amble-id)
      (let ((id (format "window-%d" (cl-incf amble-workspace--window-serial))))
        (set-window-parameter window 'amble-id id) id)))

(defun amble-workspace--window (id)
  "Resolve window ID in the selected frame, using selection if absent."
  (if (null id) (selected-window)
    (or (cl-find id (window-list nil 'no-minibuf) :key #'amble-workspace--window-id :test #'equal)
        (user-error "Unknown window ID in this frame: %s" id))))

(defun amble-workspace-windows (&optional filtered)
  "Describe visible windows with stable IDs; FILTERED respects context limits."
  (vconcat (mapcar (lambda (window)
                     `((id . ,(amble-workspace--window-id window))
                       (buffer . ,(buffer-name (window-buffer window)))
                       (selected . ,(if (eq window (selected-window)) t :false))
                       (width . ,(window-total-width window)) (height . ,(window-total-height window))))
                   (cl-remove-if-not
                    (lambda (window) (or (not filtered) (amble--context-buffer-p (window-buffer window))))
                    (window-list nil 'no-minibuf)))))

(cl-defun amble-workspace-buffer-tool (args)
          "Manage buffers with explicit save and close semantics from ARGS."
          (pcase (alist-get 'action args)
            ("list" `((buffers . ,(vconcat (mapcar #'amble--buffer-info
                                                   (cl-remove-if-not #'amble--context-buffer-p (buffer-list)))))))
            ("open"
             (unless (alist-get 'file args) (user-error "open requires file"))
             (let* ((path (amble--local-path (alist-get 'file args)))
                    (buffer (progn (unless (file-exists-p path) (user-error "Use create for a new buffer"))
                                   (amble--target args t))))
               (when (eq t (alist-get 'display args)) (pop-to-buffer buffer))
               (amble--buffer-info buffer)))
            ("create"
             (let ((name (alist-get 'name args)))
               (unless (and (stringp name) (not (string-empty-p name))) (user-error "create requires name"))
               (when (get-buffer name) (user-error "Buffer already exists"))
               (let ((buffer (generate-new-buffer name)))
                 (with-current-buffer buffer (buffer-enable-undo))
                 (when (eq t (alist-get 'display args)) (pop-to-buffer buffer))
                 (amble--buffer-info buffer))))
            ("clean"
             (unless (assq 'dry_run args) (user-error "clean requires dry_run"))
             (amble-clean-buffers (not (eq :false (alist-get 'dry_run args))) (alist-get 'minutes args)))
            ("restore" (amble-reopen-cleaned) `((restored . ,(vconcat amble--reopen-files))))
            (_
             (with-current-buffer (amble--target args)
               (pcase (alist-get 'action args)
                 ("switch" (pop-to-buffer (current-buffer)))
                 ("rename"
                  (unless (alist-get 'name args) (user-error "rename requires name"))
                  (rename-buffer (alist-get 'name args)))
                 ("save"
                  (unless (equal (alist-get 'expected_tick args) (buffer-chars-modified-tick))
                    (user-error "Buffer changed; read before saving"))
                  (when-let* ((destination (alist-get 'destination args)))
                    (setq destination (amble--local-path destination))
                    (when (file-exists-p destination) (user-error "Destination exists; refusing overwrite"))
                    (set-visited-file-name destination t))
                  (unless buffer-file-name (user-error "New buffers require destination to save"))
                  (when (file-remote-p buffer-file-name) (user-error "Use an explicit remote workflow for saving"))
                  (unless (verify-visited-file-modtime (current-buffer)) (user-error "File changed on disk; reconcile before saving"))
                  (amble--execute #'save-buffer))
                 ("close"
                  (when (or (buffer-modified-p) (get-buffer-process (current-buffer))
                            (eq (current-buffer) amble-origin-buffer))
                    (user-error "Refusing to close unsaved, process, or invocation buffer"))
                  (let ((name (buffer-name)) (file buffer-file-name))
                    (unless (amble--execute (lambda () (kill-buffer (current-buffer)))) (user-error "A hook prevented closing"))
                    (when file (cl-pushnew file amble--reopen-files :test #'equal))
                    (cl-return-from amble-workspace-buffer-tool `((closed . ,name)))))
                 (_ (user-error "Unknown buffer action")))
               (append (amble--buffer-info (current-buffer)) `((tick . ,(buffer-chars-modified-tick))))))))

(cl-defun amble-workspace-window-tool (args)
          "Manage windows and saved layouts according to ARGS."
          (let ((action (alist-get 'action args)))
            (pcase action
              ("list" nil)
              ("snapshot"
               (when (>= (hash-table-count amble-workspace--layouts) 20) (clrhash amble-workspace--layouts))
               (let ((id (format "layout-%d" (cl-incf amble-workspace--layout-serial))))
                 (puthash id (current-window-configuration) amble-workspace--layouts)
                 (cl-return-from amble-workspace-window-tool `((layout_id . ,id)))))
              ("restore"
               (let ((layout (gethash (alist-get 'layout_id args) amble-workspace--layouts)))
                 (unless layout (user-error "Unknown saved layout"))
                 (unless (frame-live-p (window-configuration-frame layout)) (user-error "Saved frame no longer exists"))
                 (set-window-configuration layout)))
              ("show"
               (let ((buffer (amble--target args t)))
                 (if (alist-get 'window_id args)
                     (set-window-buffer (amble-workspace--window (alist-get 'window_id args)) buffer)
                   (display-buffer buffer))))
              (_
               (let ((window (amble-workspace--window (alist-get 'window_id args))))
                 (pcase action
                   ("focus" (select-window window))
                   ("split" (split-window window nil (intern (or (alist-get 'side args) "right"))))
                   ("resize"
                    (let ((delta (alist-get 'delta args)))
                      (unless (and (integerp delta) (<= -200 delta 200)) (user-error "delta must be -200..200"))
                      (window-resize window delta (eq t (alist-get 'horizontal args)))))
                   ("close" (delete-window window))
                   ("only" (delete-other-windows window))
                   (_ (user-error "Unknown window action"))))))
            `((windows . ,(amble-workspace-windows)))))

(provide 'amble-workspace)
;;; amble-workspace.el ends here
