;;; amble-zk.el --- Delegate planning to zk -*- lexical-binding: t; -*-

(require 'amble-tools)
(defvar zk-inbox-file)
(defvar zk-agenda-file)
(declare-function zk-capture-task "zk" (title &optional scheduled deadline))
(declare-function zk-capture-plan "zk" (title &optional body))
(declare-function zk-list-tasks "zk")
(declare-function zk-update-task "zk" (file position expected-tick &optional state scheduled deadline))

(defun amble-zk--require ()
  "Load the installed zk package; never create a separate Amble inbox."
  (unless (require 'zk nil t)
    (user-error "Install and configure zk to manage tasks, plans and schedules")))

(defun amble-zk--result (record)
  "Convert a zk capture/update result to a tool response."
  `((file . ,(plist-get record :file)) (point . ,(plist-get record :point))
    (title . ,(plist-get record :title)) (state . ,(plist-get record :state))
    (saved . ,(if (plist-get record :saved) t :false))
    (tick . ,(plist-get record :tick))))

(defun amble-zk-tool (args)
  "Dispatch planning actions to zk; storage and Org semantics belong to zk."
  (amble-zk--require)
  (pcase (alist-get 'action args)
    ("info" `((inbox . ,zk-inbox-file) (agenda . ,zk-agenda-file)))
    ("tasks"
     (let* ((tasks (zk-list-tasks)) (offset (or (alist-get 'offset args) 0))
            (limit (amble--limit (alist-get 'limit args) 50 200)))
       (unless (and (integerp offset) (>= offset 0)) (user-error "offset must be nonnegative"))
       `((total . ,(length tasks))
         (tasks . ,(vconcat
                     (mapcar (lambda (task)
                               `((title . ,(plist-get task :title)) (state . ,(plist-get task :state))
                                 (scheduled . ,(plist-get task :scheduled)) (deadline . ,(plist-get task :deadline))
                                 (file . ,(plist-get task :file)) (point . ,(plist-get task :point))
                                 (tick . ,(plist-get task :tick))))
                             (seq-take (nthcdr offset tasks) limit)))))))
    ("add_task"
     (amble-zk--result (zk-capture-task (alist-get 'title args)
                                      (alist-get 'scheduled args) (alist-get 'deadline args))))
    ("add_plan"
     (amble-zk--result (zk-capture-plan (alist-get 'title args) (alist-get 'body args))))
    ("update_task"
     (unless (and (stringp (alist-get 'file args)) (integerp (alist-get 'point args))
                  (integerp (alist-get 'expected_tick args)))
       (user-error "List tasks first; update_task needs file, point and expected_tick"))
     (amble-zk--result (zk-update-task (alist-get 'file args) (alist-get 'point args)
                                     (alist-get 'expected_tick args) (alist-get 'state args)
                                     (alist-get 'scheduled args) (alist-get 'deadline args))))
    ("view"
     (let ((command (cdr (assoc (alist-get 'view args)
                                '(("home" . zk-home) ("inbox" . zk-open-inbox)
                                  ("agenda" . zk-open-agenda) ("today" . zk-today)
                                  ("week" . zk-week) ("daily" . zk-daily) ("weekly" . zk-weekly))))))
       (unless command (user-error "Choose a zk view"))
       (funcall command)
       `((view . ,(alist-get 'view args)) (buffer . ,(buffer-name)))))
    (_ (user-error "Unknown zk action"))))

(amble-tools-register
 "emacs_zk"
 "Tasks, plans and schedules via zk. info returns its shared files; tasks lists live open tasks with file/point/tick. add_task captures in the zk inbox; add_plan writes to the zk agenda. update_task needs a fresh expected_tick from tasks. Optional dates use YYYY-MM-DD or YYYY-MM-DD HH:MM; omit unspecified dates, use an empty string to remove one. Never invent a time or deadline. view opens a zk screen or date heading. saved=false means earlier unsaved edits were preserved; do not retry the capture."
 '((action (type . "string") (enum . ["info" "tasks" "add_task" "add_plan" "update_task" "view"]))
   (title (type . "string")) (body (type . "string"))
   (scheduled (type . "string")) (deadline (type . "string")) (state (type . "string"))
   (file (type . "string")) (point (type . "integer")) (expected_tick (type . "integer"))
   (offset (type . "integer")) (limit (type . "integer"))
   (view (type . "string") (enum . ["home" "inbox" "agenda" "today" "week" "daily" "weekly"])))
 '("action") #'amble-zk-tool "zk" "zk")

(provide 'amble-zk)
;;; amble-zk.el ends here
