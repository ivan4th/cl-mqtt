(in-package :cl-mqtt)

;; FIXME: use thread-specific buffer
(defun send-message (socket message)
  (let ((buf (make-array 1024 :element-type '(unsigned-byte 8) :fill-pointer 0)))
    (build-packet buf message)
    (as:write-socket-data socket buf)))

;; TBD: need to fill in configurable values
(defun send-connect-message (socket)
  (send-message
   socket
   (make-mqtt-message :type :connect
                      :dup 0
                      :qos 0
                      :retain 0
                      :protocol-name "MQIsdp"
                      :protocol-level 3
                      :connect-username-flag 0
                      :connect-password-flag 0
                      :connect-will-qos 0
                      :connect-will-flag 0
                      :connect-clean-session-flag 1
                      :connect-keepalive 60
                      :client-id "cl-mqtt")))

(defclass mqtt-client ()
  ((socket :accessor socket)
   (reader :accessor reader)
   (next-mid :accessor next-mid :initform 1)
   (message-handlers :accessor message-handlers :initform '())))

(defun push-message-handler (client handler)
  (push handler (message-handlers client)))

#++
(defun connect (host &optional (port 1883))
  (let ((client (make-instance
                 'mqtt-client
                 :reader (make-mqtt-frame-reader
                          #'(lambda (buf var-header-start)
                              (dbg-show (parse-packet buf var-header-start)))))))
    (setf (socket client)
          (as:tcp-connect
           host port
           #'(lambda (socket bytes)
               (declare (ignore socket))
               (dbg "read: ~s" bytes)
               (funcall (reader client) bytes))
           (lambda (ev)
             (format t "ev: ~a~%" ev))
           :connect-cb #'(lambda (socket)
                           (dbg "connected.")
                           (send-connect-message socket))))
    client))

(defun connect (host &optional (port 1883))
  (let ((client (make-instance 'mqtt-client))
        (future (asf:make-future)))
    (setf (reader client)
          (make-mqtt-frame-reader
           #'(lambda (buf var-header-start)
               ;; TBD: catch parse errors
               (let ((message (parse-packet buf var-header-start)))
                 (dbg-show message)
                 (setf (message-handlers client)
                       (iter (for handler in (message-handlers client))
                             (when (funcall handler message)
                               (collect handler)))))))
          (socket client)
          (as:tcp-connect
           host port
           #'(lambda (socket bytes)
               (declare (ignore socket))
               (dbg "read: ~s" bytes)
               (funcall (reader client) bytes))
           (lambda (ev)
             (format t "ev: ~a~%" ev)
             (asf:signal-error future ev))
           :connect-cb #'(lambda (socket)
                           (dbg "connected.")
                           (push-message-handler
                            client
                            #'(lambda (message)
                                (case (mqtt-message-type message)
                                  (:connack
                                   (case (mqtt-message-ret-code message)
                                     (:accepted
                                      (asf:finish future client)
                                      ;; remove the handler
                                      nil)
                                     (t (error "oops (TBD: fix this)"))))
                                  ;; keep the handler if this is not CONNACK
                                  (t t))))
                           (send-connect-message socket))))
    future))

(defun subscribe (client topic)
  (let ((future (asf:make-future))
        (mid (next-mid client)))
    (push-message-handler
     client
     #'(lambda (message)
         (cond ((and (eq :suback (mqtt-message-type message))
                     (= mid (mqtt-message-mid message)))
                (asf:finish future t)
                nil)
               ;; TBD: better error handling (e.g. disconnection while waiting)
               ;; Perhaps PUSH-MESSAGE-HANDLER should accept packet type spec
               ;; and also disconnection/failure callback. Need to handle timeouts,
               ;; too.
               (t t))))
    (send-message
     (socket client)
     (make-mqtt-message
      :type :subscribe
      :dup 0
      :qos 1
      :retain 0
      :mid mid
      :topic topic
      :subscription-qos 0))
    (incf (next-mid client))
    future))

(defun ping (client)
  (send-message
   (socket client)
   (make-mqtt-message :type :pingreq)))

(defun publish (client topic payload)
  (send-message
   (socket client)
   (make-mqtt-message
    :type :publish
    :dup 0
    :qos 0
    :retain 0
    ;; TBD: mid for non-zero qos
    :topic topic
    :payload payload)))

(defun disconnect (client)
  (as:close-socket (socket client)))
