;;; amble-files.el --- Bounded local discovery and live reads -*- lexical-binding: t; -*-
(require 'amble-core)

(defcustom amble-search-ignored-directories
  '(".git" "node_modules" ".venv" "venv" "__pycache__" "eln-cache" "target" "dist")
  "Directories skipped by native file discovery."
  :type '(repeat string) :group 'amble)

(defun amble-files--walk (root depth hidden limit)
  "Collect at most LIMIT local files below ROOT to DEPTH, without symlinks."
  (let ((queue (list (cons root 0))) files (visited 0) truncated skipped
        (deadline (+ (float-time) 0.4)))
    (while (and queue (< visited 3000) (< (length files) limit)
                (< (float-time) deadline))
      (pcase-let ((`(,dir . ,level) (pop queue)))
        (condition-case nil
            (let ((entries (directory-files dir t directory-files-no-dot-files-regexp t 301)))
              (when (> (length entries) 300) (setq truncated t entries (seq-take entries 300)))
              (dolist (file entries)
                (cl-incf visited)
                (let ((name (file-name-nondirectory file)))
                  (unless (or (file-symlink-p file)
                              (and (not hidden) (string-prefix-p "." name)))
                    (cond
                     ((file-directory-p file)
                      (cond ((member name amble-search-ignored-directories) nil)
                            ((< level depth) (push (cons file (1+ level)) queue))
                            (t (setq truncated t))))
                     ((and (file-regular-p file) (< (length files) limit))
                      (push file files))
                     ((file-regular-p file) (setq truncated t)))))))
          (file-error (push dir skipped)))))
    `((files . ,(nreverse files))
      (truncated . ,(if (or queue truncated) t :false))
      (skipped . ,(vconcat skipped)))))

(defun amble-files-find (args)
  "Find filenames using bounded local traversal described by ARGS."
  (let* ((root (amble--directory (alist-get 'directory args)))
         (query (downcase (or (alist-get 'query args) "")))
         (depth (or (alist-get 'depth args) 4))
         (limit (amble--limit (alist-get 'limit args) 50 200)))
    (unless (and (integerp depth) (<= 0 depth 12)) (user-error "Depth must be 0–12"))
    (let* ((walk (amble-files--walk root depth (eq t (alist-get 'hidden args)) 2000))
           (matches (cl-remove-if-not
                     (lambda (path) (string-match-p (regexp-quote query)
                                                    (downcase (file-relative-name path root))))
                     (alist-get 'files walk))))
      `((root . ,root) (matches . ,(vconcat (seq-take matches limit)))
        (truncated . ,(if (or (eq t (alist-get 'truncated walk)) (> (length matches) limit)) t :false))
        (skipped . ,(alist-get 'skipped walk))
        (hint . "If truncated, narrow directory/query or use an asynchronous job for a large search.")))))

(defun amble-files-read (args)
  "Read live buffer text by positions, lines or active region using ARGS."
  (when-let* ((file (alist-get 'file args)))
    (let ((path (amble--local-path file)))
      (unless (or (find-buffer-visiting path) (file-regular-p path))
        (user-error "File does not exist: %s" path))
      (when (and (not (find-buffer-visiting path))
                 (> (file-attribute-size (file-attributes path)) (* 2 1024 1024)))
        (user-error "File exceeds 2 MiB; open explicitly or use an asynchronous job"))))
  (with-current-buffer (amble--target args t)
    (save-excursion
      (let* ((limit (amble--limit (alist-get 'limit args) 16000 48000))
             (region (eq t (alist-get 'region args)))
             (line (alist-get 'start_line args))
             (last-line (alist-get 'end_line args))
             (lo (or (alist-get 'start args) (point-min)))
             (hi (or (alist-get 'end args) (point-max))))
        (when (and (or line last-line) (or (alist-get 'start args) (alist-get 'end args) region))
          (user-error "Choose positions, lines or region, not a mixture"))
        (when (and region (or (alist-get 'start args) (alist-get 'end args)))
          (user-error "Choose positions or region"))
        (when (or line last-line)
          (setq line (or line 1))
          (unless (and (integerp line) (> line 0)
                       (or (null last-line) (and (integerp last-line) (>= last-line line))))
            (user-error "Invalid line range"))
          (goto-char (point-min))
          (unless (zerop (forward-line (1- line))) (user-error "Start line is beyond the buffer"))
          (setq lo (point))
          (when last-line (forward-line (1+ (- last-line line))) (setq hi (point))))
        (when region
          (unless (use-region-p) (user-error "No active region in this buffer"))
          (setq lo (region-beginning) hi (region-end)))
        (unless (and (integerp lo) (integerp hi) (<= (point-min) lo hi (point-max)))
          (user-error "Invalid accessible buffer range"))
        (let ((end (min hi (+ lo limit))))
          `((buffer . ,(buffer-name)) (file . ,buffer-file-name)
            (start . ,lo) (end . ,end) (start_line . ,(line-number-at-pos lo))
            (tick . ,(buffer-chars-modified-tick)) (modified . ,(if (buffer-modified-p) t :false))
            (truncated . ,(if (< end hi) t :false))
            (next_start . ,(when (< end hi) end))
            (text . ,(buffer-substring-no-properties lo end))))))))

(defun amble-files--matches (regexp limit deadline source)
  "Search current buffer for REGEXP with LIMIT and DEADLINE, returning SOURCE data."
  (let (matches)
    (save-excursion
      (goto-char (point-min))
      (while (and (< (length matches) limit) (< (float-time) deadline)
                  (re-search-forward regexp nil t))
        (let ((start (match-beginning 0)) (end (match-end 0)))
          (push (append source
                        `((start . ,start) (end . ,end) (line . ,(line-number-at-pos start))
                          (text . ,(buffer-substring-no-properties
                                    (line-beginning-position) (min (line-end-position) (+ (line-beginning-position) 300))))))
                matches)
          (when (= start end) (if (eobp) (goto-char (point-max)) (forward-char)))
          ;; An empty regexp at eob cannot make further progress.
          (when (eobp) (goto-char (point-max)) (setq limit (length matches))))))
    (nreverse matches)))

(defun amble-files-search (args)
  "Search text in live buffers or a bounded local project using ARGS."
  (let* ((query (alist-get 'query args))
         (regexp (if (eq t (alist-get 'regexp args)) query (regexp-quote query)))
         (scope (or (alist-get 'scope args) "buffer"))
         (limit (amble--limit (alist-get 'limit args) 50 200))
         (case-fold-search (not (eq t (alist-get 'case_sensitive args))))
         (deadline (+ (float-time) 0.6))
         (root (when (equal scope "project") (amble--directory (alist-get 'directory args))))
         sources matches skipped truncated)
    (when (string-empty-p query) (user-error "Search query cannot be empty"))
    (string-match-p regexp "") ; Validate before reading files.
    (pcase scope
      ("buffer" (setq sources (list (amble--target args))))
      ("buffers" (setq sources (cl-remove-if-not #'amble--context-buffer-p (buffer-list))))
      ("project"
       (let ((walk (amble-files--walk root 8 nil 500)))
         (setq sources (alist-get 'files walk) truncated (eq t (alist-get 'truncated walk))
               skipped (append (alist-get 'skipped walk) nil)))
       ;; Unsaved files and text in live buffers take precedence over disk.
       (dolist (buffer (buffer-list))
         (with-current-buffer buffer
           (when (and buffer-file-name (not (file-remote-p buffer-file-name))
                      (file-in-directory-p buffer-file-name root) (amble--context-buffer-p buffer))
             (setq sources (cons buffer (delete buffer-file-name sources)))))))
      (_ (user-error "Unknown search scope")))
    (while (and sources (< (length matches) limit) (< (float-time) deadline))
      (let* ((source (pop sources))
             (live (if (bufferp source) source (find-buffer-visiting source))))
        (condition-case nil
            (setq matches
                  (nconc matches
                         (if live
                             (with-current-buffer live
                               (amble-files--matches regexp (- limit (length matches)) deadline
                                                     `((buffer . ,(buffer-name)) (file . ,buffer-file-name)
                                                       (tick . ,(buffer-chars-modified-tick)))))
                           (if (> (file-attribute-size (file-attributes source)) (* 512 1024))
                               (progn (push source skipped) nil)
                             (with-temp-buffer
                               (insert-file-contents source)
                               (if (save-excursion (goto-char (point-min)) (search-forward "\0" nil t))
                                   (progn (push source skipped) nil)
                                 (amble-files--matches regexp (- limit (length matches)) deadline
                                                       `((file . ,source) (source . "disk")))))))))
          (file-error (push (if (bufferp source) (buffer-name source) source) skipped)))))
    `((matches . ,(vconcat matches)) (root . ,root)
      (truncated . ,(if (or sources truncated (>= (length matches) limit) (>= (float-time) deadline)) t :false))
      (skipped . ,(vconcat skipped))
      (hint . "Positions and ticks refer to live buffers; read disk hits before editing. Narrow scope when truncated."))))

(provide 'amble-files)
;;; amble-files.el ends here
