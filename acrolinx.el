;;; acrolinx.el --- Check with Acrolinx from within Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2019, 2020 Acrolinx GmbH

;; Authors:
;; Claus Brunzema <claus.brunzema at acrolinx.com>
;; Stefan Kamphausen <stefan.kamphausen at acrolinx.com>
;; Keywords: tools

;; This file is not part of Emacs

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;; 02110-1301 USA or see <http://www.gnu.org/licenses/>.


;;; Commentary:

;; First of all, please note that you need access to Acrolinx which is
;; a commercial software. Without it, this is not useful for you.

;; Getting started:

;; - Set `acrolinx-server-url' to the url of your Acrolinx server.
;; - Get an API token from your Acrolinx server (see
;;   https://github.com/acrolinx/platform-api#getting-an-api-token)
;; - Put the API token into `acrolinx-api-token' or use
;;   emacs' auth-source library and put the token e.g. into
;;   ~/.netrc (possibly encrypted).
;; - Load and evaluate acrolinx.el
;; - Call `acrolinx-check' in a buffer with some text you want to check.
;; - The check results/flags will pop up in a dedicated buffer.


;; TODOs
;; DONE (http/other) error handling!
;; DONE display all flags
;; DONE add document reference (buffer-file-name?) in check request
;; DONE add contentFormat in check request (markdown etc.)
;; DONE show flag help texts
;; - support Acrolinx Sign-In (https://github.com/acrolinx/platform-api#getting-an-access-token-with-acrolinx-sign-in)
;; DONE support checking a selection/region
;; DONE acrolinx-dwim: check buffer/region
;; - display statistics
;; - use customize
;; - display goal colors
;; DONE key "g" -> refresh
;; - improve sdk documentation?
;; - sidebar lookalike with speedbar-style attached frame?
;; - support compile-next-error
;; DONE make selected target configurable (with completion), put into buffer-local var
;; DONE defvar acrolinx-default-target -> value or func
;; - handle nil credentials
;; - support custom field sending
;; - check for emacs version >= 25 (libxml support)
;; - send cancel after check timeout
;; DONE sort flags by text position
;; - acrolinx-mode -> acrolinx
;; - cleanup buffer-local vars
;; - add link to scorecard
;; - support -*- buffer settings for content format and target


;;; Code:


(defvar acrolinx-version "0.9.0"
  "Version of acrolinx.el.")


;;;- configuration --------------------------------------------------------
(defvar acrolinx-server-url nil
  "URL of the Acrolinx Server.")


(defvar acrolinx-x-client "SW50ZWdyYXRpb25EZXZlbG9wbWVudERlbW9Pbmx5"
  "Client signature for talking to the Acrolinx Server.

Until acrolinx.el gets an official integration signature we'll use
the development value taken from https://github.com/acrolinx/platform-api#signature")


(defvar acrolinx-api-token nil
  "API token for talking to the Acrolinx Server.

See https://github.com/acrolinx/platform-api#getting-an-api-token on
how to get an API token.

If you do not want to set this token from
lisp source code you can set this variable to nil. In this case
we call `auth-source-search' to get an API token using
`acrolinx-x-client' as :user and the host portion of
`acrolinx-server-url' as :host parameter.")


(defvar acrolinx-timeout 30
  "Timeout in seconds for communication with the Acrolinx server.")


(defvar acrolinx-flag-face 'match
  "Face used to highlight issues in the checked buffer text.")


(defvar acrolinx-request-check-result-interval 1.5
  "Interval in seconds between checking if a job has finished.")


(defvar acrolinx-request-check-result-max-tries 25
  "How many times to check if a job has finished before giving up.")


(defvar acrolinx-scorecard-buffer-name "*Acrolinx Scorecard*"
  "Name to use for the buffer containing scorecard results.")


(defvar acrolinx-initial-default-target nil
  "Default target to use.

Target to use for checking a buffer that has not been checked by
Acrolinx before. If the value is a string, the string is used as
the target name. If the value is a function it is called to get a
target name. If the value is nil the user will be asked for a
target name.")


(defvar acrolinx-auto-content-format-alist
  '((text-mode . "TEXT")
    (fundamental-mode . "TEXT")
    (nxml-mode . "XML")
    (html-mode . "HTML")
    (json-mode . "JSON")
    (yaml-mode . "YAML")
    (conf-javaprop-mode . "PROPERTIES")
    (java-mode . "JAVA")
    (cc-mode . "CPP")
    (markdown-mode . "MARKDOWN"))
  "Alist of major mode symbols to content formats.")


;;;- dependencies ---------------------------------------------------------
(require 'cl)
(require 'cl-macs)
(require 'auth-source)
(require 'url-http)
(require 'json)
(require 'shr)
(require 'subr-x)


;;;- internals ------------------------------------------------------------
(defvar acrolinx-available-targets '()
  "Cache for the available targets.

See `acrolinx-get-available-targets'")


(defvar-local acrolinx-target nil
  "Target to use for checks in this buffer.")


(defvar acrolinx-scorecard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'kill-this-buffer)
    (define-key map (kbd "g")
      (lambda ()
        (interactive)
        (pop-to-buffer acrolinx-src-buffer)
        (acrolinx-check)))
    map)
  "Keymap used in the Acrolinx scorecard buffer.")


(define-derived-mode acrolinx-scorecard-mode special-mode
  "Acrolinx Scorecard"
  "Major special mode for displaying Acrolinx scorecards."
  (defvar-local acrolinx-overlays '())
  (defvar-local acrolinx-src-buffer nil)
  (add-hook 'kill-buffer-hook #'acrolinx-delete-overlays nil 'local))


(defvar acrolinx-last-response-string "" "only for debugging")
(defvar acrolinx-last-check-result-response nil "only for debugging")


;;;- utilities ------------------------------------------------------------
(defun acrolinx-get-x-auth ()
  (or acrolinx-api-token
      (let ((secret
             (plist-get
              (car
               (auth-source-search :host (url-host
                                          (url-generic-parse-url
                                           acrolinx-server-url))
                                   :user acrolinx-x-client))
              :secret)))
        (if (functionp secret)
            (funcall secret)
          secret))))

(defun acrolinx-url-http (url callback &optional
                                   callback-args
                                   request-method
                                   extra-headers
                                   data)
  (let ((url-request-method (or request-method "GET"))
        (url-request-extra-headers
         (append
          (list (cons "x-acrolinx-client" acrolinx-x-client)
                (cons "x-acrolinx-auth" (acrolinx-get-x-auth)))
          extra-headers))
        (url-request-data (when (stringp data)
                            (encode-coding-string data 'utf-8))))
    (url-http (url-generic-parse-url url)
              callback
              (cons nil callback-args))))

(defun acrolinx-check-status (status)
  (when-let ((error-info (plist-get status :error)))
    (error "Http request failed: %s" (cdr error-info))))

(defun acrolinx-get-json-from-response ()
  (setq acrolinx-last-response-string (buffer-string))
  (let ((http-response-code (url-http-parse-response)))
    (unless (and (>= http-response-code 200)
                 (< http-response-code 300))
      (error "Query failed with http status %d: %s"
             http-response-code
             (buffer-string))))
  (goto-char (point-min))
  (re-search-forward "^HTTP/" nil t) ;skip to header start
  (re-search-forward "^$" nil t) ;skip to body
  (let ((json-object-type 'hash-table)
        (json-array-type 'list))
    (condition-case err
        (json-read-from-string (decode-coding-string
                                (buffer-substring (point) (point-max))
                                'utf-8))
      (error
       (message "Json parse error: %s\n %s" err (buffer-string))
       (make-hash-table)))))

(defun acrolinx-delete-overlays ()
  (mapc #'delete-overlay acrolinx-overlays)
  (setq acrolinx-overlays '()))

(defun acrolinx-string-from-html (html)
  (with-temp-buffer
    (insert html)
    (let ((dom (libxml-parse-html-region (point-min) (point-max))))
      (erase-buffer)
      (shr-insert-document dom)
      (string-trim (buffer-substring-no-properties (point-min) (point-max))))))

(defun acrolinx-prepare-scorecard-buffer ()
  (with-current-buffer (get-buffer-create acrolinx-scorecard-buffer-name)
    (unless (eq major-mode 'acrolinx-scorecard-mode)
      (set-buffer-multibyte t)
      (acrolinx-scorecard-mode))
    (acrolinx-delete-overlays)
    (setq buffer-read-only nil)
    (erase-buffer)))

(defun acrolinx-insert-button (label action help &optional face)
  (let ((wrapper (lambda (button) (funcall action) nil)))
    (insert-button label
                   'action wrapper
                   'follow-link wrapper
                   'help-echo help
                   'face (or face 'button))))

(defun acrolinx-get-targets-from-capabilities ()
  (let* ((deadline (+ (float-time) acrolinx-timeout))
         (finished nil)
         (response-buffer
          (acrolinx-url-http
           (concat acrolinx-server-url "/api/v1/checking/capabilities")
           (lambda (status)
             (acrolinx-check-status status)
             (setq finished t)))))
      (while (and (null finished)
                  (< (float-time) deadline))
        (sit-for 0.3))
      (unless finished
        (error "Timeout querying capabilities"))

      (with-current-buffer response-buffer
        (let* ((json (acrolinx-get-json-from-response))
               (targets (gethash "guidanceProfiles" (gethash "data" json))))
          (when (null targets)
            (error "No targets found in capability response"))
          (mapcar (lambda (target)
                    (cons (gethash "id" target)
                          (gethash "displayName" target)))
                  targets)))))

(defun acrolinx-get-available-targets ()
  "Gets the available targets of the Acrolinx server.

The targets list is cached in `acrolinx-available-targets'.
If this function is called interactively the cache is flushed and
a fresh list of targets is requested from the server."
  (interactive)
  (when (called-interactively-p 'interactive)
    (setq acrolinx-available-targets '()))
  (setq acrolinx-available-targets
        (or acrolinx-available-targets
            (acrolinx-get-targets-from-capabilities)))
  (when (called-interactively-p 'interactive)
    (message "available targets: %s"
             (string-join (mapcar #'cdr acrolinx-available-targets) ", ")))
  acrolinx-available-targets)


;;;- checking workflow ----------------------------------------------------
(defun acrolinx-check (&optional arg)
  "Check the contents of the current buffer with Acrolinx.

If the buffer has been checked before the target is taken from
the (buffer-local) `acrolinx-target'. Otherwise, if
`acrolinx-initial-default-target' is not nil, the target
name is taken from there. The last resort is asking the user to
select a target from all available targets.

When called with a prefix arg, always ask the user for the target.

Remembers the target in the buffer-local `acrolinx-target'.
"
  (interactive "P")
  (let ((target
         (or (and (null arg)
                  acrolinx-target)
             (and (null arg)
                  (or (and (functionp acrolinx-initial-default-target)
                           (funcall acrolinx-initial-default-target))
                      acrolinx-initial-default-target))
             (let* ((available-targets (acrolinx-get-available-targets))
                    (display-names (mapcar #'cdr available-targets))
                    (default (car display-names)))
               (car (rassoc
                     (completing-read
                      (concat "Target (default: " default "): ")
                      display-names
                      nil ;predicate
                      t ; require-match
                      nil ; initial input
                      nil ; hist
                      default)
                     available-targets))))))
    (when (null target)
      (error "Could not determine a valid target"))
    (setq acrolinx-target target) ; buffer local
    (acrolinx-send-check-string
     target
     (and (use-region-p) (region-beginning))
     (and (use-region-p) (region-end))))
  (setq deactivate-mark nil)) ; keep region

(defun acrolinx-send-check-string (target &optional begin end)
  "Send the contents of the current buffer to the Acrolinx server.

This sends the buffer content to `acrolinx-server-url' and
installs callbacks that handle the responses when they arrive
later from the server. The resulting scorecards will be shown in
a separate buffer (called `acrolinx-scorecard-buffer-name')."
  (acrolinx-prepare-scorecard-buffer)
  (acrolinx-url-http
   (concat acrolinx-server-url "/api/v1/checking/checks")
   #'acrolinx-handle-check-string-response
   (list (current-buffer))
   "POST"
   '(("content-type" . "application/json"))
   (concat "{\"content\":\""
           (base64-encode-string
            (encode-coding-string
             (encode-coding-string
              (buffer-substring-no-properties (point-min)
                                              (point-max))
              'utf-8 t t) ; convert from whatever to utf-8
             'no-conversion t t) ; convert utf-8 to raw bytes for base64
            t) "\",
             \"checkOptions\":{"
            "\"guidanceProfileId\":\"" target "\","
            "\"contentFormat\":\""
            (alist-get major-mode
                       acrolinx-auto-content-format-alist
                       "AUTO") "\","
            (if (and begin end)
                (concat "\"partialCheckRanges\":"
                        "[{\"begin\":" (number-to-string (- begin 1)) ","
                        "\"end\":" (number-to-string (- end 1)) "}],")
                "")
            "\"checkType\":\"interactive\""
            "},"
            "\"contentEncoding\":\"base64\","
            "\"document\":{"
            "\"reference\":\"" (buffer-file-name) "\""
            "}}")))

(defun acrolinx-handle-check-string-response (status &optional src-buffer)
  (acrolinx-check-status status)
  (let ((check-result-url
         (gethash "result"
                  (gethash "links"
                           (acrolinx-get-json-from-response)))))
    (sit-for acrolinx-request-check-result-interval)
    (acrolinx-request-check-result src-buffer check-result-url 1)))

(defun acrolinx-request-check-result (src-buffer url attempt)
  (if (> attempt acrolinx-request-check-result-max-tries)
      ;; TODO send cancel
      (error "No check result with %s after %d attempts"
             url acrolinx-request-check-result-max-tries)
    (acrolinx-url-http
     url
     #'acrolinx-handle-check-result-response
     (list src-buffer url attempt))))

(defun acrolinx-handle-check-result-response (status
                                                   &optional
                                                   src-buffer url attempt)
  (acrolinx-check-status status)
  (let* ((json (acrolinx-get-json-from-response))
         (data (gethash "data" json)))
    (setq acrolinx-last-check-result-response json)
    (if (null data)
        (progn
          ;; TODO use retryAfter value from server response
          (sit-for acrolinx-request-check-result-interval)
          (acrolinx-request-check-result src-buffer url (+ 1 attempt)))
      (let* ((score (gethash "score" (gethash "quality" data)))
             (goals  (gethash "goals" data))
             (issues (gethash "issues" data)))
        (message "Acrolinx score: %d" score)
        (switch-to-buffer-other-window acrolinx-scorecard-buffer-name)
        (setq acrolinx-src-buffer src-buffer)
        (insert (format "Acrolinx Score: %d\n\n" score))
        (acrolinx-render-issues issues goals)
        (setq buffer-read-only t)
        (goto-char (point-min))))))

(defun acrolinx-get-guidance-html (issue)
  (or (and (plusp (length (gethash "guidanceHtml" issue)))
           (gethash "guidanceHtml" issue))
      (string-join
       (mapcar (lambda (sub) (gethash "displayNameHtml" sub))
               (gethash "subIssues" issue))
       "<br/>")))

(defun acrolinx-render-issues (issues goals)
  (cl-flet
      ((get-issue-position (issue)
         (or
          (when-let ((pos-info (gethash "positionalInformation" issue))
                     (matches (gethash "matches" pos-info))
                     (first-match (first matches)))
            (gethash "originalBegin" first-match))
          0)))
    (setq issues (sort issues
                       (lambda (a b)
                         (< (get-issue-position a) (get-issue-position b)))))
    (mapc #'acrolinx-render-issue issues)))

(defun acrolinx-render-issue (issue)
  (let* ((all-matches (gethash "matches"
                               (gethash "positionalInformation" issue)))
         (start-match (first all-matches))
         (end-match (car (last all-matches)));can be the same as start-match
         (match-text (if (eq start-match end-match)
                         (gethash "originalPart" start-match)
                       (concat (gethash "originalPart" start-match)
                               " ... "
                               (gethash "originalPart" end-match))))
         (match-start (gethash "originalBegin" start-match))
         (match-end (gethash "originalEnd" end-match))
         (spacer (make-string (length match-text) ? ))
         (suggestions (mapcar
                       (lambda (suggestion)
                         (gethash "surface" suggestion))
                       (gethash "suggestions" issue)))
         (overlay (make-overlay (+ 1 match-start)
                                (+ 1 match-end)
                                acrolinx-src-buffer)))
    (overlay-put overlay 'face acrolinx-flag-face)
    (push overlay acrolinx-overlays)

    (acrolinx-insert-button match-text
                                 (lambda ()
                                   (pop-to-buffer acrolinx-src-buffer)
                                   (goto-char (overlay-start overlay)))
                                 "jump to source location")

    (if (null suggestions)
        (insert "\n")
      (cl-flet ((create-suggestion-button-action (suggestion)
                 (lambda ()
                   (let ((old-size (- (overlay-end overlay)
                                      (overlay-start overlay))))
                     (pop-to-buffer acrolinx-src-buffer)
                     (goto-char (overlay-start overlay))
                     (overlay-put overlay 'face nil)
                     (insert suggestion)
                     (delete-char old-size)))))
        (insert " -> ")
        (acrolinx-insert-button (first suggestions)
                                     (create-suggestion-button-action
                                      (first suggestions))
                                     "replace text")
        (insert "\n")
        (dolist (suggestion (rest suggestions))
          (insert spacer " -> ")
          (acrolinx-insert-button
           suggestion
           (create-suggestion-button-action suggestion)
           "replace text")
          (insert "\n"))))

    (let ((issue-name (acrolinx-string-from-html
                       (gethash "displayNameHtml" issue)))
          (guidance (acrolinx-string-from-html
                     (acrolinx-get-guidance-html issue))))
      (if (zerop (length guidance))
          (insert (concat "  " issue-name))
        (let ((marker-overlay (make-overlay (point) (+ 1 (point))))
              (guidance-overlay (make-overlay 1 2))) ; dummy positions
          (acrolinx-insert-button
           (concat "+ " issue-name)
           (lambda ()
             (goto-char (overlay-start marker-overlay))
             (setq buffer-read-only nil)
             (if (overlay-get guidance-overlay 'invisible)
                 (insert "-")
               (insert "+"))
             (delete-char 1)
             (setq buffer-read-only t)
             (overlay-put guidance-overlay 'invisible
                          (not (overlay-get guidance-overlay 'invisible))))
           "toggle guidance"
           'default)
          (insert "\n")
          (let ((guidance-pos (point)))
            (insert guidance)
            (insert "\n")
            (move-overlay guidance-overlay guidance-pos (point)))
          (overlay-put guidance-overlay 'invisible t))))
    (insert "\n\n")))

(provide 'acrolinx)
;;; acrolinx.el ends here