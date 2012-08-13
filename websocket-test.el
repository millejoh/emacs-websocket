;; websocket-test.el --- Unit tests for the websocket layer

;; Copyright (c) 2010 Andrew Hyatt
;;
;; Author: Andrew Hyatt <ahyatt at gmail dot com>
;; Maintainer: Andrew Hyatt <ahyatt at gmail dot com>
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;; 02110-1301, USA.

;;; Commentary:
;; This defines and runs ert unit tests.  You can download ert from:
;; http://github.com/ohler/ert, it also comes with Emacs 24 and above.

(require 'ert)
(require 'websocket)
(eval-when-compile (require 'cl))

(ert-deftest websocket-genbytes-length ()
  (loop repeat 100
        do (should (= (string-bytes (websocket-genbytes 16)) 16))))

(ert-deftest websocket-calculate-accept ()
  ;; This example comes straight from RFC 6455
  (should
   (equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
          (websocket-calculate-accept "dGhlIHNhbXBsZSBub25jZQ=="))))

(defconst websocket-test-hello "\x81\x05\x48\x65\x6c\x6c\x6f"
  "'Hello' string example, taken from the RFC.")

(defconst websocket-test-masked-hello
  "\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58"
  "'Hello' masked string example, taken from the RFC.")

(defconst websocket-test-64-bit-p
  (calc-eval '("2^32 <= $") 'pred most-positive-fixnum))

(ert-deftest websocket-get-bytes ()
  (should (equal #x5 (websocket-get-bytes "\x5" 1)))
  (should (equal #x101 (websocket-get-bytes "\x1\x1" 2)))
  (let ((f (lambda () (websocket-get-bytes "\x0\x0\x0\x1\x0\x0\x0\x1" 8))))
    (if websocket-test-64-bit-p
        (should (equal #x100000001 (funcall f)))
      (should-error (funcall f) :type 'websocket-unparseable-frame)))
  (should-error (websocket-get-bytes "\x0\x0\x0" 3))
  (should-error (websocket-get-bytes "\x0" 2) :type 'websocket-unparseable-frame))

(ert-deftest websocket-get-opcode ()
  (should (equal 'text (websocket-get-opcode websocket-test-hello))))

(ert-deftest websocket-get-payload-len ()
  (should (equal '(5 . 1)
                 (websocket-get-payload-len
                  (substring websocket-test-hello 1))))
  (should (equal '(200 . 3)
                 (websocket-get-payload-len
                  (bindat-pack '((:len u8) (:val u16))
                               `((:len . 126)
                                 (:val . 200))))))
  ;; we don't want to hit up any limits even on strange emacs builds,
  ;; so this test has a pretty small test value
  (should (equal '(70000 . 9)
                 (websocket-get-payload-len
                  (bindat-pack '((:len u8) (:val vec 2 u32))
                               `((:len . 127)
                                 (:val . [0 70000])))))))

(ert-deftest websocket-read-frame ()
  (should (equal (make-websocket-frame :opcode 'text :payload "Hello"
                                       :length (length websocket-test-hello)
                                       :completep t)
                 (websocket-read-frame websocket-test-hello)))
  (should (equal (make-websocket-frame :opcode 'text :payload "Hello"
                                       :length (length websocket-test-hello)
                                       :completep t)
                 (websocket-read-frame (concat websocket-test-hello
                                               "should-not-be-read"))))
  (should (equal (make-websocket-frame :opcode 'text :payload "Hello"
                                       :length (length websocket-test-masked-hello)
                                       :completep t)
                 (websocket-read-frame websocket-test-masked-hello)))
  (should (equal (make-websocket-frame :opcode 'text :payload "Hello"
                                       :length (length websocket-test-hello)
                                       :completep nil)
                 (websocket-read-frame
                  (concat (unibyte-string
                           (logand (string-to-char
                                    (substring websocket-test-hello 0 1))
                                   127))
                          (substring websocket-test-hello 1)))))
  (dotimes (i (- (length websocket-test-hello) 1))
    (should-not (websocket-read-frame
                 (substring websocket-test-hello 0
                            (- (length websocket-test-hello) (+ i 1))))))
  (dotimes (i (- (length websocket-test-masked-hello) 1))
    (should-not (websocket-read-frame
                 (substring websocket-test-masked-hello 0
                            (- (length websocket-test-masked-hello) (+ i 1)))))))

(defun websocket-test-header-with-lines (&rest lines)
  (mapconcat 'identity (append lines '("\r\n")) "\r\n"))

(ert-deftest websocket-verify-response-code ()
  (should (websocket-verify-response-code "HTTP/1.1 101"))
  (should
   (eq 400 (cdr (should-error (websocket-verify-response-code "HTTP/1.1 400")
                          :type 'websocket-received-error-http-response))))
  (should
   (eq 200 (cdr (should-error (websocket-verify-response-code "HTTP/1.1 200"))))))

(ert-deftest websocket-verify-headers ()
  (let ((accept "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        (invalid-accept "Sec-WebSocket-Accept: bad")
        (upgrade "Upgrade: websocket")
        (connection "Connection: upgrade")
        (ws (websocket-inner-create
             :conn "fake-conn" :url "ws://foo/bar"
             :accept-string "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        (ws-with-protocol
         (websocket-inner-create
             :conn "fake-conn" :url "ws://foo/bar"
             :accept-string "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
             :protocols '("myprotocol")))
        (ws-with-extensions
         (websocket-inner-create
             :conn "fake-conn" :url "ws://foo/bar"
             :accept-string "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
             :extensions '("ext1" "ext2"))))
    (should (websocket-verify-headers
             ws
             (websocket-test-header-with-lines accept upgrade connection)))
    (should-error
     (websocket-verify-headers
      ws
      (websocket-test-header-with-lines invalid-accept upgrade connection))
     :type 'websocket-invalid-header)
    (should-error (websocket-verify-headers
                   ws
                   (websocket-test-header-with-lines upgrade connection))
                  :type 'websocket-invalid-header)
    (should-error (websocket-verify-headers
                   ws
                   (websocket-test-header-with-lines accept connection))
                  :type 'websocket-invalid-header)
    (should-error (websocket-verify-headers
                   ws
                   (websocket-test-header-with-lines accept upgrade))
                  :type 'websocket-invalid-header)
    (should-error (websocket-verify-headers
                   ws-with-protocol
                   (websocket-test-header-with-lines accept upgrade connection))
                  :type 'websocket-invalid-header)
    (should-error
     (websocket-verify-headers
      ws-with-protocol
      (websocket-test-header-with-lines accept upgrade connection
                                        "Sec-Websocket-Protocol: foo"))
     :type 'websocket-invalid-header)
    (should
     (websocket-verify-headers
      ws-with-protocol
      (websocket-test-header-with-lines accept upgrade connection
                                        "Sec-Websocket-Protocol: myprotocol")))
    (should (equal '("myprotocol")
                   (websocket-negotiated-protocols ws-with-protocol)))
    (should-error
     (websocket-verify-headers
      ws-with-extensions
      (websocket-test-header-with-lines accept upgrade connection
                                        "Sec-Websocket-Extensions: foo")))
    (should
     (websocket-verify-headers
      ws-with-extensions
      (websocket-test-header-with-lines
       accept upgrade connection "Sec-Websocket-Extensions: ext1, ext2; a=1")))
    (should (equal '("ext1" "ext2; a=1")
                   (websocket-negotiated-extensions ws-with-extensions)))
    (should
     (websocket-verify-headers
      ws-with-extensions
      (websocket-test-header-with-lines accept upgrade connection
                                        "Sec-Websocket-Extensions: ext1"
                                        "Sec-Websocket-Extensions: ext2; a=1")))
    (should (equal '("ext1" "ext2; a=1")
                   (websocket-negotiated-extensions ws-with-extensions)))))

(ert-deftest websocket-create-headers ()
  (let ((system-name "mysystem")
        (base-headers (concat "Host: www.example.com\r\n"
                              "Upgrade: websocket\r\n"
                              "Connection: Upgrade\r\n"
                              (format "Sec-WebSocket-Key: %s\r\n"
                                      (websocket-calculate-accept "key"))
                              "Origin: mysystem\r\n"
                              "Sec-WebSocket-Version: 13\r\n")))
    (should (equal (concat base-headers "\r\n")
                   (websocket-create-headers "ws://www.example.com/path"
                                             "key" nil nil)))
    (should (equal (concat base-headers
                           "Sec-WebSocket-Protocol: protocol\r\n\r\n")
                   (websocket-create-headers "ws://www.example.com/path"
                                             "key" '("protocol") nil)))
    (should (equal
             (concat base-headers
                     "Sec-WebSocket-Extensions: ext1; a; b=2, ext2\r\n\r\n")
             (websocket-create-headers "ws://www.example.com/path"
                                       "key" nil
                                       '(("ext1" . ("a" "b=2"))
                                         ("ext2")))))))

(ert-deftest websocket-process-frame ()
  (let* ((sent)
         (processed)
         (deleted)
         (websocket (websocket-inner-create
                     :conn t :url t
                     :on-message (lambda (websocket frame)
                                   (setq
                                    processed
                                    (websocket-frame-payload frame)))
                     :accept-string t)))
    (dolist (opcode '(text binary continuation))
      (setq processed nil)
      (should (equal
               "hello"
               (progn
                 (funcall (websocket-process-frame
                   websocket
                   (make-websocket-frame :opcode opcode :payload "hello")))
                 processed))))
    (setq sent nil)
    (flet ((websocket-send (websocket content) (setq sent content)))
      (should (equal
               (make-websocket-frame :opcode 'pong :completep t)
               (progn
                 (funcall (websocket-process-frame websocket
                                           (make-websocket-frame :opcode 'ping)))
                 sent))))
    (flet ((delete-process (conn) (setq deleted t)))
      (should (progn
                (funcall
                 (websocket-process-frame websocket
                                          (make-websocket-frame :opcode 'close)))
                deleted)))))

(ert-deftest websocket-process-frame-error-handling ()
  (let* ((error-called)
         (websocket (websocket-inner-create
                     :conn t :url t :accept-string t
                     :on-message (lambda (websocket frame)
                                   (message "In on-message")
                                   (error "err"))
                     :on-error (lambda (ws type err)
                                 (should (eq 'on-message type))
                                 (setq error-called t)))))
    (funcall (websocket-process-frame websocket
                                      (make-websocket-frame :opcode 'text
                                                            :payload "hello")))
    (should error-called)))

(ert-deftest websocket-to-bytes ()
  ;; We've tested websocket-get-bytes by itself, now we can use it to
  ;; help test websocket-to-bytes.
  (should (equal 30 (websocket-get-bytes (websocket-to-bytes 30 1) 1)))
  (should (equal 300 (websocket-get-bytes (websocket-to-bytes 300 2) 2)))
  (let ((f (lambda () (websocket-to-bytes 70000 8))))
    (if websocket-test-64-bit-p
        (should (equal 70000 (websocket-get-bytes (funcall f) 8)))
      (should-error (funcall f))))
  (should-error (websocket-to-bytes 30 3))
  (should-error (websocket-to-bytes 300 1))
  ;; I'd like to test the error for 32-byte systems on 8-byte lengths,
  ;; but elisp does not allow us to temporarily set constants such as
  ;; most-positive-fixnum.
  )

(ert-deftest websocket-encode-frame ()
  ;; We've tested websocket-read-frame, now we can use that to help
  ;; test websocket-encode-frame.
  (let ((websocket-mask-frames nil))
    (should (equal
             websocket-test-hello
             (websocket-encode-frame
              (make-websocket-frame :opcode 'text :payload "Hello" :completep t))))
    (dolist (len (if websocket-test-64-bit-p '(200 70000) '(200 60000)))
      (let ((long-string (make-string len ?x)))
        (should (equal long-string
                       (websocket-frame-payload
                        (websocket-read-frame
                         (websocket-encode-frame
                          (make-websocket-frame :opcode 'text
                                                :payload long-string)))))))))
  (let ((websocket-mask-frames t))
    (flet ((websocket-genbytes (n) (substring websocket-test-masked-hello 2 6)))
      (should (equal websocket-test-masked-hello
                     (websocket-encode-frame
                      (make-websocket-frame :opcode 'text :payload "Hello"
                                            :completep t))))))
  (should-not
   (websocket-frame-completep
    (websocket-read-frame
     (websocket-encode-frame (make-websocket-frame :opcode 'text
                                                   :payload "Hello"
                                                   :completep nil)))))
  (dolist (opcode '(close ping pong))
    (should (equal
             opcode
             (websocket-frame-opcode
              (websocket-read-frame
               (websocket-encode-frame (make-websocket-frame :opcode opcode
                                                             :completep t))))))))

(ert-deftest websocket-close ()
  (let ((sent-frames))
    (flet ((websocket-send (websocket frame) (push frame sent-frames))
           (websocket-openp (websocket) t)
           (kill-buffer (buffer))
           (process-buffer (conn)))
      (websocket-close (websocket-inner-create
                        :conn "fake-conn"
                        :url t
                        :accept-string t))
      (should (equal sent-frames (list
                                  (make-websocket-frame :opcode 'close
                                                        :completep t)))))))

(ert-deftest websocket-outer-filter ()
  (let* ((fake-ws (websocket-inner-create
                   :conn t :url t :accept-string t
                   :on-open (lambda (websocket)
                              (should (eq (websocket-ready-state websocket)
                                          'open))
                              (setq open-callback-called t)
                              (error "Ignore me!"))
                   :on-error (lambda (ws type err))))
         (processed-frames)
         (frame1 (make-websocket-frame :opcode 'text :payload "foo" :completep t
                                       :length 9))
         (frame2 (make-websocket-frame :opcode 'text :payload "bar" :completep t
                                       :length 9))
         (open-callback-called)
         (websocket-frames
          (concat
           (websocket-encode-frame frame1)
           (websocket-encode-frame frame2))))
    (flet ((websocket-process-frame
            (websocket frame)
            (lexical-let ((frame frame))
              (lambda () (push frame processed-frames))))
           (websocket-verify-response-code (output) t)
           (websocket-verify-headers (websocket output) t))
      (websocket-outer-filter fake-ws "Sec-")
      (should (eq (websocket-ready-state fake-ws) 'connecting))
      (should-not open-callback-called)
      (websocket-outer-filter fake-ws "WebSocket-Accept: acceptstring")
      (should-not open-callback-called)
      (websocket-outer-filter fake-ws (concat
                                       "\r\n\r\n"
                                       (substring websocket-frames 0 2)))
      (should open-callback-called)
      (websocket-outer-filter fake-ws (substring websocket-frames 2))
      (should (equal (list frame2 frame1) processed-frames)))
    (flet ((websocket-ready-state (websocket) 'connecting)
           (websocket-close (websocket)))
      (should (eq 500 (cdr (should-error
                                (websocket-outer-filter fake-ws "HTTP/1.1 500\r\n\r\n")
                                :type 'websocket-received-error-http-response)))))))

(ert-deftest websocket-outer-filter-bad-connection ()
  (let* ((on-open-calledp)
         (websocket-closed-calledp)
         (fake-ws (websocket-inner-create
                   :conn t :url t :accept-string t
                   :on-open (lambda (websocket)
                              (setq on-open-calledp t)))))
    (flet ((websocket-verify-response-code (output) t)
           (websocket-verify-headers (websocket output) (error "Bad headers!"))
           (websocket-close (websocket) (setq websocket-closed-calledp t)))
      (condition-case err
          (progn (websocket-outer-filter fake-ws "HTTP/1.1 101\r\n\r\n")
                 (error "Should have thrown an error!"))
        (error
         (should-not on-open-calledp)
         (should websocket-closed-calledp))))))

(ert-deftest websocket-send ()
  (let ((ws (websocket-inner-create :conn t :url t :accept-string t)))
    (flet ((websocket-ensure-connected (websocket))
           (websocket-openp (websocket) t)
           (process-send-string (conn string)))
      ;; Just make sure there is no error.
      (websocket-send ws (make-websocket-frame :opcode 'ping
                                                       :completep t)))
    (should-error (websocket-send ws
                                  (make-websocket-frame :opcode 'text)))
    (should-error (websocket-send ws
                                  (make-websocket-frame :opcode 'close
                                                        :payload "bye!"
                                                        :completep t))
                  :type 'websocket-illegal-frame)
    (should-error (websocket-send ws
                                  (make-websocket-frame :opcode :close))
                  :type 'websocket-illegal-frame)))

(ert-deftest websocket-verify-client-headers ()
  (let* ((http "HTTP/1.1")
         (host "Host: authority")
         (upgrade "Upgrade: websocket")
         (key (format "Sec-Websocket-Key: %s" (base64-encode-string "key")))
         (version "Sec-Websocket-Version: 13")
         (origin "Origin: origin")
         (protocol "Sec-Websocket-Protocol: protocol")
         (extensions1 "Sec-Websocket-Extensions: foo")
         (extensions2 "Sec-Websocket-Extensions: bar; baz=2")
         (all-required-headers (list host upgrade key version)))
    ;; Test that all these headers are necessary
    (should (equal
             '(:key "key" :protocols ("protocol") :extensions ("foo" "bar; baz=2"))
             (websocket-verify-client-headers
              (mapconcat 'identity (append (list http "" protocol extensions1 extensions2)
                                           all-required-headers) "\r\n"))))
    (should (websocket-verify-client-headers
              (mapconcat 'identity
                         (mapcar 'upcase
                                 (append (list http "" protocol extensions1 extensions2)
                                         all-required-headers)) "\r\n")))
    (dolist (header all-required-headers)
      (should-not (websocket-verify-client-headers
                   (mapconcat 'identity (append (list http "")
                                                (remove header all-required-headers))
                              "\r\n"))))
    (should-not (websocket-verify-client-headers
                 (mapconcat 'identity (append (list "HTTP/1.0" "") all-required-headers)
                            "\r\n")))))

(ert-deftest websocket-intersect ()
  (should (equal '(2) (websocket-intersect '(1 2) '(2 3))))
  (should (equal nil (websocket-intersect '(1 2) '(3 4))))
  (should (equal '(1 2) (websocket-intersect '(1 2) '(1 2)))))

(ert-deftest websocket-get-server-response ()
  (let ((ws (websocket-inner-create :conn t :url t :accept-string "key"
                                    :protocols '("spa" "spb")
                                    :extensions '("sea" "seb"))))
    (should (equal (concat
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n"
                    "Sec-WebSocket-Accept: key\r\n\r\n")
                   (websocket-get-server-response ws nil nil)))
    (should (string-match "Sec-Websocket-Protocol: spb\r\n"
                          (websocket-get-server-response ws '("spb" "spc") nil)))
    (should-not (string-match "Sec-Websocket-Protocol:"
                              (websocket-get-server-response ws '("spc") nil)))
    (let ((output (websocket-get-server-response ws '("spa" "spb") nil)))
      (should (string-match "Sec-Websocket-Protocol: spa\r\n" output))
      (should (string-match "Sec-Websocket-Protocol: spb\r\n" output)))
    (should (string-match "Sec-Websocket-Extensions: sea"
                          (websocket-get-server-response ws nil '("sea" "sec"))))
    (should-not (string-match "Sec-Websocket-Extensions:"
                              (websocket-get-server-response ws nil '("sec"))))
    (let ((output (websocket-get-server-response ws nil '("sea" "seb"))))
      (should (string-match "Sec-Websocket-Extensions: sea\r\n" output))
      (should (string-match "Sec-Websocket-Extensions: seb\r\n" output)))))

(ert-deftest websocket-server-filter ()
  (let ((on-open-called)
        (ws (websocket-inner-create :conn t :url t :accept-string "key"
                                    :on-open (lambda (ws) (setq on-open-called t))))
        (closed)
        (response)
        (processed))
    (flet ((process-send-string (p text) (setq response text))
           (websocket-close (ws) (setq closed t))
           (process-get (process sym) ws))
     ;; Bad request, in two parts
     (flet ((websocket-verify-client-headers (ws text) nil))
       (websocket-server-filter nil "HTTP/1.0 GET /foo \r\n")
       (should-not closed)
       (websocket-server-filter nil "\r\n")
       (should (equal response "HTTP/1.1 400 Bad Request\r\n\r\n"))
       (should-not (websocket-inflight-input ws)))
    ;; Good request, followed by packet
     (setq closed nil
           response nil)
     (setf (websocket-inflight-input ws) nil)
     (flet ((websocket-verify-client-headers (ws text) t)
            (websocket-get-server-response (ws protocols extensions)
                                           "response")
            (websocket-process-input-on-open-ws (ws text)
                                                (setq processed t)
                                                (should
                                                 (equal text websocket-test-hello))))
       (websocket-server-filter nil
                                (concat "\r\n\r\n" websocket-test-hello))
       (should (equal (websocket-ready-state ws) 'open))
       (should-not closed)
       (should (equal response "response"))
       (should processed)))))

(ert-deftest websocket-complete-server-response-test ()
  ;; Example taken from RFC
  (should (equal
           (concat "HTTP/1.1 101 Switching Protocols\r\n"
                   "Upgrade: websocket\r\n"
                   "Connection: Upgrade\r\n"
                   "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
                   "Sec-WebSocket-Protocol: chat\r\n\r\n"
                   )
           (let ((header-info
                          (websocket-verify-client-headers
                           (concat "GET /chat HTTP/1.1\r\n"
                                   "Host: server.example.com\r\n"
                                   "Upgrade: websocket\r\n"
                                   "Connection: Upgrade\r\n"
                                   "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                                   "Origin: http://example.com\r\n"
                                   "Sec-WebSocket-Protocol: chat, superchat\r\n"
                                   "Sec-WebSocket-Version: 13\r\n"))))
                     (should header-info)
                     (let ((ws (websocket-inner-create
                                :conn t :url t
                                :accept-string (websocket-calculate-accept
                                                (plist-get header-info :key))
                                :protocols '("chat"))))
                       (websocket-get-server-response
                        ws
                        (plist-get header-info :protocols)
                        (plist-get header-info :extension)))))))
