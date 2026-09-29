;;; amble-core.el --- Live Emacs tools for an agent -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "31.1"))
;; Version: 0.4.0

;;; Commentary:
;; Backend-independent tools.  Lisp evaluation intentionally has the authority
;; of the running Emacs.  It is not a sandbox.  Only an active user-started agent
;; session should be allowed to call these tools.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'project)
(declare-function amble--log "amble" (label text))

(defgroup amble nil "Operate Emacs using natural language." :group 'applications)
(defcustom amble-todo-file nil
  "Default Org inbox.  Nil uses an existing `org-default-notes-file'."
  :type '(choice (const nil) file))
(defcustom amble-stale-minutes 60
  "Minimum idle age for cleaning a buffer."
  :type 'integer)
(defcustom amble-eval-timeout 15
  "Cooperative timeout for Lisp tools, in seconds.
Timers cannot interrupt CPU-bound Lisp or blocking native functions; use C-g."
  :type 'number)
(defvar amble-origin-buffer nil)
(defcustom amble-context-buffer-predicate nil
  "Optional function deciding which buffers may appear in automatic context.
Called with a buffer. Nil includes all public buffer metadata. This is a context
filter, not an execution sandbox: emacs_eval retains full Emacs authority."
  :type '(choice (const nil) function))
(defvar-local amble--last-used nil)
(defvar amble--reopen-files nil)

(defun amble--touch-buffer ()
  "Track the most recently used time without changing user buffers."
  (unless (minibufferp)
    (setq amble--last-used (float-time))))

(defun amble-tools-enable ()
  "Start recording buffer activity."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (unless amble--last-used
        (setq amble--last-used (float-time)))))
  (add-hook 'post-command-hook #'amble--touch-buffer))

(defun amble--buffer (name)
  "Resolve NAME or the current turn's originating buffer."
  (or (and name (get-buffer name))
      (and (not name) (buffer-live-p amble-origin-buffer)
           amble-origin-buffer)
      (and (not name) (current-buffer))
      (user-error "No live buffer named %s" name)))

(defun amble--project-root ()
  "Return the current local project root, if any."
  (unless (file-remote-p default-directory)
    (when-let* ((p (project-current nil))) (project-root p))))

(defun amble--buffer-info (buffer)
  "Return JSON-compatible metadata about BUFFER, without its text."
  (with-current-buffer buffer
    `((name . ,(buffer-name)) (file . ,buffer-file-name)
      (mode . ,(symbol-name major-mode))
      (modified . ,(if (buffer-modified-p) t :false))
      (visible . ,(if (get-buffer-window buffer t) t :false))
      (size . ,(buffer-size)) (point . ,(point)) (tick . ,(buffer-chars-modified-tick))
      (process . ,(when-let* ((p (get-buffer-process buffer)))
                    (symbol-name (process-status p)))))))

(defun amble--context-buffer-p (buffer)
  "Whether BUFFER can appear in automatic context."
  (and (not (string-prefix-p " " (buffer-name buffer)))
       (or (null amble-context-buffer-predicate)
           (funcall amble-context-buffer-predicate buffer))))

(defun amble-search-symbols (query &optional kind)
  "Discover live symbols containing QUERY, filtered by KIND."
  (let* ((predicate (pcase kind
                      ("command" #'commandp) ("variable" #'boundp)
                      ("function" #'fboundp) (_ nil)))
         (matches (apropos-internal (regexp-quote query) predicate)))
    `((total . ,(length matches))
      (matches . ,(vconcat
                   (mapcar
                    (lambda (s)
                      `((name . ,(symbol-name s))
                        (command . ,(if (commandp s) t :false))
                        (summary . ,(car (split-string
                                          (or (and (fboundp s) (documentation s t))
                                              (documentation-property s 'variable-documentation t)
                                              "") "\n")))))
                    (seq-take matches 80)))))))


(defun amble--limit (value default maximum)
  "Validate a positive bounded VALUE, using DEFAULT when absent."
  (let ((n (or value default)))
    (unless (and (integerp n) (<= 1 n maximum))
      (user-error "Limit must be between 1 and %d" maximum))
    n))

(defun amble--local-path (path)
  "Resolve PATH relative to the invocation buffer without remote I/O."
  (let ((result (expand-file-name path
                                  (with-current-buffer (amble--buffer nil)
                                    default-directory))))
    (when (file-remote-p result) (user-error "This tool requires a local path"))
    result))

(defun amble--directory (directory)
  "Resolve DIRECTORY, defaulting to the invocation project or directory."
  (let ((dir (amble--local-path
              (or directory (with-current-buffer (amble--buffer nil)
                              (or (amble--project-root) default-directory))))))
    (unless (file-directory-p dir) (user-error "Directory does not exist: %s" dir))
    (file-name-as-directory dir)))

(defun amble--target (args &optional open)
  "Resolve ARGS buffer/file without changing selection.  OPEN permits visiting."
  (when (and (alist-get 'buffer args) (alist-get 'file args))
    (user-error "Specify either buffer or file, not both"))
  (if-let* ((file (alist-get 'file args)))
      (let* ((path (amble--local-path file))
             (live (find-buffer-visiting path)))
        (or live
            (and open (let ((enable-local-variables :safe) (enable-local-eval nil))
                        (find-file-noselect path)))
            (user-error "File has no live buffer; use emacs_read or open it first")))
    (amble--buffer (alist-get 'buffer args))))

(defun amble--value (value &optional depth)
  "Convert Lisp VALUE into bounded JSON-compatible data."
  (let ((depth (or depth 0)))
    (cond
     ((> depth 6) "[depth limit]")
     ((or (null value) (eq value t) (eq value :false) (numberp value)) value)
     ((stringp value) (substring-no-properties value 0 (min (length value) 12000)))
     ((bufferp value) `((buffer . ,(buffer-name value))))
     ((symbolp value) (symbol-name value))
     ((hash-table-p value)
      (let ((result (make-hash-table :test 'equal)) (n 0))
        (maphash (lambda (k v)
                   (when (< n 100)
                     (puthash (format "%s" k) (amble--value v (1+ depth)) result)
                     (cl-incf n))) value)
        result))
     ((or (vectorp value) (and (listp value) (proper-list-p value)))
      (if (and (consp value)
               (cl-every (lambda (x) (and (consp x) (or (symbolp (car x)) (stringp (car x))))) value))
          (let ((result (make-hash-table :test 'equal)))
            (dolist (item (seq-take value 100))
              (puthash (format "%s" (car item)) (amble--value (cdr item) (1+ depth)) result))
            result)
        (vconcat (mapcar (lambda (v) (amble--value v (1+ depth)))
                         (seq-take (append value nil) 100)))))
     (t (let ((print-length 20) (print-level 3) (print-circle t))
          (prin1-to-string value))))))

(defun amble--no-input (&rest _)
  "Reject minibuffer input during a model tool call."
  (user-error "This operation needs interactive input; ask the user for the missing value"))

(defun amble--execute (function)
  "Run FUNCTION without waiting for minibuffer input."
  (let ((minibuffer-setup-hook (cons #'amble--no-input minibuffer-setup-hook)))
    (cl-letf (((symbol-function 'read-from-minibuffer) #'amble--no-input)
              ((symbol-function 'read-string) #'amble--no-input)
              ((symbol-function 'completing-read) #'amble--no-input)
              ((symbol-function 'read-file-name) #'amble--no-input)
              ((symbol-function 'read-char) #'amble--no-input)
              ((symbol-function 'read-key) #'amble--no-input)
              ((symbol-function 'read-passwd) #'amble--no-input)
              ((symbol-function 'yes-or-no-p) #'amble--no-input)
              ((symbol-function 'y-or-n-p) #'amble--no-input))
             (with-timeout (amble-eval-timeout (error "Elisp execution timed out"))
               (funcall function)))))

(provide 'amble-core)
;;; amble-core.el ends here
