;;; Copyright (c) 2015 Ivan Shvedunov
;;;
;;; Permission is hereby granted, free of charge, to any person obtaining a copy
;;; of this software and associated documentation files (the "Software"), to deal
;;; in the Software without restriction, including without limitation the rights
;;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;;; copies of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:
;;;
;;; The above copyright notice and this permission notice shall be included in
;;; all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
;;; THE SOFTWARE.

(in-package :cl-mqtt)

(defparameter *default-response-timeout* 2) ;; FIXME
(defparameter *default-keepalive* 60)
(defparameter *default-ping-interval* 15)

(defun %connect (host port read-cb write-cb later-error-cb)
  (bb:with-promise (resolve reject)
    (let ((connected-p nil)
          (socket nil))
      (setf socket
            (as:tcp-connect
             host port
             read-cb
             :event-cb (lambda (error)
                         (format t "~&error: ~a~%" error)
                         (if connected-p
                             (funcall later-error-cb error)
                             (reject (make-condition
                                      'mqtt-error
                                      :format-control "Connection failed: ~a"
                                      :format-arguments (list error)))))
             :connect-cb #'(lambda (socket)
                             #++
                             (dbg "connected.")
                             (setf connected-p t)
                             (resolve socket))
             :write-cb #'(lambda (socket)
                           (declare (ignore socket))
                           (funcall write-cb)))))))

(defclass mqtt-client ()
  ((socket :accessor socket :initarg :socket)
   (reader :accessor reader :initarg :reader)
   (last-mid :accessor last-mid :initform 0)
   (response-timeout :accessor response-timeout :initform *default-response-timeout*
                     :initarg :response-timeout)
   (keepalive :accessor keepalive :initform *default-keepalive*
              :initarg :keepalive)
   (ping-interval :accessor ping-interval :initform *default-ping-interval*
                  :initarg :ping-interval)
   (message-handlers :accessor message-handlers :initform '())
   (error-handler :accessor error-handler
                  :initarg :error-handler
                  :initform #'(lambda (error)
                                (warn "MQTT error: ~a" error)))
   (write-callback :accessor write-callback :initform nil)
   (write-finished-promise :accessor write-finished-promise :initform nil)
   (on-message :accessor on-message
               :initform #'(lambda (message)
                             (format *debug-io* "~&incoming mqtt message: ~s~%" message))
               :initarg :on-message)
   (ping-stopper :accessor ping-stopper)
   (client-id :accessor client-id :initarg :client-id)))

(defun get-next-mid (client)
  ;; FIXME: should keep track of 'in-flight' message ids, etc.
  (setf (last-mid client)
        (logand (1+ (last-mid client)) #xffff)))

(defun handle-connection-error (client error &rest args)
  "Handle an async connection error that cannot be expressed as
  promise rejection"
  (when (stringp error)
    (setf error (make-condition 'mqtt-error
                                :format-control error
                                :format-arguments args)))
  (%disconnect client)
  (when (error-handler client)
    (funcall (error-handler client) error))
  error)

(defun push-message-handler (client match callback &key permanent-p)
  (let ((pred
          (etypecase match
            (function match)
            (keyword #'(lambda (message)
                         (eq match (mqtt-message-type message))))
            ((cons keyword (integer 0 65535))
             #'(lambda (message)
                 (and (eq (car match) (mqtt-message-type message))
                      (eq (cdr match) (mqtt-message-mid message))))))))
    (push (list pred callback permanent-p) (message-handlers client))))

(defun remove-message-handler (client handler)
  (deletef (message-handlers client) handler :key #'second))

(defun handle-packet (client buf var-header-start)
  (let ((message (parse-packet buf var-header-start)))
    #++
    (dbg "recv: ~s ~s" (mqtt-message-type message) message)
    (iter (for item in (message-handlers client))
          (destructuring-bind (pred callback permanent-p)
              item
            (let ((match-p (funcall pred message)))
              (when match-p
                (collect callback into callbacks))
              (when (or (not match-p) permanent-p)
                (collect item into new-handlers))))
          (finally
            (setf (message-handlers client) new-handlers)
            ;; TBD: shouldn't need delay here if blackbird is fixed
            (as:with-delay ()
              (dolist (callback callbacks)
                (funcall callback message)))))))

(defun wait-for-message (client pred)
  (bb:with-promise (resolve reject)
    (let (delay)
      (labels ((handle (message)
                 (when delay
                   (as:remove-event delay)
                   (as:free-event delay)
                   (resolve message))))
        (setf delay
              (as:with-delay ((response-timeout client))
                (setf delay nil)
                (remove-message-handler client #'handle)
                (reject
                 (handle-connection-error client "connection timed out (waiting for ~s)" pred))))
        (push-message-handler client pred #'handle)))))

;; FIXME: use thread-specific buffer
(defun %send-message (client message)
  (let ((buf (make-array 1024 :element-type '(unsigned-byte 8) :fill-pointer 0)))
    (build-packet buf message)
    (as:write-socket-data (socket client)
                          ;; FIXME (performance)
                          (coerce buf '(simple-array (unsigned-byte 8) (*))))))

(defun send-message (client message)
  (setf (write-finished-promise client)
        (flet ((actually-send ()
                 (let (delay)
                   (bb:with-promise (resolve reject :name "SEND-MESSAGE-PROMISE")
                     (setf (write-callback client)
                           #'(lambda ()
                               (when delay
                                 (as:remove-event delay)
                                 (as:free-event delay)
                                 (setf (write-callback client) nil
                                       (write-finished-promise client) nil)
                                 #++
                                 (dbg "sent ~s: ~s" (mqtt-message-type message) message)
                                 (resolve))))
                     (setf delay
                           (as:with-delay ((response-timeout client)) ;; FIXME: add write-timeout
                             (setf delay nil
                                   (write-callback client) nil
                                   (write-finished-promise client) nil)
                             (%disconnect client)
                             (let ((condition (make-condition 'mqtt-error
                                                              :format-control "Timed out writing")))
                               (handle-connection-error client condition)
                               (reject condition))))
                     (%send-message client message)))))
          (if (null (write-finished-promise client))
              (actually-send)
              (bb:attach (write-finished-promise client) #'actually-send)))))

(defun talk (client message pred-or-msg-type)
  "Send a message and wait for reply"
  (bb:chain
      (bb:all
       (list (wait-for-message client pred-or-msg-type)
             (send-message client message)))
    (:then (result) (first result))))

;; TBD: need to fill in configurable values
;; TBD: should auto-generate client-id if not specified
(defun send-connect-message (client &key client-id (clean-session t))
  (setf client-id (or client-id "cl-mqtt"))
  (check-type client-id string)
  (send-message
   client
   (make-mqtt-message :type :connect
                      :dup 0
                      :qos 0
                      :retain nil
                      :protocol-name "MQTT"
                      :protocol-level 4
                      :connect-username-flag 0
                      :connect-password-flag 0
                      :connect-will-qos 0
                      :connect-will-flag 0
                      :connect-clean-session-flag (if clean-session 1 0)
                      :connect-keepalive (keepalive client)
                      :client-id client-id)))

(defun handle-publish (client message)
  (flet ((invoke-on-message ()
           (bb:catcher
               (funcall (on-message client) message)
             (error (c)
               (warn "on-message failed: ~a" c)))))
    (let ((mid (mqtt-message-mid message)))
      (case (mqtt-message-qos message)
        (0
         (invoke-on-message))
        (1
         ;; make sure the :puback is written to the socket
         ;; so disconnect will not kill it
         (bb:wait (send-message client (make-mqtt-message :type :puback :mid mid))
           (invoke-on-message)))
        (2
         (bb:walk
           (send-message client (make-mqtt-message :type :pubrec :mid mid))
           (wait-for-message client (cons :pubrel mid))
           ;; FIXME: the delay should not be necessary here
           ;; https://github.com/orthecreedence/blackbird/issues/16
           (as:with-delay () (invoke-on-message))
           (send-message client (make-mqtt-message :type :pubcomp :mid mid))))))))

(defun handle-ping (client)
  (send-message client (make-mqtt-message :type :pingresp)))

(defun connect (host &rest initargs &key (port 1883) response-timeout error-handler on-message
                                      keepalive ping-interval client-id (clean-session t))
  (declare (ignore response-timeout error-handler on-message
                   keepalive ping-interval)) ; passed via initargs
  (let (client)
    (bb:alet ((socket (%connect host port
                                #'(lambda (socket bytes)
                                    (declare (ignore socket))
                                    (funcall (reader client) bytes))
                                #'(lambda ()
                                    (when (write-callback client)
                                      (funcall (write-callback client))))
                                #'(lambda (error)
                                    (handle-connection-error client error)))))
      (setf client (apply #'make-instance 'mqtt-client
                          :socket socket
                          :reader (make-mqtt-frame-reader
                                   #'(lambda (buf var-header-start)
                                       (handle-packet client buf var-header-start)))
                          (remove-from-plist initargs :port :clean-session)))
      (setf (ping-stopper client)
            (as:with-interval ((ping-interval client))
              (ping client)))
      ;; TBD: perhaps should just check for :PUBLISH and :PINGREQ
      ;; in HANDLE-PACKET instead of using 'permanent' handlers
      (push-message-handler client
                            :publish
                            #'(lambda (message)
                                (handle-publish client message))
                            :permanent-p t)
      (push-message-handler client
                            :pingreq
                            #'(lambda (message)
                                (declare (ignore message))
                                (handle-ping client))
                            :permanent-p t)
      (bb:chain
          (wait-for-message client :connack)
        (:then (message)
          (unless (eq :accepted (mqtt-message-ret-code message))
            (handle-connection-error "CONNECT rejected with ret code ~s"
                                     (mqtt-message-ret-code message)))))
      (bb:wait
          (send-connect-message client :client-id client-id :clean-session clean-session)
        ;; note that we don't wait for connack before returning
        ;; (TBD: make it an option)
        client))))

(defun subscribe (client topic &optional (qos 2))
  (let ((mid (get-next-mid client)))
    (bb:alet ((response
               (talk
                client
                (make-mqtt-message
                 :type :subscribe
                 :dup 0
                 :qos 1 ;; that's QoS for SUBSCRIBE command itself, not subscription
                 :retain nil
                 :mid mid
                 :topic topic
                 :subscription-qos qos)
                (cons :suback mid))))
      (values (mqtt-message-subscription-qos response)
              (mqtt-message-mid response)))))

(defun unsubscribe (client topic)
  (let ((mid (get-next-mid client)))
    (bb:alet ((response
               (talk
                client
                (make-mqtt-message
                 :type :unsubscribe
                 :dup 0
                 :qos 1 ;; that's QoS for UNSUBSCRIBE command itself, not subscription
                 :retain nil
                 :mid mid
                 :topic topic)
                (cons :unsuback mid))))
      (values (mqtt-message-subscription-qos response)
              (mqtt-message-mid response)))))

(defun ping (client)
  (talk client (make-mqtt-message :type :pingreq) :pingresp))

(defun publish (client topic payload &key (qos 0) (retain nil))
  (check-type payload (or string (vector (unsigned-byte 8))))
  (let ((mid (if (plusp qos) (get-next-mid client) 0)))
    (bb:wait (send-message
              client
              (make-mqtt-message
               :type :publish
               :dup 0
               :qos qos
               :retain retain
               :mid mid
               :topic topic
               :payload (if (stringp payload)
                            (babel:string-to-octets payload :encoding :utf-8)
                            payload)))
      (case qos
        (1 (wait-for-message client (cons :puback mid)))
        (2 (bb:walk
             (wait-for-message client (cons :pubrec mid))
             (send-message client (make-mqtt-message
                                   :type :pubrel
                                   :qos 1
                                   :mid mid))
             (wait-for-message client (cons :pubcomp mid))))))))

(defun %disconnect (client)
  (setf (message-handlers client) '())
  (when (ping-stopper client)
    (handler-case
        (funcall (shiftf (ping-stopper client) nil))
      (error (c)
        (warn "PING-STOPPER ERROR: ~a" c))))
  (unless (as:streamish-closed-p (socket client))
    (as:close-socket (socket client)))
  (values))

(defun disconnect (client)
  (bb:finally
      (bb:chain
          (send-message client (make-mqtt-message :type :disconnect))
        (:then () (values)))
    (%disconnect client)
    #++
    (as:dump-event-loop-status)))

;; TBD: auto-ping
;; TBD: look for 'coverate statements not found' in the broker output (myself, not in code)
;; TBD: look for 'ERROR' in broker output (in the code)
