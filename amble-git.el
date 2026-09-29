;;; amble-git.el --- Optional asynchronous Git capabilities -*- lexical-binding: t; -*-
(require 'amble-tools)

(defun amble-git-tool (args)
  "Start a read-only Git status or diff job from ARGS."
  (let* ((directory (amble--directory (alist-get 'directory args)))
         (root (locate-dominating-file directory ".git"))
         (command (list "git" "--no-pager")))
    (unless root (user-error "Not a Git working tree"))
    (setq command
          (append command
                  (pcase (alist-get 'action args)
                    ("status" '("status" "--short" "--branch"))
                    ("diff" (append '("diff" "--no-ext-diff" "--no-textconv" "--no-color")
                                    (when (eq t (alist-get 'staged args)) '("--cached")) '("--")))
                    (_ (user-error "Unknown Git action")))))
    (let* ((result (amble-jobs-start command root 60))
           (buffer (get-buffer (alist-get 'buffer result))))
      (when (and buffer (equal (alist-get 'action args) "diff"))
        (with-current-buffer buffer (diff-mode) (setq buffer-read-only t)))
      (when buffer (display-buffer buffer))
      result)))

(amble-tools-register
 "emacs_git"
 "Git extension: start an asynchronous status/diff job and display native output. diff defaults to unstaged; staged=true selects staged. Use emacs_job wait for completion. No commits or working-tree mutations."
 '((action (type . "string") (enum . ["status" "diff"]))
   (directory (type . "string")) (staged (type . "boolean")))
 '("action") #'amble-git-tool "git" "git")
(provide 'amble-git)
;;; amble-git.el ends here
