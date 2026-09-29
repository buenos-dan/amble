;;; amble-org.el --- Optional Org capabilities -*- lexical-binding: t; -*-
(require 'amble-tools)
(require 'org)
(require 'org-capture)
(defun amble-org-display (&optional file)
  "Display FILE or the current Org buffer, including inline images."
  (let ((b (if file (find-file-noselect file) (amble--buffer nil))))
    (with-current-buffer b
      (unless (derived-mode-p 'org-mode) (user-error "This is not an Org buffer"))
      (pop-to-buffer b)
      (org-fold-show-all)
      (org-link-preview-region t t)
      (font-lock-ensure)
      `((displayed . ,(buffer-name b))
        (inline_images . ,(cl-count-if
                           (lambda (ov) (eq (car-safe (overlay-get ov 'display)) 'image))
                           (overlays-in (point-min) (point-max))))
        (graphical . ,(if (display-graphic-p) t :false))))))

(defun amble-add-todo (title &optional file)
  "Append TITLE to FILE or the configured Org inbox and display it.
Save when the target had no preexisting unsaved edits."
  (when (or (string-empty-p (string-trim title)) (string-match-p "[\r\n]" title))
    (user-error "A TODO title must be a nonempty single line"))
  (let* ((target (or file amble-todo-file
                     (and org-default-notes-file
                          (file-exists-p org-default-notes-file) org-default-notes-file)
                     (user-error "Set amble-todo-file or provide the user's inbox path")))
         (b (let ((path (amble--local-path target)))
              (unless (file-exists-p path) (user-error "Inbox does not exist; configure an existing Org inbox"))
              (let ((enable-local-variables :safe) (enable-local-eval nil))
                (find-file-noselect path)))))
    (with-current-buffer b
      (unless (derived-mode-p 'org-mode) (user-error "Target must be an Org file"))
      (let ((was-modified (buffer-modified-p)) start)
        (save-restriction
          (widen)
          (goto-char (point-max))
          (atomic-change-group
            (unless (bolp) (insert "\n"))
            (setq start (point))
            (insert "* TODO " (string-trim title) "\n")))
        (undo-boundary)
        (unless was-modified (save-buffer))
        (pop-to-buffer b)
        (goto-char start)
        `((file . ,buffer-file-name) (title . ,(string-trim title))
          (point . ,start) (saved . ,(if was-modified :false t)))))))

(defun amble-org--templates ()
  "Return capture template names without exposing template bodies or targets."
  (vconcat (cl-loop for template in org-capture-templates
                    when (and (stringp (car template)) (nth 2 template))
                    collect `((key . ,(car template)) (description . ,(nth 1 template))
                              (type . ,(symbol-name (nth 2 template)))))))

(defun amble-org--capture (key title)
  "Capture TITLE through an existing entry template KEY, preserving its target."
  (let ((template (assoc key org-capture-templates)) success)
    (unless (and template (eq (nth 2 template) 'entry))
      (user-error "Select an existing entry capture template from templates"))
    (when (plist-get (nthcdr 5 template) :immediate-finish)
      (user-error "This template finalizes immediately; use a template with an editable capture step"))
    (when (and (stringp (nth 4 template))
               (string-match-p "%\\^" (nth 4 template)))
      (user-error "This template needs interactive fields; ask the user to capture manually"))
    (let ((org-capture-initial title))
      (unwind-protect
          (amble--execute
           (lambda ()
             (org-capture nil key)
             (unless (bound-and-true-p org-capture-mode)
               (user-error "Capture template finalized immediately; inspect its target before retrying"))
             (unless (and (stringp (nth 4 template)) (string-match-p "%i" (nth 4 template)))
               (insert title))
             (org-capture-finalize)
             (setq success t)
             `((captured . t) (template . ,key) (title . ,title))))
        (when (and (not success) (bound-and-true-p org-capture-mode)) (org-capture-kill))))))

(defun amble-org-tool (args)
  "Dispatch optional Org capabilities using ARGS."
  (pcase (alist-get 'action args)
    ("templates" `((templates . ,(amble-org--templates)) (todo_file . ,amble-todo-file)))
    ("capture"
     (unless (and (alist-get 'template args) (alist-get 'title args))
       (user-error "capture requires template and title"))
     (amble-org--capture (alist-get 'template args) (alist-get 'title args)))
    ("display" (amble-org-display (alist-get 'file args)))
    ("add_todo"
     (unless (alist-get 'title args) (user-error "add_todo requires title"))
     (amble-add-todo (alist-get 'title args) (alist-get 'file args)))
    (_ (user-error "Unknown Org action"))))

(amble-tools-register
 "emacs_org"
 "Org extension: templates lists existing capture keys. Prefer capture with an entry template and title; fails if input is needed. display shows an Org file with images. add_todo is a fallback for the configured inbox or an explicit existing Org file; saves only when no prior unsaved changes existed."
 '((action (type . "string") (enum . ["templates" "capture" "display" "add_todo"]))
   (template (type . "string")) (title (type . "string")) (file (type . "string")))
 '("action") #'amble-org-tool "org" "org")
(provide 'amble-org)
;;; amble-org.el ends here
