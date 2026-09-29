;;; amble-jobs.el --- Bounded asynchronous process jobs -*- lexical-binding: t; -*-
(require 'amble-core)

(defvar amble-jobs--table (make-hash-table :test 'equal))
(defvar amble-jobs--serial 0)
(defconst amble-jobs--output-limit 131072)

(defun amble-jobs--get (id)
  "Return job ID or signal a useful error."
  (or (gethash id amble-jobs--table) (user-error "Unknown job: %s" id)))

(defun amble-jobs-info (id &optional offset limit)
  "Read metadata and an output page for job ID using OFFSET and LIMIT."
  (let* ((job (amble-jobs--get id)) (buffer (plist-get job :buffer))
         (offset (or offset 0)) (limit (amble--limit limit 8000 24000))
         (text (if (buffer-live-p buffer) (with-current-buffer buffer (buffer-string)) "")))
    (unless (and (integerp offset) (<= 0 offset (length text)))
      (user-error "Output offset must be 0–%d" (length text)))
    (let ((end (min (length text) (+ offset limit))))
      `((job_id . ,id) (status . ,(plist-get job :status))
        (directory . ,(plist-get job :directory)) (command . ,(vconcat (plist-get job :command)))
        (exit_code . ,(plist-get job :exit-code))
        (output . ,(substring-no-properties text offset end)) (offset . ,offset) (next_offset . ,end)
        (truncated . ,(if (or (< end (length text)) (plist-get job :truncated)) t :false))
        (buffer . ,(and (buffer-live-p buffer) (buffer-name buffer)))))))

(defun amble-jobs--notify (id)
  "Deliver job ID completion outside process sentinels."
  (let* ((job (amble-jobs--get id)) (waiters (plist-get job :waiters)))
    (setf (plist-get job :waiters) nil)
    (dolist (callback waiters)
      (funcall callback (amble-jobs-info id)))))

(defun amble-jobs-subscribe (id callback)
  "Call CALLBACK with job ID's result when it finishes."
  (let ((job (amble-jobs--get id)))
    (push callback (plist-get job :waiters))
    (unless (equal (plist-get job :status) "running")
      (run-at-time 0 nil #'amble-jobs--notify id))))

(defun amble-jobs-unsubscribe (id callback)
  "Remove CALLBACK from job ID."
  (when-let* ((job (gethash id amble-jobs--table)))
    (setf (plist-get job :waiters) (delq callback (plist-get job :waiters)))))

(defun amble-jobs-start (command directory &optional timeout)
  "Start COMMAND (program and arguments) in DIRECTORY; return job metadata."
  (setq command (append command nil) directory (amble--directory directory)
        timeout (or timeout 120))
  (unless (and command (cl-every #'stringp command) (not (string-empty-p (car command))))
    (user-error "command must contain a program and optional arguments"))
  (unless (and (numberp timeout) (<= 1 timeout 3600)) (user-error "Job timeout must be 1–3600 seconds"))
  (when (>= (cl-count "running" (hash-table-values amble-jobs--table)
                      :key (lambda (job) (plist-get job :status)) :test #'equal) 4)
    (user-error "Four jobs are already running; wait or cancel one"))
  ;; Bound retained job records and buffers; running jobs and their waiters survive.
  (when (>= (hash-table-count amble-jobs--table) 30)
    (let (oldest)
      (maphash (lambda (id job)
                 (when (and (not (equal (plist-get job :status) "running"))
                            (null (plist-get job :waiters))
                            (let ((b (plist-get job :buffer)))
                              (or (not (buffer-live-p b))
                                  (and (not (get-buffer-window b t)) (not (buffer-modified-p b)))))
                            (or (null oldest) (< (plist-get job :created) (plist-get (cdr oldest) :created))))
                   (setq oldest (cons id job)))) amble-jobs--table)
      (when oldest
        (when (buffer-live-p (plist-get (cdr oldest) :buffer)) (kill-buffer (plist-get (cdr oldest) :buffer)))
        (remhash (car oldest) amble-jobs--table))
      (unless oldest (user-error "Job history is full; close unused output buffers first"))))
  (let* ((id (format "job-%d" (cl-incf amble-jobs--serial)))
         (buffer (generate-new-buffer (format "*amble-job %s*" id)))
         (job (list :id id :command command :directory directory :buffer buffer
                    :status "running" :process nil :timer nil :waiters nil
                    :created (float-time) :truncated nil :exit-code nil))
         (default-directory directory))
    (puthash id job amble-jobs--table)
    (with-current-buffer buffer (special-mode) (setq-local default-directory directory))
    (condition-case err
        (let ((process
               (make-process
                :name (concat "amble-" id) :buffer buffer :command command :noquery t
                :connection-type 'pipe :coding 'utf-8-unix
                :filter (lambda (_proc chunk)
                          (when (buffer-live-p buffer)
                            (with-current-buffer buffer
                              (let ((inhibit-read-only t)
                                    (remaining (- amble-jobs--output-limit (buffer-size))))
                                (goto-char (point-max))
                                (when (> remaining 0)
                                  (insert (substring chunk 0 (min remaining (length chunk)))))
                                (when (> (length chunk) remaining)
                                  (setf (plist-get job :truncated) t))
                                (set-buffer-modified-p nil)))))
                :sentinel (lambda (proc _event)
                            (when (memq (process-status proc) '(exit signal failed))
                              (when (equal (plist-get job :status) "running")
                                (setf (plist-get job :status) (if (= (process-exit-status proc) 0) "completed" "failed")))
                              (setf (plist-get job :exit-code) (process-exit-status proc))
                              (when (timerp (plist-get job :timer)) (cancel-timer (plist-get job :timer)))
                              (run-at-time 0 nil #'amble-jobs--notify id))))))
          (setf (plist-get job :process) process
                (plist-get job :timer)
                (run-at-time timeout nil
                             (lambda ()
                               (when (process-live-p process)
                                 (setf (plist-get job :status) "timed_out")
                                 (delete-process process))))))
      (error (setf (plist-get job :status) "failed")
             (with-current-buffer buffer
               (let ((inhibit-read-only t)) (insert (error-message-string err))))))
    (amble-jobs-info id)))

(defun amble-jobs-tool (args)
  "Dispatch a bounded process job operation described by ARGS."
  (pcase (alist-get 'action args)
    ("start" (amble-jobs-start (alist-get 'command args) (alist-get 'directory args) (alist-get 'timeout args)))
    ("list" `((jobs . ,(vconcat (mapcar (lambda (id)
                                          (let ((info (amble-jobs-info id 0 1)))
                                            (assq-delete-all 'output info)))
                                        (hash-table-keys amble-jobs--table))))))
    ("status" (amble-jobs-info (alist-get 'job_id args) (alist-get 'offset args) (alist-get 'limit args)))
    ("wait" (let* ((id (alist-get 'job_id args)) (job (amble-jobs--get id)))
              (if (equal (plist-get job :status) "running")
                  (list :amble-wait id)
                (amble-jobs-info id))))
    ("cancel" (let* ((id (alist-get 'job_id args)) (job (amble-jobs--get id)))
                (when (process-live-p (plist-get job :process))
                  (setf (plist-get job :status) "cancelled")
                  (delete-process (plist-get job :process)))
                (amble-jobs-info id)))
    (_ (user-error "Unknown job action"))))

(provide 'amble-jobs)
;;; amble-jobs.el ends here
