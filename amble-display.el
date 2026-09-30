;;; amble-display.el --- Conversation rendering and folding -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "31.1"))
;;; Code:
(require 'amble-input)
(require 'json)

(defvar amble-model)
(defvar amble--busy)
(defvar amble--waiting-job)
(defvar amble--waiting-retry)
(defvar amble--run-stats)

(defun amble--stats-text (stats)
  "Format logical model turns, tool calls and model time from STATS."
  (let ((turns (plist-get stats :turns)) (calls (plist-get stats :tools))
        (seconds (plist-get stats :seconds)))
    (when-let* ((start (plist-get stats :request-started)))
      (setq seconds (+ seconds (max 0 (- (float-time) start)))))
    (format "%d turn%s · %d tool call%s · %.1fs"
            turns (if (= turns 1) "" "s") calls (if (= calls 1) "" "s") seconds)))

(defun amble--update-process-caption (section)
  "Refresh SECTION's metrics without changing its expanded state."
  (when-let* ((button (button-at (overlay-get section 'amble-header))))
    (with-silent-modifications
      (let ((stats (overlay-get section 'amble-run-stats))
            (calls (overlay-get section 'amble-call-count)))
	(button-put button 'amble-caption
                    (concat (if stats (amble--stats-text stats)
                              (format "%d tool call%s" calls (if (= calls 1) "" "s")))
                            (when (overlay-get section 'amble-has-error) " · failed")))
	(button-put button 'help-echo
                    "TAB/RET/click: details. Retries do not add turns. Seconds include request retries, but exclude backoff and jobs.")
	(button-put button 'display
                    (concat (if (overlay-get section 'invisible) "▶ " "▼ ")
                            (button-get button 'amble-caption)))))))

(defun amble--refresh-stats (stats)
  "Update all transcript sections associated with STATS."
  (when-let* ((buffer (get-buffer "*amble*")))
    (with-current-buffer buffer
      (dolist (overlay (overlays-in (point-min) (point-max)))
        (when (and (overlay-get overlay 'amble-process)
                   (eq (overlay-get overlay 'amble-run-stats) stats))
          (amble--update-process-caption overlay)))))
  (force-mode-line-update t))

(defvar-local amble--display-ready nil)
(defvar-local amble--process-section nil)

(define-button-type 'amble-details-button
  'follow-link t
  'help-echo "TAB, RET or click to expand/collapse details"
  'action #'amble--toggle-details-button)

(defun amble--set-details-folded (button folded)
  "Set BUTTON's detail visibility according to FOLDED."
  (let ((body (button-get button 'amble-details)))
    (when (and folded (<= (overlay-start body) (point))
               (< (point) (overlay-end body)))
      (goto-char (button-start button)))
    (overlay-put body 'invisible (and folded 'amble-details))
    (with-silent-modifications
      (button-put button 'display
                  (concat (if folded "▶ " "▼ ")
                          (or (button-get button 'amble-caption)
                              (button-get button 'amble-entry)))))))

(defun amble--reveal-details (overlay)
  "Reveal OVERLAY and any enclosing execution section during search."
  (dolist (item (cons overlay (overlays-at (overlay-start overlay))))
    (when-let* ((header (overlay-get item 'amble-header))
                (button (button-at header)))
      (amble--set-details-folded button nil))))

(defun amble--toggle-details-button (button)
  "Toggle the details associated with BUTTON."
  (amble--set-details-folded
   button (not (overlay-get (button-get button 'amble-details) 'invisible))))

(defun amble-toggle-details ()
  "Toggle the current tool or result block, or move to the next one."
  (interactive)
  (let ((button (or (button-at (point))
                    (cl-some (lambda (overlay)
                               (when-let* ((header (overlay-get overlay 'amble-header)))
                                 (button-at header)))
                             (sort (overlays-at (point))
                                   (lambda (a b)
                                     (< (- (overlay-end a) (overlay-start a))
                                        (- (overlay-end b) (overlay-start b)))))))))
    (if (and button (button-get button 'amble-details))
        (amble--toggle-details-button button)
      (forward-button 1 t nil t))))

(defun amble--pretty-details (text)
  "Format JSON TEXT with two-space indentation, preserving non-JSON text."
  (with-temp-buffer
    (insert text)
    (let ((json-encoding-default-indentation "  ")
          (inhibit-message t) (message-log-max nil))
      (condition-case nil
          (progn (json-pretty-print-buffer) (buffer-string))
        (error text)))))

(defun amble--tool-entry-p (label)
  "Whether LABEL identifies a tool call or its result."
  (or (string-prefix-p "Tool · " label)
      (string-prefix-p "Result" label)
      (string-prefix-p "Tool error" label)))

(defun amble--compact-tool-gap (boundary)
  "Hide the separator before a tool heading at BOUNDARY, retaining log text."
  (when (and (> boundary (1+ (point-min)))
             (eq (char-before boundary) ?\n)
             (eq (char-before (1- boundary)) ?\n)
             (not (cl-some (lambda (overlay) (overlay-get overlay 'amble-spacing))
                           (overlays-at (1- boundary)))))
    (let ((gap (make-overlay (1- boundary) boundary nil nil nil)))
      (overlay-put gap 'amble-spacing t)
      (overlay-put gap 'invisible 'amble-spacing))))

(defun amble--make-details (start body-start end label face &optional expanded)
  "Create a folding heading at START for BODY-START..END.
Use LABEL and FACE for the heading; EXPANDED controls its initial state."
  (let* ((body (make-overlay body-start end))
         (button (make-text-button start (1- body-start)
                                   'type 'amble-details-button 'amble-entry label
                                   'amble-details body 'face face)))
    (overlay-put body 'amble-header (copy-marker start t))
    (overlay-put body 'isearch-open-invisible #'amble--reveal-details)
    (amble--set-details-folded button (not expanded))
    body))

(defun amble--make-process-section (start body-start)
  "Make the execution heading at START control a section at BODY-START."
  (let ((body (amble--make-details start body-start body-start
                                   "Activity" 'font-lock-comment-face)))
    (overlay-put body 'amble-process t)
    (overlay-put body 'amble-call-count 0)
    (overlay-put body 'amble-run-stats (get-text-property start 'amble-run-stats))
    body))

(defun amble--insert-process-section (&optional stats)
  "Insert a collapsed execution heading at point and return its overlay."
  (let ((start (point)))
    (insert (propertize "Activity\n" 'amble-entry "Activity"
                        'amble-process-header t 'amble-run-stats stats 'rear-nonsticky t))
    (amble--make-process-section start (point))))

(defun amble--extend-process-section (section end label)
  "Extend SECTION through END and account for entry LABEL."
  (move-overlay section (overlay-start section) end)
  (when (string-prefix-p "Tool · " label)
    (overlay-put section 'amble-call-count
                 (1+ (overlay-get section 'amble-call-count))))
  (when (string-prefix-p "Tool error" label)
    (overlay-put section 'amble-has-error t))
  (amble--update-process-caption section))

(defun amble--fold-entry (start body-start end label)
  "Make an entry at START with body BODY-START..END and LABEL foldable."
  (when (and (< body-start end)
             (amble--tool-entry-p label)
             (not (button-at start)))
    (let* ((text (buffer-substring-no-properties body-start end))
           (formatted (amble--pretty-details text)))
      (unless (equal text formatted)
        (save-excursion
          (goto-char body-start)
          (delete-region body-start end)
          (insert formatted)
          (setq end (point)))))
    (let ((failed (string-prefix-p "Tool error" label)))
      (amble--make-details start body-start end label
                           (if failed 'warning 'font-lock-keyword-face) failed))))

(defun amble-refresh-display ()
  "Rebuild transcript folding and formatting without reading the unsent draft."
  (interactive)
  (when-let* ((buffer (get-buffer "*amble*")))
    (with-current-buffer buffer
      (amble-input--with-history #'amble--refresh-transcript))))

(defun amble--refresh-transcript ()
  "Rebuild folding in one pass using the transcript's explicit entry markers."
  (let ((inhibit-read-only t) section previous)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let* ((start (point))
               (label (get-text-property start 'amble-entry))
               (body-start (next-single-property-change start 'amble-entry nil (point-max)))
               (next (copy-marker
                      (if label
                          (next-single-property-change body-start 'amble-entry nil (point-max))
                        body-start) t)))
          (unwind-protect
              (when label
                (cond
                 ((get-text-property start 'amble-process-header)
                  (setq section (or (when-let* ((button (button-at start)))
                                      (button-get button 'amble-details))
                                    (amble--make-process-section start body-start)))
                  (overlay-put section 'amble-call-count 0)
                  (overlay-put section 'amble-has-error nil))
                 (t
                  (amble--fold-entry start body-start (1- next) label)
                  (when (and previous (amble--tool-entry-p previous)
                             (amble--tool-entry-p label))
                    (amble--compact-tool-gap start))
                  (if (get-text-property start 'amble-intermediate)
                      (when section (amble--extend-process-section section (1- next) label))
                    (setq section nil))))
                (setq previous label))
            (goto-char next)
            (set-marker next nil)))))
    (setq amble--process-section (and amble--busy section)
          amble--display-ready t)))

(define-derived-mode amble-session-mode text-mode "Amble"
  "Conversation and draft in one buffer. C-c C-c sends; RET inserts a newline."
  (setq-local truncate-lines nil word-wrap t)
  (add-to-invisibility-spec 'amble-details)
  (add-to-invisibility-spec 'amble-spacing)
  (setq-local header-line-format
              '(:eval (format " Amble · %s · %s · C-c C-c send"
                              amble-model
                              (cond (amble--waiting-job "等待后台任务")
                                    (amble--waiting-retry "等待重试")
                                    (amble--busy "working")
                                    (t "ready")))))
  (amble-input-setup)
  (amble-input-setup-keys))

(defun amble--log (label text &optional intermediate)
  "Insert a transcript entry above the draft, preserving typing and history view."
  (with-current-buffer (amble-input-buffer)
    (unless amble--display-ready (amble-refresh-display))
    (amble-input--with-history
     (lambda () (amble--log-entry label text intermediate)))))

(defun amble--log-entry (label text &optional intermediate)
  "Append LABEL and TEXT; group INTERMEDIATE text with the turn's tools."
  (with-current-buffer (get-buffer-create "*amble*")
    (let ((inhibit-read-only t)
          (following (cl-remove-if-not
                      (lambda (w) (and (window-live-p w)
                                       (<= (1- (point-max)) (window-point w) (point-max))))
                      (get-buffer-window-list (current-buffer) nil t))))
      (goto-char (point-max))
      (when (amble--tool-entry-p label)
        (let* ((end (previous-single-property-change
                     (point) 'amble-entry nil (point-min)))
               (previous (and (> end (point-min))
                              (get-text-property (1- end) 'amble-entry))))
          (when (and previous (amble--tool-entry-p previous))
            (amble--compact-tool-gap (point)))))
      (setq intermediate (and (or intermediate (amble--tool-entry-p label)) t))
      (if intermediate
          (unless (and (overlayp amble--process-section)
                       (overlay-buffer amble--process-section))
            (setq amble--process-section (amble--insert-process-section amble--run-stats)))
        (setq amble--process-section nil))
      (let ((start (point)) body-start)
        (insert (propertize (concat label "\n") 'face 'font-lock-keyword-face
                            'amble-entry label 'amble-intermediate intermediate
                            'amble-run-stats (and (equal label "You") amble--run-stats)
                            'rear-nonsticky t))
        (setq body-start (point))
        (insert text "\n\n")
        (amble--fold-entry start body-start (1- (point)) label))
      (when intermediate
        (amble--extend-process-section amble--process-section (1- (point-max)) label))
      (dolist (w following)
        (when (window-live-p w) (set-window-point w (point-max)))))))

(provide 'amble-display)
;;; amble-display.el ends here
