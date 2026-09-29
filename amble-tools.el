;;; amble-tools.el --- Core tool registry and capability discovery -*- lexical-binding: t; -*-
;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1"))
(require 'amble-core)
(require 'amble-files)
(require 'amble-edit)
(require 'amble-workspace)
(require 'amble-jobs)

(defvar amble-tools--registry (make-hash-table :test 'equal))
(defvar amble-tools--enabled nil)
(defconst amble-tools--capabilities
  '(("org" amble-org "Org display, capture templates and TODO inbox")
    ("git" amble-git "Git status and diff as asynchronous jobs")))

(defun amble-tools-register (name description fields required handler category &optional capability)
  "Register NAME with DESCRIPTION, FIELDS, REQUIRED, HANDLER and CATEGORY.
CAPABILITY, when present, enables lazy loading outside the core tool list."
  (puthash name
           (list :schema `((type . "function") (name . ,name) (description . ,description)
                           (parameters . ((type . "object")
                                          (properties . ,(or fields (make-hash-table)))
                                          (required . ,(vconcat required)) (additionalProperties . :false)))
                           (strict . :false))
                 :handler handler :category category :capability capability)
           amble-tools--registry))

(defun amble-tools--active-p (entry)
  "Whether registry ENTRY is currently available."
  (or (null (plist-get entry :capability)) (member (plist-get entry :capability) amble-tools--enabled)))

(defun amble-tool-specs ()
  "Return active Responses tool definitions in stable name order."
  (vconcat (mapcar (lambda (name) (plist-get (gethash name amble-tools--registry) :schema))
                   (sort (cl-remove-if-not
                          (lambda (name) (amble-tools--active-p (gethash name amble-tools--registry)))
                          (hash-table-keys amble-tools--registry)) #'string<))))

(defun amble-tools--validate (schema value path)
  "Validate VALUE against the declared subset of SCHEMA, labeling errors PATH."
  (unless (eq schema t)
    (let ((type (alist-get 'type schema)))
      (unless
          (pcase type
            ("string" (stringp value))
            ("integer" (integerp value))
            ("number" (numberp value))
            ("boolean" (memq value '(t :false)))
            ("array" (vectorp value))
            ("object" (and (listp value) (proper-list-p value) (cl-every #'consp value)))
            (_ t))
        (user-error "%s must be %s" path type))
      (when-let* ((choices (alist-get 'enum schema)))
        (unless (member value (append choices nil)) (user-error "Invalid value for %s" path)))
      (when (equal type "array")
        (when (> (length value) 200) (user-error "%s has too many elements" path))
        (dolist (item (append value nil)) (amble-tools--validate (or (alist-get 'items schema) t) item path)))
      (when (equal type "object")
        (let ((fields (alist-get 'properties schema)))
          (dolist (key (append (alist-get 'required schema) nil))
            (unless (assq (intern key) value) (user-error "%s requires %s" path key)))
          (dolist (entry value)
            (let ((spec (and (listp fields) (assq (car entry) fields))))
              (unless spec (user-error "Unknown argument %s in %s" (car entry) path))
              (amble-tools--validate (cdr spec) (cdr entry) (format "%s.%s" path (car entry))))))))))

(defun amble-dispatch-tool (name args)
  "Validate and dispatch active tool NAME with ARGS; unknown tools fail closed."
  (let ((entry (gethash name amble-tools--registry)))
    (unless (and entry (amble-tools--active-p entry))
      (user-error "Tool %s is unavailable; inspect emacs_capabilities first" name))
    (amble-tools--validate (alist-get 'parameters (plist-get entry :schema)) args name)
    (funcall (plist-get entry :handler) args)))

(defun amble-tools-capabilities (args)
  "List or enable a known capability according to ARGS."
  (let ((action (or (alist-get 'action args) "list")) (name (alist-get 'name args)))
    (pcase action
      ("list" nil)
      ("enable"
       (let ((entry (assoc name amble-tools--capabilities)))
         (unless entry (user-error "Unknown capability: %s" name))
         (require (nth 1 entry))
         (cl-pushnew name amble-tools--enabled :test #'equal)))
      ("disable" (setq amble-tools--enabled (delete name amble-tools--enabled)))
      (_ (user-error "Unknown capability action")))
    `((capabilities . ,(vconcat
                        (mapcar (lambda (entry)
                                  `((name . ,(car entry)) (description . ,(nth 2 entry))
                                    (enabled . ,(if (member (car entry) amble-tools--enabled) t :false))))
                                amble-tools--capabilities)))
      (tools . ,(vconcat
                 (mapcar (lambda (spec)
                           `((name . ,(alist-get 'name spec))
                             (category . ,(plist-get (gethash (alist-get 'name spec) amble-tools--registry) :category))))
                         (append (amble-tool-specs) nil)))))))

(defun amble-tools-select-context ()
  "Enable relevant optional capabilities from the invocation buffer."
  (with-current-buffer (amble--buffer nil)
    (when (derived-mode-p 'org-mode) (amble-tools-capabilities '((action . "enable") (name . "org"))))
    (when (and (not (file-remote-p default-directory))
               (locate-dominating-file default-directory ".git"))
      (amble-tools-capabilities '((action . "enable") (name . "git"))))))

(defun amble-tools-context (args)
  "Return compact invocation context, or full buffer details using ARGS."
  (with-current-buffer (amble--buffer nil)
    (when (and amble-context-buffer-predicate
               (not (funcall amble-context-buffer-predicate (current-buffer))))
      (user-error "Invocation buffer is excluded by the context filter"))
    (let ((context
           `((origin . ,(amble--buffer-info (current-buffer)))
             (directory . ,default-directory) (project . ,(amble--project-root))
             (region . ,(when (use-region-p) `((start . ,(region-beginning)) (end . ,(region-end)))))
             (windows . ,(amble-workspace-windows t))
             (capabilities . ,(vconcat amble-tools--enabled))
             (jobs . ,(vconcat (cl-loop for id being the hash-keys of amble-jobs--table
                                        for job = (gethash id amble-jobs--table)
                                        when (equal (plist-get job :status) "running")
                                        collect `((job_id . ,id) (status . "running"))))))))
      (when (eq t (alist-get 'detailed args))
        (setq context (append context
                              `((emacs_version . ,emacs-version)
                                (buffers . ,(vconcat (mapcar #'amble--buffer-info
                                                             (cl-remove-if-not #'amble--context-buffer-p (buffer-list)))))))))
      context)))

(defun amble-tools-inspect (args)
  "Inspect symbols, key bindings or mode information using ARGS."
  (with-current-buffer (amble--buffer (alist-get 'buffer args))
    (pcase (alist-get 'kind args)
      ("symbol"
       (let ((symbol (intern-soft (or (alist-get 'name args) ""))))
         (unless symbol (user-error "Unknown symbol; search symbols first"))
         `((symbol . ,(symbol-name symbol)) (command . ,(if (commandp symbol) t :false))
           (arguments . ,(when (fboundp symbol) (amble--value (help-function-arglist symbol t))))
           (function_doc . ,(when (fboundp symbol) (amble--value (documentation symbol t))))
           (variable_doc . ,(amble--value (documentation-property symbol 'variable-documentation t)))
           (value . ,(when (and (eq t (alist-get 'include_value args)) (boundp symbol))
                       (amble--value (symbol-value symbol))))
           (source . ,(or (symbol-file symbol 'defun) (symbol-file symbol 'defvar))))))
      ("key"
       (unless (alist-get 'name args) (user-error "key inspection requires name"))
       (let ((binding (key-binding (kbd (alist-get 'name args)) t)))
         `((key . ,(alist-get 'name args)) (buffer . ,(buffer-name))
           (binding . ,(amble--value binding))
           (documentation . ,(when (and (symbolp binding) (fboundp binding))
                               (amble--value (documentation binding t)))))))
      ("mode"
       `((major_mode . ,(symbol-name major-mode))
         (documentation . ,(amble--value (documentation major-mode t)))
         (minor_modes . ,(vconcat (mapcar #'symbol-name
                                          (cl-remove-if-not (lambda (mode) (and (boundp mode) (symbol-value mode)))
                                                            minor-mode-list))))))
      (_ (user-error "Unknown inspection kind")))))

(defun amble-tools-command (args)
  "Invoke a discovered function with explicit noninteractive ARGS."
  (let ((fn (intern-soft (alist-get 'function args))))
    (unless (and fn (fboundp fn) (not (macrop fn)) (not (special-form-p fn)))
      (user-error "Not a callable function; inspect its symbol first"))
    (with-current-buffer (amble--buffer (alist-get 'buffer args))
      (undo-boundary)
      (unwind-protect
          `((value . ,(amble--value (amble--execute
                                     (lambda () (apply fn (append (alist-get 'arguments args) nil))))))
            (buffer . ,(buffer-name)) (tick . ,(buffer-chars-modified-tick)))
        (undo-boundary)))))

(defun amble-tools-eval (args)
  "Evaluate one advanced Elisp expression from ARGS."
  (let* ((code (alist-get 'code args)) (parsed (read-from-string code)))
    (unless (string-match-p "\\`[[:space:]]*\\'" (substring code (cdr parsed)))
      (user-error "Provide a single form; use progn to combine forms"))
    (with-current-buffer (amble--buffer (alist-get 'buffer args))
      (let ((output "") (truncated nil) value)
        (undo-boundary)
        (unwind-protect
            (let ((standard-output (lambda (char)
                                     (if (< (length output) 12000)
                                         (setq output (concat output (char-to-string char)))
                                       (setq truncated t)))))
              (setq value (amble--execute (lambda () (eval (car parsed) t)))))
          (undo-boundary))
        `((value . ,(amble--value value)) (output . ,output)
          (output_truncated . ,(if truncated t :false))
          (buffer . ,(buffer-name)) (tick . ,(buffer-chars-modified-tick)))))))

;; These are model-visible tools, not wrappers around an unconstrained action router.
(amble-tools-register "emacs_context"
                      "Observe compact live editor context, region, windows and running job IDs. detailed=true includes all public buffer metadata. No text is read."
                      '((detailed (type . "boolean"))) nil #'amble-tools-context "observe")
(amble-tools-register "emacs_inspect"
                      "Inspect an existing symbol, actual key binding, or buffer mode. name is required for symbol/key. Variable values are returned only with include_value=true."
                      '((kind (type . "string") (enum . ["symbol" "key" "mode"])) (name (type . "string"))
                        (buffer (type . "string")) (include_value (type . "boolean"))) '("kind") #'amble-tools-inspect "observe")
(amble-tools-register "emacs_search_symbols"
                      "Find installed commands, functions or variables by name fragment, then inspect before calling."
                      '((query (type . "string")) (kind (type . "string") (enum . ["command" "function" "variable" "all"]))) '("query")
                      (lambda (a) (amble-search-symbols (alist-get 'query a) (alist-get 'kind a))) "observe")
(amble-tools-register "emacs_capabilities"
                      "List optional capabilities and active tools. Enable org/git when needed; new tools appear in the next model request. Disable removes them from the active set."
                      '((action (type . "string") (enum . ["list" "enable" "disable"])) (name (type . "string"))) nil #'amble-tools-capabilities "observe")
(amble-tools-register "emacs_find_files"
                      "Find file paths by substring within a local directory/project. Bounded traversal; ignores symlinks and generated directories. Narrow scope if truncated."
                      '((query (type . "string")) (directory (type . "string")) (depth (type . "integer"))
                        (hidden (type . "boolean")) (limit (type . "integer"))) '("query") #'amble-files-find "read")
(amble-tools-register "emacs_search_text"
                      "Search literal text (or regexp=true) in buffer, public buffers, or project files. Live unsaved content takes precedence. Bounded results include line/positions/tick."
                      '((query (type . "string")) (scope (type . "string") (enum . ["buffer" "buffers" "project"]))
                        (buffer (type . "string")) (directory (type . "string")) (regexp (type . "boolean"))
                        (case_sensitive (type . "boolean")) (limit (type . "integer"))) '("query") #'amble-files-search "read")
(amble-tools-register "emacs_read"
                      "Read buffer OR file, preferring unsaved text. Positions are 1-based with exclusive end. Lines are 1-based inclusive. Or set region=true. Returns tick for editing."
                      '((buffer (type . "string")) (file (type . "string")) (start (type . "integer")) (end (type . "integer"))
                        (start_line (type . "integer")) (end_line (type . "integer")) (region (type . "boolean")) (limit (type . "integer"))) nil #'amble-files-read "read")
(amble-tools-register "emacs_edit"
                      "Preview/apply a batch of version-checked edits. changes contains buffer OR file, expected_tick and edits [{start,end,text}]. All offsets refer to pre-edit text; insert uses start=end. Apply is undoable and never saves. undo requires buffer and expected_tick."
                      '((action (type . "string") (enum . ["preview" "apply" "undo"]))
                        (buffer (type . "string")) (file (type . "string")) (expected_tick (type . "integer"))
                        (changes (type . "array")
                                 (items (type . "object")
                                        (properties (buffer (type . "string")) (file (type . "string")) (expected_tick (type . "integer"))
                                                    (edits (type . "array") (items (type . "object")
                                                                                   (properties (start (type . "integer")) (end (type . "integer")) (text (type . "string")))
                                                                                   (required . ["start" "end" "text"]) (additionalProperties . :false))))
                                        (required . ["expected_tick" "edits"]) (additionalProperties . :false))))
                      '("action") #'amble-edit-tool "edit")
(amble-tools-register "emacs_buffers"
                      "Manage live buffers: list/open/create/switch/rename/save/close/clean/restore. open needs file; create/rename need name. save needs expected_tick and destination for a new file. clean requires dry_run. Refuses unsaved/process/invocation buffer closure. rename changes buffer name only."
                      '((action (type . "string") (enum . ["list" "open" "create" "switch" "rename" "save" "close" "clean" "restore"]))
                        (buffer (type . "string")) (file (type . "string")) (name (type . "string")) (destination (type . "string"))
                        (display (type . "boolean")) (expected_tick (type . "integer")) (dry_run (type . "boolean")) (minutes (type . "number")))
                      '("action") #'amble-workspace-buffer-tool "edit")
(amble-tools-register "emacs_windows"
                      "List/show/focus/split/resize/close/only windows, or snapshot/restore a layout. IDs come from list/context. show takes buffer OR file. resize uses signed delta and horizontal. Closing windows preserves buffers."
                      '((action (type . "string") (enum . ["list" "show" "focus" "split" "resize" "close" "only" "snapshot" "restore"]))
                        (window_id (type . "string")) (buffer (type . "string")) (file (type . "string"))
                        (side (type . "string") (enum . ["right" "below" "left" "above"])) (delta (type . "integer"))
                        (horizontal (type . "boolean")) (layout_id (type . "string"))) '("action") #'amble-workspace-window-tool "edit")
(amble-tools-register "emacs_command"
                      "Call an existing function with explicit arguments (array); no call-interactively or minibuffer prompts. Inspect its signature first. Has full Emacs authority; prefer dedicated edit/buffer/window tools."
                      '((function (type . "string")) (arguments (type . "array") (items . t)) (buffer (type . "string")))
                      '("function" "arguments") #'amble-tools-command "execute")
(amble-tools-register "emacs_eval"
                      "Advanced fallback: evaluate one Elisp form (progn for composition). Full Emacs authority, NOT a sandbox. Prefer dedicated tools. Do not block or prompt for input; return concise structured data."
                      '((code (type . "string")) (buffer (type . "string"))) '("code") #'amble-tools-eval "execute")
(amble-tools-register "emacs_job"
                      "Start/status/wait/cancel/list asynchronous local process jobs. start uses command=[program,args...] (no implicit shell), directory and optional timeout (1–3600s). wait suspends model continuation without blocking Emacs. Status output supports offset and limit."
                      '((action (type . "string") (enum . ["start" "status" "wait" "cancel" "list"]))
                        (command (type . "array") (items (type . "string"))) (directory (type . "string"))
                        (timeout (type . "number")) (job_id (type . "string")) (offset (type . "integer")) (limit (type . "integer")))
                      '("action") #'amble-jobs-tool "execute")

(provide 'amble-tools)
;;; amble-tools.el ends here
