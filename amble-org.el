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

(declare-function amble-zk--require "amble-zk")
(declare-function amble-zk-tool "amble-zk" (args))
(defvar zk-inbox-file)

(defun amble-add-todo (title &optional file)
  "Compatibility entry point: capture TITLE through zk's shared inbox."
  (require 'amble-zk)
  (amble-zk--require)
  (when (and file (not (equal (expand-file-name file) (expand-file-name zk-inbox-file))))
    (user-error "Tasks use zk-inbox-file; Amble has no separate TODO destination"))
  (amble-zk-tool `((action . "add_task") (title . ,title))))

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
    ("templates" `((templates . ,(amble-org--templates))))
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
 "Org document extension: templates lists capture keys; capture applies a generic entry template. display shows an Org file with images. For tasks, plans and schedules enable zk and use emacs_zk. add_todo is a compatibility alias that delegates to zk; it never writes to a separate inbox."
 '((action (type . "string") (enum . ["templates" "capture" "display" "add_todo"]))
   (template (type . "string")) (title (type . "string")) (file (type . "string")))
 '("action") #'amble-org-tool "org" "org")
(provide 'amble-org)
;;; amble-org.el ends here
