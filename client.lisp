(in-package :cl-mqtt)

(defparameter *default-response-timeout* 2) ;; FIXME

(defun %connect (host port read-cb write-cb later-error-cb)
  (bb:with-promise (resolve reject)
    (let ((connected-p nil)
          (socket nil))
      (setf socket
            (as:tcp-connect
             host port
             read-cb
             :event-cb (lambda (error)
                         (format t "error: ~a~%" error)
                         (if connected-p
                             (funcall later-error-cb error)
                             (reject (make-condition
                                      'mqtt-error
                                      :format-control "Connection failed: ~a"
                                      :format-arguments (list error)))))
             :connect-cb #'(lambda (socket)
                             (dbg "connected.")
                             (setf connected-p t)
                             (resolve socket))
             :write-cb #'(lambda (socket)
                           (declare (ignore socket))
                           (funcall write-cb)))))))

(defclass mqtt-client ()
  ((socket :accessor socket :initarg :socket)
   (reader :accessor reader :initarg :reader)
   (next-mid :accessor next-mid :initform 1)
   (response-timeout :accessor response-timeout :initform *default-response-timeout*
                     :initarg :response-timeout)
   (message-handlers :accessor message-handlers :initform '())
   (error-handler :accessor error-handler
                  :initarg :error-handler
                  :initform #'(lambda (error)
                                (warn "MQTT error: ~a" error)))
   (write-callback :accessor write-callback :initform nil)))

(defun get-next-mid (client)
  ;; FIXME: should keep track of 'in-flight' message ids, etc.
  (prog1
      (next-mid client)
    (incf (next-mid client))))

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

(defun push-message-handler (client pred-or-msg-type callback)
  (let ((pred
          (if (functionp pred-or-msg-type)
              pred-or-msg-type
              #'(lambda (message)
                  (eq pred-or-msg-type (mqtt-message-type message))))))
    (push (cons pred callback) (message-handlers client))))

(defun remove-message-handler (client handler)
  (deletef (message-handlers client) handler))

(defun handle-packet (client buf var-header-start)
  (let ((message (parse-packet buf var-header-start)))
    (iter (for item in (message-handlers client))
          (destructuring-bind (pred . callback)
              item
            (if (funcall pred message)
                (collect callback into callbacks)
                (collect item into new-handlers)))
          (finally
            (setf (message-handlers client) new-handlers)
            (as:with-delay ()
              (dolist (callback callbacks)
                (funcall callback message)))))))

(defun wait-for-message (client pred-or-msg-type)
  (bb:with-promise (resolve reject)
    (let (delay)
      (labels ((matches-p (message)
                 (if (functionp pred-or-msg-type)
                     (funcall pred-or-msg-type message)
                     (eq pred-or-msg-type (mqtt-message-type message))))
               (handle (message)
                 (as:free-event delay)
                 (resolve message)))
        (setf delay
              (as:with-delay ((response-timeout client))
                (remove-message-handler client #'handle)
                (reject
                 (handle-connection-error client "connection timed out"))))
        (push-message-handler client #'matches-p #'handle)))))

;; FIXME: use thread-specific buffer
(defun %send-message (client message)
  (let ((buf (make-array 1024 :element-type '(unsigned-byte 8) :fill-pointer 0)))
    (build-packet buf message)
    (as:write-socket-data (socket client) buf)))

(defun send-message (client message)
  (let (delay)
    (bb:with-promise (resolve reject)
      (setf (write-callback client)
            #'(lambda ()
                (as:free-event delay)
                (setf (write-callback client) nil)
                (dbg "sent ~s: ~s" (mqtt-message-type message) message)
                (resolve)))
      (%send-message client message)
      (setf delay
            (as:with-delay ((response-timeout client)) ;; FIXME: add write-timeout
              (:printv :write-timeout)
              (setf (write-callback client) nil)
              (%disconnect client)
              (reject (make-condition 'mqtt-error
                                      :format-control "Timed out writing")))))))

(defun talk (client message pred-or-msg-type)
  "Send a message and wait for reply"
  (bb:chain
      (bb:all
       (list (wait-for-message client pred-or-msg-type)
             (send-message client message)))
    (:then (result) (first result))))

;; TBD: need to fill in configurable values
(defun send-connect-message (client)
  (send-message
   client
   (make-mqtt-message :type :connect
                      :dup 0
                      :qos 0
                      :retain 0
                      :protocol-name "MQTT"
                      :protocol-level 4
                      :connect-username-flag 0
                      :connect-password-flag 0
                      :connect-will-qos 0
                      :connect-will-flag 0
                      :connect-clean-session-flag 1
                      :connect-keepalive 60
                      :client-id "cl-mqtt")))

(defun connect (host &rest initargs &key (port 1883) response-timeout error-handler)
  (declare (ignore response-timeout error-handler)) ;; passed via initargs
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
                          (remove-from-plist initargs :port)))
      (bb:chain
          (wait-for-message client :connack)
        (:then (message)
          (:printv (mqtt-message-ret-code message))
          (unless (eq :accepted (mqtt-message-ret-code message))
            (handle-connection-error "CONNECT rejected with ret code ~s"
                                     (mqtt-message-ret-code message)))))
      (bb:wait
          (send-connect-message client)
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
                 :retain 0
                 :mid mid
                 :topic topic
                 :subscription-qos qos)
                #'(lambda (message)
                    (dbg "expect mid ~s got ~s" mid (mqtt-message-mid message))
                    (and (eq :suback (mqtt-message-type message))
                         (= mid (mqtt-message-mid message)))))))
      (values (mqtt-message-subscription-qos response)
              (mqtt-message-mid response)))))

(defun ping (client)
  (send-message
   client
   (make-mqtt-message :type :pingreq)))

(defun publish (client topic payload)
  (send-message
   client
   (make-mqtt-message
    :type :publish
    :dup 0
    :qos 0
    :retain 0
    ;; TBD: mid for non-zero qos
    :topic topic
    :payload payload)))

(defun %disconnect (client)
  (setf (message-handlers client) '())
  (unless (as:streamish-closed-p (socket client))
    (as:close-socket (socket client)))
  (values))

(defun disconnect (client)
  (bb:wait
      (send-message client (make-mqtt-message :type :disconnect))
    (%disconnect client)
    (:printv :disconnected)
    (as:dump-event-loop-status)
    (values)))

;; TBD: auto-ping
;; TBD: look for 'coverate statements not found' in the broker output (myself, not in code)
