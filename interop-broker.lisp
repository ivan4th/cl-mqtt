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

(in-package :cl-mqtt.tests)

(defun port-available-p (port)
  (handler-case
      (as:tcp-server
       nil port
       #'(lambda (sock data)
           (declare (ignore sock data))))
    (as:socket-address-in-use () nil)
    (:no-error (server)
      (as:close-tcp-server server)
      t)))

(defun find-available-port (&optional (from-port 49152) (below-port 65536))
  (iter (for port from from-port below below-port)
        (when (port-available-p port)
          (return port))
        (finally
            (error "no available port found"))))

(defun dummy-connect (port &key (host "localhost") (timeout 0.3))
  (bb:with-promise (resolve reject)
    (as:tcp-connect host port
                    #'(lambda (socket data)
                        (declare (ignore socket data))
                        (values))
                    :event-cb #'(lambda (c)
                                  (reject c))
                    :read-timeout timeout
                    :connect-cb #'(lambda (socket)
                                    (resolve)
                                    (as:close-streamish socket)))))

(defun wait-for-tcp-port (port &key (host "localhost") (timeout 0.3)
                                 (interval 0.5) (attempts 4))
  (labels ((wait ()
             (bb:chain
                 (dummy-connect port :host host :timeout timeout)
               (:catch (c)
                 (if (typep c 'as:socket-refused)
                     (bb:with-promise (resolve reject)
                       (if (plusp attempts)
                           (as:with-delay (interval)
                             (decf attempts)
                             (resolve (wait)))
                           (error "timed out waiting for port ~d" port)))
                     (error "unexpected broker connect error: ~a" c))))))
    (wait)))

(defvar *broker-process* nil)
(defvar *broker-port* nil)

(defparameter *broker-path*
  (asdf:system-relative-pathname
   :cl-mqtt.tests
   #p"interop/org.eclipse.paho.mqtt.testing/interoperability/startbroker.py"))

(defun %wait-for (pred &optional action)
  (bb:with-promise (resolve reject)
    (labels ((wait (&optional (attempts 42))
               (when action (funcall action))
               (cond ((funcall pred)
                      (resolve))
                     ((zerop attempts)
                      (reject (make-instance
                               'simple-error
                               :format-control "WAIT-FOR timed out"
                               :format-arguments '())))
                     (t
                      (as:with-delay (0.1)
                        (wait (1- attempts)))))))
      (wait))))

(defmacro wait-for (expr &body body)
  `(%wait-for #'(lambda () ,expr)
     ,(when body `#'(lambda () ,@body))))

(defun start-broker ()
  (unless *broker-process*
    (setf *broker-port*
          (find-available-port)
          *broker-process*
          (as:spawn "python3"
                    (list (namestring *broker-path*)
                          "--port" (princ-to-string *broker-port*))
                    :output :inherit
                    :error-output :inherit
                    :exit-cb #'(lambda (proc exit-status term-signal)
                                 (declare (ignore proc exit-status term-signal))
                                 (format *debug-io* "~&broker process exited~%")
                                 (setf *broker-process* nil
                                       *broker-port* nil))))
    (bb:catcher
        (wait-for-tcp-port *broker-port*)
      (error (c)
        (stop-broker)
        (error "failed to start broker: ~a" c)))))

(defun stop-broker ()
  (wait-for (null *broker-process*)
    (when *broker-process*
      (as:process-kill *broker-process* 2))))

(defun call-with-broker (thunk)
  (flet ((doit ()
           (bb:walk
             (start-broker)
             (bb:with-promise (resolve reject)
               (let ((done-p nil))
                 (bb:chain
                     (funcall thunk "localhost" *broker-port*
                              #'(lambda (error)
                                  (stop-broker)
                                  (unless (shiftf done-p t)
                                    (reject error))))
                   (:then ()
                     (stop-broker)
                     (unless (shiftf done-p t)
                       (resolve)))
                   (:catch (error)
                     (stop-broker)
                     (unless (shiftf done-p t)
                       (reject error)))))))))
    (if cl-async-base:*event-base*
        (doit)
        (let ((err nil))
          (as:with-event-loop (:catch-app-errors nil)
            (as:add-event-loop-exit-callback
             #'(lambda ()
                 ;; abrupt event loop termination (FIXME)
                 (when *broker-process*
                   (as:process-kill *broker-process* 2)
                   (setf *broker-process* nil
                         *broker-port* nil))))
            (bb:wait
                (bb:catcher (doit) (error (c) (setf err c)))
              (as:exit-event-loop)))
          (when err
            (error err))))))

(defmacro with-broker ((&optional (host-var (gensym)) (port-var (gensym)) (error-cb-var (gensym)))
                       &body body)
  `(call-with-broker
    #'(lambda (,host-var ,port-var ,error-cb-var)
        (declare (ignorable ,host-var ,port-var ,error-cb-var))
        ,@body)))
