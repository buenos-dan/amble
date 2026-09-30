;;; amble-frame.el --- Floating conversation outside the work layout -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "31.1"))
;;; Code:
(require 'amble-core)
(require 'amble-input)

(defvar amble--busy)
(defvar amble-frame--child nil)
(defvar amble-frame--parent nil)

(defcustom amble-frame-width 0.48
  "Conversation width as a fraction of the parent frame."
  :type 'float :group 'amble)
(defcustom amble-frame-height 0.45
  "Conversation height as a fraction of the parent frame."
  :type 'float :group 'amble)

(defun amble-frame-capture-origin ()
  "Remember the work frame and buffer while outside the conversation.
An active request keeps its original work target even if the panel is reopened."
  (unless (or (frame-parameter nil 'amble-conversation)
              (derived-mode-p 'amble-session-mode)
              (minibufferp) (bound-and-true-p amble--busy))
    (setq amble-work-frame (selected-frame)
          amble-origin-buffer (current-buffer))))

(defun amble-frame--work-parent ()
  "Return the live work frame, never substituting an unrelated frame."
  (unless (and (frame-live-p amble-work-frame)
               (not (frame-parameter amble-work-frame 'amble-conversation)))
    (user-error "Open Amble from the work frame to select a task target"))
  amble-work-frame)

(defun amble-frame--fit (parent)
  "Size and position the conversation within PARENT without splitting it."
  (when (and (eq parent amble-frame--parent)
             (frame-live-p amble-frame--child))
    (let* ((pw (frame-pixel-width parent)) (ph (frame-pixel-height parent))
           (width (min (max 180 (- pw 40))
                       (max 360 (floor (* pw (max 0.2 (min 0.95 amble-frame-width)))))))
           (height (min (max 120 (- ph 70))
                        (max 240 (floor (* ph (max 0.2 (min 0.95 amble-frame-height))))))))
      (set-frame-size amble-frame--child width height t)
      (set-frame-position amble-frame--child (max 0 (- pw width 28)) 35))))

(defun amble-frame--conversation-window (frame buffer)
  "Find a live leaf window in FRAME and ensure it displays BUFFER.
The frame root can be an internal layout node after a help buffer splits it."
  (unless (frame-live-p frame)
    (user-error "The Amble frame was closed; open the conversation again"))
  (unless (buffer-live-p buffer)
    (user-error "The Amble buffer was closed; open the conversation again"))
  (let ((window (or (get-buffer-window buffer frame)
                    (car (window-list frame 'no-minibuf)))))
    (unless (window-live-p window)
      (user-error "The Amble frame has no usable conversation window"))
    (unless (eq (window-buffer window) buffer)
      (set-window-dedicated-p window nil)
      (set-window-buffer window buffer)
      (set-window-point window (with-current-buffer buffer (point-max))))
    (set-window-dedicated-p window t)
    window))

(defun amble-frame-display (buffer &optional focus)
  "Show BUFFER in a child frame; FOCUS selects it for interaction."
  (amble-frame-capture-origin)
  (let ((parent (amble-frame--work-parent)))
    (unless (display-graphic-p parent)
      (user-error "Amble's floating conversation requires a graphical Emacs frame"))
    (unless (and (frame-live-p amble-frame--child)
                 (eq amble-frame--parent parent)
                 (eq (frame-parent amble-frame--child) parent))
      (when (frame-live-p amble-frame--child) (delete-frame amble-frame--child t))
      (setq amble-frame--parent parent)
      (setq amble-frame--child
            (make-frame
             `((parent-frame . ,parent) (name . "Amble")
               (amble-conversation . t) (visibility . nil)
               (minibuffer . t) (undecorated . t)
               (no-accept-focus . nil) (no-focus-on-map . t)
               (skip-taskbar . t) (no-other-frame . t)
               (desktop-dont-save . t)
               (menu-bar-lines . 0) (tool-bar-lines . 0)
               (tab-bar-lines . 0) (vertical-scroll-bars . nil)
               (horizontal-scroll-bars . nil)
               (internal-border-width . 10) (child-frame-border-width . 1)
               (drag-internal-border . t) (drag-with-header-line . t)
               (min-width . 20) (min-height . 12)
               (width . 60) (height . 24))))
      (amble-frame--fit parent))
    (let ((child amble-frame--child))
      (amble-frame--conversation-window child buffer)
      (make-frame-visible child)
      (when focus (select-frame-set-input-focus child))
      ;; Visibility/focus hooks can rearrange windows; resolve the leaf again.
      (let ((window (amble-frame--conversation-window child buffer)))
        (when focus
          (select-window window)
          (amble-input-focus))
        window))))

(defun amble-frame-display-buffer (buffer _alist)
  "Route display-buffer requests for BUFFER into the floating conversation."
  (amble-frame-display buffer))

(defun amble-hide ()
  "Hide the floating conversation without cancelling work or altering layout."
  (interactive)
  (let ((focused (eq (selected-frame) amble-frame--child)))
    (when (frame-live-p amble-frame--child)
      (make-frame-invisible amble-frame--child t))
    (when (and focused (frame-live-p amble-frame--parent))
      (select-frame-set-input-focus amble-frame--parent))))

(defun amble-frame--deleted (frame)
  "Forget deleted FRAME references so the panel can be recreated."
  (when (eq frame amble-frame--child) (setq amble-frame--child nil))
  ;; Keep a dead work-frame reference: tool dispatch should stop, not retarget.
  (when (eq frame amble-frame--parent) (setq amble-frame--parent nil)))

(defun amble-frame--buffer-killed ()
  "Hide the panel when its transcript buffer is killed."
  (when (equal (buffer-name) "*amble*") (amble-hide)))

(add-hook 'delete-frame-functions #'amble-frame--deleted)
(add-hook 'window-size-change-functions #'amble-frame--fit)
(add-hook 'kill-buffer-hook #'amble-frame--buffer-killed)

(provide 'amble-frame)
;;; amble-frame.el ends here
