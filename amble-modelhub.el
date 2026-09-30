;;; amble-modelhub.el --- Asynchronous ModelHub transport -*- lexical-binding: t; -*-

;; Version: 0.3.6
;; Package-Requires: ((emacs "31.1"))

;;; Commentary:
;; Native HTTPS for the Responses API.  This module never executes tools.
;; Callbacks run from timers, outside URL process filters.  Cancelling a handle
;; invalidates both network callbacks and events already waiting for delivery.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'time-date)

(cl-defstruct (amble-modelhub--request (:constructor amble-modelhub--make))
  data key endpoint callback observer (active t) (started (float-time))
  buffer timer attempt event delivery recovered-input
  (retry-count 0) retry-timer notice-timer (attempt-count 0))

(defun amble-modelhub--json (value)
  "Encode VALUE as multibyte JSON text, preserving objects, arrays and booleans.
Decode the UTF-8 bytes returned by `json-serialize' before combining with text."
  (decode-coding-string
   (json-serialize value :null-object nil :false-object :false) 'utf-8-unix))

(defun amble-modelhub--parse (text)
  "Parse JSON TEXT, preserving the distinction between {} and []."
  (json-parse-string text :object-type 'hash-table :array-type 'array
                     :null-object nil :false-object :false))

(defun amble-modelhub--get (key value)
  "Read string KEY from a JSON object VALUE, or return nil."
  (when (hash-table-p value) (gethash key value)))

(defun amble-modelhub--id ()
  "Return a fresh identifier for a request."
  (substring (secure-hash 'sha256
                          (format "%s:%s:%s" (float-time) (random) (emacs-pid)))
             0 32))

(defun amble-modelhub--read-key ()
  "Read the API key exclusively from EMACS_AMBLE_API_KEY."
  (let ((key (string-trim (or (getenv "EMACS_AMBLE_API_KEY") ""))))
    (when (string-empty-p key)
      (user-error "Set EMACS_AMBLE_API_KEY in the environment used to start Emacs"))
    key))

(defun amble-modelhub--endpoint (endpoint)
  "Validate ENDPOINT and resolve the Responses URL.
Accept either a base URL or the complete /responses URL."
  (unless (and (stringp endpoint)
               (not (string-match-p "[?#[:space:]]" endpoint))
               (let ((url (url-generic-parse-url endpoint)))
                 (and (equal (url-type url) "https")
                      (not (string-empty-p (or (url-host url) "")))
                      (not (url-user url)) (not (url-password url)))))
    (error "Endpoint must be HTTPS without credentials, query or fragment"))
  (setq endpoint (string-remove-suffix "/" endpoint))
  (if (string-suffix-p "/responses" endpoint) endpoint
    (concat endpoint "/responses")))

(defun amble-modelhub--redact (handle text)
  "Remove HANDLE's raw and URL-encoded key from diagnostic TEXT."
  (let ((key (amble-modelhub--request-key handle)))
    (when (and key (not (string-empty-p key)))
      (dolist (secret (list key (url-hexify-string key)))
        (setq text (replace-regexp-in-string
                    (regexp-quote secret) "[REDACTED]" text t t))))
    (truncate-string-to-width text 2000 nil nil "…")))

(defun amble-modelhub--payload (handle)
  "Build a stateless Responses API request for HANDLE."
  (let* ((data (amble-modelhub--request-data handle))
         (payload `((model . ,(alist-get 'model data))
                    (input . ,(alist-get 'input data))
                    (stream . :false) (store . :false)
                    (include . ["reasoning.encrypted_content"]))))
    (when (alist-get 'reasoning data)
      (setf (alist-get 'reasoning payload) (alist-get 'reasoning data)))
    (when (alist-get 'max_output_tokens data)
      (setf (alist-get 'max_output_tokens payload) (alist-get 'max_output_tokens data)))
    (when (> (length (alist-get 'tools data)) 0)
      (setq payload (append payload `((tools . ,(alist-get 'tools data))
                                      (tool_choice . "auto")))))
    payload))

(defun amble-modelhub--header-bytes (text)
  "Encode printable ASCII header TEXT as unibyte data.
Even an ASCII-only multibyte header promotes UTF-8 body bytes when url.el
concatenates the request, causing its multibyte-request check to fail."
  (when (string-match-p "[^ -~]" text)
    (error "ModelHub HTTP headers must contain printable ASCII"))
  (encode-coding-string text 'us-ascii))

(defun amble-modelhub--invalid-reasoning-p (body)
  "Recognize the specific encrypted-state validation error in HTTP BODY."
  (condition-case nil
      (let* ((failure (amble-modelhub--get "error" (amble-modelhub--parse body)))
             (code (amble-modelhub--get "code" failure))
             (message (amble-modelhub--get "message" failure)))
        (or (equal code "invalid_encrypted_content")
            ;; ModelHub wraps the upstream code inside its error message.
            (and (equal code "-4003") (stringp message)
                 (string-match-p
                  "\\`code: invalid_encrypted_content;" message))))
    (error nil)))

(defun amble-modelhub--recover-reasoning (handle body)
  "Retry HANDLE once after a rejected reasoning state described in BODY.
Preserve every message, function call and tool result.  Only opaque reasoning
items are omitted; no completed Emacs tool is executed again by this retry."
  (when (and (not (amble-modelhub--request-recovered-input handle))
             (amble-modelhub--invalid-reasoning-p body))
    (let* ((data (amble-modelhub--request-data handle))
           (input (alist-get 'input data))
           (clean (vconcat
                   (cl-remove-if
                    (lambda (item)
                      (equal (if (hash-table-p item) (gethash "type" item)
                               (alist-get 'type item))
                             "reasoning"))
                    (append input nil)))))
      (when (< (length clean) (length input))
        (setf (amble-modelhub--request-recovered-input handle) clean)
        (setf (alist-get 'input data) clean)
        (setf (amble-modelhub--request-started handle) (float-time))
        (amble-modelhub--post handle (amble-modelhub--payload handle))
        t))))

(defun amble-modelhub--observe (handle event)
  "Report request telemetry EVENT to HANDLE's optional observer.
Telemetry must not interrupt network processing or disclose request content."
  (when-let* ((observer (amble-modelhub--request-observer handle)))
    (let ((inhibit-message t) (message-log-max nil))
      (condition-case nil (funcall observer event) (error nil)))))

(defun amble-modelhub--close (handle &optional outcome status)
  "Stop HANDLE's current HTTP attempt and dispose of its private buffer."
  (let ((buffer (amble-modelhub--request-buffer handle))
        (timer (amble-modelhub--request-timer handle))
        (attempt (amble-modelhub--request-attempt handle)))
    (setf (amble-modelhub--request-attempt handle) nil
          (amble-modelhub--request-buffer handle) nil
          (amble-modelhub--request-timer handle) nil)
    (when (timerp timer) (cancel-timer timer))
    (when attempt
      (amble-modelhub--observe
       handle `((event . "request-finished")
                (attempt . ,(amble-modelhub--request-attempt-count handle))
                (seconds . ,(max 0 (- (float-time) (amble-modelhub--request-started handle))))
                (outcome . ,(or outcome "cancelled")) (status . ,status))))
    (when (buffer-live-p buffer)
      ;; url.el detaches the process from its buffer before invoking us.
      (when-let* ((process (or (get-buffer-process buffer)
                              (buffer-local-value 'url-http-process buffer))))
        (set-process-sentinel process #'ignore)
        (set-process-filter process #'ignore)
        (delete-process process)
        (url-http-idle-sentinel process "closed by Amble\n"))
      (kill-buffer buffer))))

(defun amble-modelhub--retry-after ()
  "Read Retry-After from the current HTTP headers as a delay in seconds."
  (when (bound-and-true-p url-http-end-of-headers)
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search t))
        (when (re-search-forward "^Retry-After:[ \t]*\\([^\r\n]+\\)"
                                 url-http-end-of-headers t)
          (let ((value (string-trim (match-string-no-properties 1))))
            (if (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" value)
                (string-to-number value)
              (condition-case nil
                  (max 0 (- (float-time (date-to-time value)) (float-time)))
                (error nil)))))))))

(defun amble-modelhub--rate-limit-description (body)
  "Return a concise description of a 429 response BODY."
  (let ((code (condition-case nil
                  (amble-modelhub--get
                   "code" (amble-modelhub--get "error" (amble-modelhub--parse body)))
                (error nil))))
    (if (equal code "-2004")
        "ModelHub 业务资源不足（HTTP 429，-2004）"
      "ModelHub 暂时限流或资源不足（HTTP 429）")))

(defun amble-modelhub--retry-notice (handle text)
  "Notify HANDLE's caller about a pending retry without ending the request."
  (setf (amble-modelhub--request-notice-timer handle) nil)
  (when (and (amble-modelhub--request-active handle)
             (not (amble-modelhub--request-event handle)))
    (let ((inhibit-message t) (message-log-max nil))
      (funcall (amble-modelhub--request-callback handle)
               handle `((event . "retry") (text . ,text))))))

(defun amble-modelhub--retry (handle)
  "Resume HANDLE after a rate-limit delay, unless it was cancelled."
  (setf (amble-modelhub--request-retry-timer handle) nil)
  (when (and (amble-modelhub--request-active handle)
             (not (amble-modelhub--request-event handle)))
    (condition-case err
        (let ((inhibit-message t) (message-log-max nil))
          (funcall (amble-modelhub--request-callback handle)
                   handle '((event . "retrying")))
          (when (amble-modelhub--request-active handle)
            (amble-modelhub--post handle (amble-modelhub--payload handle))))
      (error (amble-modelhub--network-error handle err)))))

(defun amble-modelhub--rate-limit (handle body retry-after)
  "Schedule a bounded retry for HANDLE's 429 BODY, respecting RETRY-AFTER."
  (let* ((count (amble-modelhub--request-retry-count handle))
         (limit (or (alist-get 'max_retries (amble-modelhub--request-data handle)) 3))
         (delay (max (or retry-after 0) (min 60 (* 5 (expt 2 (min count 4))))))
         (description (amble-modelhub--rate-limit-description body)))
    (cond
     ((>= count limit)
      (amble-modelhub--error
       handle (format "%s；%s。已保留对话和工具结果，请稍后继续；若持续发生，需要在 ModelHub 申请扩容。"
                      description
                      (if (= count 0) "自动重试已关闭"
                        (format "重试 %d 次后仍不可用" count)))))
     ((> delay 60)
      ;; Never shorten the server's requested delay to fit our local limit.
      (amble-modelhub--error
       handle (format "%s；服务端要求至少等待 %d 秒，超过本次自动等待上限，已停止重试。请稍后继续。"
                      description (ceiling delay))))
     (t
      (setf (amble-modelhub--request-retry-count handle) (1+ count))
      (when-let* ((timer (amble-modelhub--request-notice-timer handle)))
        (cancel-timer timer))
      (setf (amble-modelhub--request-notice-timer handle)
            (run-at-time 0 nil #'amble-modelhub--retry-notice handle
                         (format "%s，%.0f 秒后重试（%d/%d），C-g 可取消。"
                                 description delay (1+ count) limit))
            (amble-modelhub--request-retry-timer handle)
            (run-at-time delay nil #'amble-modelhub--retry handle))))))

(defun amble-modelhub-cancel (handle)
  "Cancel HANDLE, including queued callbacks, without notifying its caller."
  (when (amble-modelhub--request-p handle)
    (setf (amble-modelhub--request-active handle) nil)
    (amble-modelhub--close handle)
    (dolist (timer (list (amble-modelhub--request-retry-timer handle)
                        (amble-modelhub--request-notice-timer handle)))
      (when (timerp timer) (cancel-timer timer)))
    (when-let* ((timer (amble-modelhub--request-delivery handle)))
      (cancel-timer timer))
    (setf (amble-modelhub--request-delivery handle) nil
          (amble-modelhub--request-event handle) nil
          (amble-modelhub--request-key handle) nil
          (amble-modelhub--request-data handle) nil
          (amble-modelhub--request-recovered-input handle) nil
          (amble-modelhub--request-retry-timer handle) nil
          (amble-modelhub--request-notice-timer handle) nil
          (amble-modelhub--request-observer handle) nil
          (amble-modelhub--request-callback handle) nil)))

(defun amble-modelhub--deliver (handle)
  "Deliver HANDLE's terminal event outside network process filters."
  (when (and (amble-modelhub--request-active handle)
             (amble-modelhub--request-event handle))
    (let ((event (amble-modelhub--request-event handle))
          (callback (amble-modelhub--request-callback handle)))
      (amble-modelhub-cancel handle)
      (let ((inhibit-message t) (message-log-max nil))
        (funcall callback handle event)))))

(defun amble-modelhub--emit (handle event)
  "Schedule the single completion or error EVENT for HANDLE."
  (when (and (amble-modelhub--request-active handle)
             (not (amble-modelhub--request-event handle)))
    ;; Let the session discard rejected reasoning without losing tool results,
    ;; even when the recovery request itself fails for another reason.
    (when-let* ((input (amble-modelhub--request-recovered-input handle)))
      (setf (alist-get 'recovered-input event) input))
    (setf (amble-modelhub--request-event handle) event
          (amble-modelhub--request-delivery handle)
          (run-at-time 0 nil #'amble-modelhub--deliver handle))))

(defun amble-modelhub--error (handle message &optional outcome)
  "Close HANDLE's network operation and queue a redacted error MESSAGE."
  (amble-modelhub--close handle (or outcome "error"))
  (amble-modelhub--emit handle `((event . "error")
                                (message . ,(amble-modelhub--redact handle message)))))

(defun amble-modelhub--timeout (handle attempt)
  "Expire ATTEMPT if it still belongs to HANDLE."
  (when (and (amble-modelhub--request-active handle)
             (eq attempt (amble-modelhub--request-attempt handle)))
    (amble-modelhub--error
     handle (format "ModelHub request timed out after %.1fs"
                    (- (float-time) (amble-modelhub--request-started handle)))
     "timeout")))

(defun amble-modelhub--network-error (handle err)
  "Report network ERR without dumping an HTTP request, headers or body."
  (amble-modelhub--error
   handle (concat "ModelHub HTTP processing failed: "
                  (car (split-string (error-message-string err) "[\r\n]")))))

(defun amble-modelhub--guard-process (handle attempt process)
  "Report asynchronous PROCESS errors immediately for HANDLE's ATTEMPT."
  (let ((filter (process-filter process))
        (sentinel (process-sentinel process)))
    (when filter
      (set-process-filter
       process
       (lambda (proc data)
         (when (and (amble-modelhub--request-active handle)
                    (eq attempt (amble-modelhub--request-attempt handle)))
           (condition-case err
               (let ((inhibit-message t) (message-log-max nil))
                 (funcall filter proc data))
             (error (amble-modelhub--network-error handle err)))))))
    (when sentinel
      (set-process-sentinel
       process
       (lambda (proc event)
         (when (and (amble-modelhub--request-active handle)
                    (eq attempt (amble-modelhub--request-attempt handle)))
           (condition-case err
               (let ((inhibit-message t) (message-log-max nil))
                 (funcall sentinel proc event))
             (error (amble-modelhub--network-error handle err)))))))))

(defun amble-modelhub--complete (handle response)
  "Validate RESPONSE, retaining every output item for the next request.
No tool is dispatched unless the entire response is complete and valid."
  (when-let* ((failure (amble-modelhub--get "error" response)))
    (error "ModelHub error: %s" (or (amble-modelhub--get "message" failure) failure)))
  (unless (equal (amble-modelhub--get "status" response) "completed")
    (error "ModelHub response %s: %s"
           (or (amble-modelhub--get "status" response) "has no status")
           (or (amble-modelhub--get "reason" (amble-modelhub--get "incomplete_details" response))
               "No complete response; no tools executed")))
  (let ((output (amble-modelhub--get "output" response)) texts calls call-ids)
    (unless (vectorp output) (error "ModelHub returned no output array"))
    (dolist (item (append output nil))
      (when-let* ((status (amble-modelhub--get "status" item)))
        (unless (equal status "completed") (error "Incomplete response output item")))
      (pcase (amble-modelhub--get "type" item)
        ("reasoning" nil) ; Preserve opaque reasoning items; never interpret them as instructions.
        ("message"
         (unless (and (equal (gethash "role" item) "assistant")
                      (vectorp (gethash "content" item)))
           (error "Invalid assistant message"))
         (dolist (part (append (gethash "content" item) nil))
           (let ((text (pcase (amble-modelhub--get "type" part)
                         ("output_text" (gethash "text" part))
                         ("refusal" (gethash "refusal" part))
                         (_ (error "Unsupported assistant content type")))))
             (unless (stringp text) (error "Invalid assistant text"))
             (push text texts))))
        ("function_call"
         (let ((id (gethash "call_id" item)) (name (gethash "name" item))
               (args (gethash "arguments" item)))
           (unless (and (stringp id) (not (string-empty-p id))
                        (not (member id call-ids))
                        (stringp name) (not (string-empty-p name))
                        (stringp args) (hash-table-p (amble-modelhub--parse args)))
             (error "Invalid or duplicate function call; nothing was executed"))
           (push id call-ids)
           (push item calls)))
        (_ (error "Unsupported Responses output type: %s"
                  (amble-modelhub--get "type" item)))))
    (unless (or calls (cl-some (lambda (text) (not (string-empty-p text))) texts))
      (error "Model returned no assistant text or function calls"))
    (amble-modelhub--emit
     handle `((event . "completion") (output . ,output)
              (text . ,(string-join (nreverse texts) "\n"))
              (calls . ,(nreverse calls))))))

(defun amble-modelhub--response (status handle attempt)
  "Consume URL STATUS in the response buffer for HANDLE's ATTEMPT."
  (if (not (and (amble-modelhub--request-active handle)
                (eq attempt (amble-modelhub--request-attempt handle))))
      (kill-buffer (current-buffer))
    (setf (amble-modelhub--request-buffer handle) (current-buffer))
    (condition-case err
        (let* ((elapsed (- (float-time) (amble-modelhub--request-started handle)))
               (bytes (buffer-size))
               (code (and (boundp 'url-http-response-status) url-http-response-status))
               (retry-after (when (eq code 429) (amble-modelhub--retry-after)))
               (body (when (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)
                       (when (> (- (point-max) url-http-end-of-headers) (* 16 1024 1024))
                         (error "ModelHub response exceeds 16 MiB"))
                       (decode-coding-string
                        (buffer-substring-no-properties url-http-end-of-headers (point-max))
                        'utf-8-unix))))
          (amble-modelhub--close handle (if (integerp code) "http" "connection error") code)
          (cond
           ((eq code 429)
            (amble-modelhub--rate-limit handle body retry-after))
           ((and (eq code 400) body
                 (amble-modelhub--recover-reasoning handle body)))
           ((and (integerp code) (or (< code 200) (>= code 300)))
            (error "HTTP %s: %s" code (or body "No response body")))
           ((plist-get status :error)
            (error "ModelHub connection failed: %s" (plist-get status :error)))
           ((not (integerp code))
            (error "ModelHub connection ended without an HTTP status after %.1fs (%d bytes received)"
                   elapsed bytes))
           ((null body)
            (error "ModelHub returned HTTP %d without complete headers after %.1fs" code elapsed))
           (t (amble-modelhub--complete handle (amble-modelhub--parse body)))))
      (error (amble-modelhub--error handle (error-message-string err))))))

(defun amble-modelhub--post (handle payload)
  "Send PAYLOAD asynchronously to the Responses API for HANDLE."
  (let* ((inhibit-message t) (message-log-max nil) (url-show-status nil)
         (attempt (list 'http))
         (url-request-method "POST")
         (url-request-data (encode-coding-string (amble-modelhub--json payload) 'utf-8-unix))
         (url-request-extra-headers
          (mapcar (lambda (header)
                    (cons (amble-modelhub--header-bytes (car header))
                          (amble-modelhub--header-bytes (cdr header))))
                  `(("Content-Type" . "application/json")
                    ("Authorization" . ,(concat "Bearer " (amble-modelhub--request-key handle)))
                    ("X-TT-LOGID" . ,(amble-modelhub--id)))))
         (url-mime-accept-string "application/json")
         (url-request-noninteractive t)
         (url-history-track nil) (url-automatic-caching nil) (url-debug nil)
         (url-max-redirections 0) (url-http-attempt-keepalives nil)
         (url-privacy-level 'paranoid)
         (url (amble-modelhub--request-endpoint handle)))
    (setf (amble-modelhub--request-started handle) (float-time)
          (amble-modelhub--request-attempt handle) attempt
          (amble-modelhub--request-timer handle)
          (run-at-time (or (alist-get 'timeout (amble-modelhub--request-data handle)) 120)
                       nil #'amble-modelhub--timeout handle attempt))
    (condition-case err
        (progn
          (cl-incf (amble-modelhub--request-attempt-count handle))
          (amble-modelhub--observe
           handle `((event . "request-started")
                    (attempt . ,(amble-modelhub--request-attempt-count handle))))
          (let ((buffer (url-retrieve url #'amble-modelhub--response
                                      (list handle attempt) t t)))
            ;; A mocked or unusually fast URL callback may have already finished.
            (when (eq attempt (amble-modelhub--request-attempt handle))
              (unless (buffer-live-p buffer) (error "Could not start ModelHub request"))
              (setf (amble-modelhub--request-buffer handle) buffer)
              (with-current-buffer buffer
                (setq-local url-debug nil url-history-track nil url-automatic-caching nil
                            url-http-no-retry t url-show-status nil)
                (rename-buffer " *amble-http*" t)
                (when-let* ((process (get-buffer-process buffer)))
                  (set-process-query-on-exit-flag process nil)
                  (amble-modelhub--guard-process handle attempt process))))))
      (error (amble-modelhub--network-error handle err))
      (quit (amble-modelhub-cancel handle) (signal 'quit nil)))))

(defun amble-modelhub-start (data callback &optional observer)
  "Send Responses request DATA using EMACS_AMBLE_API_KEY; return a handle.
CALLBACK receives (HANDLE EVENT) asynchronously.  DATA is an alist containing
endpoint, model, input, tools, reasoning, max_output_tokens, timeout and
max_retries.  OBSERVER receives request-started/request-finished telemetry."
  (let ((endpoint (amble-modelhub--endpoint (alist-get 'endpoint data)))
        (retries (or (alist-get 'max_retries data) 3))
        (timeout (or (alist-get 'timeout data) 120)))
    (unless (and (numberp timeout) (> timeout 0)) (error "Timeout must be positive"))
    (unless (and (integerp retries) (<= 0 retries 10))
      (error "Rate-limit retries must be an integer from 0 to 10"))
    (let ((handle (amble-modelhub--make
                   :data data :key (amble-modelhub--read-key)
                   :endpoint endpoint :callback callback :observer observer)))
      (condition-case err
          (amble-modelhub--post handle (amble-modelhub--payload handle))
        (error (amble-modelhub--error handle (error-message-string err))))
      handle)))

(provide 'amble-modelhub)
;;; amble-modelhub.el ends here
