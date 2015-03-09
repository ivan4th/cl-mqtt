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

(define-fixture interop-fixture ()
  ((conn :accessor conn)
   (connect-args :accessor connect-args)
   (messages :accessor messages)))

#++
(setf blackbird:*promise-finish-hook*
      #'(lambda (fn)
          (as:with-delay () (funcall fn))))

(defmethod invoke-test-case :around ((fixture interop-fixture) test-case)
  (with-broker (host port error-cb)
    (setf (connect-args fixture)
          (list host :port port :error-handler error-cb))
    (reset-messages fixture)
    (bb:alet ((c (connect)))
      (setf (conn fixture) c)
      (call-next-method))))

(defun reset-messages (&optional (fixture *fixture*))
  (with-fixture (messages) fixture
    (setf (messages fixture)
          (make-array 64 :fill-pointer 0 :adjustable t))))

(defmethod setup :after ((fixture interop-fixture))
  (reset-messages fixture))

(defun connect (&optional (fixture *fixture*))
  (with-fixture (connect-args messages) fixture
    (apply #'mqtt:connect
           (append connect-args
                   (list :on-message
                         #'(lambda (message)
                             (dbg "on-message: ~s" message)
                             (vector-push-extend
                              (list (mqtt:mqtt-message-topic message)
                                    (babel:octets-to-string
                                     (mqtt:mqtt-message-payload message)
                                     :encoding :utf-8)
                                    (mqtt:mqtt-message-retain message)
                                    (mqtt:mqtt-message-qos message)
                                    (mqtt:mqtt-message-mid message))
                              messages)))))))

(defun got-messages-p (&optional (fixture *fixture*))
  (not (emptyp (messages fixture))))

(defun verify-messages (expected-messages &optional add-qos (fixture *fixture*))
  (with-fixture (messages) fixture
    (when add-qos
      ;; in case of QoS=0 we need to replace mids in expected messages with zeroes
      (setf expected-messages
            (iter (for (topic payload retain mid) in expected-messages)
                  (collect (list topic payload retain
                                 add-qos
                                 (if (zerop add-qos) 0 mid))))))
    (let ((actual-messages (coerce messages 'list)))
      (is (equal expected-messages actual-messages))
      (reset-messages fixture))))

(deftest test-connect (conn) (interop-fixture)
  ;; already connected here
  (mqtt:disconnect conn))

(deftest test-subscribe (conn) (interop-fixture)
  (flet ((sub (topic requested-qos expected-mid)
           (bb:multiple-promise-bind (qos mid)
                                     (apply #'mqtt:subscribe conn topic
                                            (when requested-qos (list requested-qos)))
             (is (= (or requested-qos 2) qos))
             (is (= expected-mid mid)))))
    (bb:walk
      (sub "/a/b" 0 1)
      (sub "/c/d" 1 2)
      (sub "/e/f" 2 3)
      (sub "/c/d" nil 4)
      (mqtt:disconnect conn))))

(define-constant +long-str+ (make-string 128 :initial-element #\X) :test #'equal)

(defun verify-publish (qos &optional (fixture *fixture*))
  (with-fixture (conn) fixture
    (bb:walk (mqtt:subscribe conn "/a/#")
      (bb:all
       (list
        (mqtt:publish conn "/a/b/c" "42" :qos qos :retain nil)
        (mqtt:publish conn "/a/b/c" +long-str+ :qos qos :retain nil)))
      (bb:wait (wait-for (got-messages-p fixture))
        (verify-messages `(("/a/b/c" "42" nil 1)
                           ("/a/b/c" ,+long-str+ nil 2))
                         qos)
        (bb:wait
            (mqtt:publish conn "/a/b/d" "4242" :qos qos :retain t)
          ;; expected-retain is still NIL.
          ;; The broker publishes the message back without the retain bit
          ;; because it isn't published as the result of new subscription.
          (bb:wait (wait-for (got-messages-p fixture))
            (verify-messages '(("/a/b/d" "4242" nil 3)) qos)
            ;; reconnect and look for the retained message
            (bb:wait (mqtt:disconnect conn)
              (bb:alet ((c1 (connect)))
                (bb:walk
                  (mqtt:subscribe c1 "/a/#")
                  (bb:wait (wait-for (got-messages-p fixture))
                    (verify-messages '(("/a/b/d" "4242" t 1)) qos)
                    (mqtt:disconnect c1)))))))))))

(deftest test-publish-qos0 () (interop-fixture)
  (verify-publish 0))

(deftest test-publish-qos1 () (interop-fixture)
  (verify-publish 1))

(deftest test-publish-qos2 () (interop-fixture)
  (verify-publish 2))

(deftest test-unsubscribe (conn) (interop-fixture)
  (bb:walk
    (mqtt:subscribe conn "/a/#")
    (mqtt:subscribe conn "/b/#")
    (mqtt:unsubscribe conn "/a/#")
    (mqtt:publish conn "/a/b" "whatever")
    (mqtt:publish conn "/b/c" "foobar")
    ;; "foobar" goes after whatever, so, if "foobar" was received,
    ;; "whatever" is already skipped
    (wait-for (got-messages-p))
    (verify-messages '(("/b/c" "foobar" nil 0 0)))))

(deftest test-ping (conn) (interop-fixture)
  (mqtt:ping conn))

;; TBD: test overlong messages
;; TBD: use 'observe'
;; TBD: multi-topic subscriptions
;; TBD: :event-cb for CONNECT is just TOO wrong
;; TBD: an option auto text decoding for payload (but handle babel decoding errors!)
;; TBD: unclean session
;; TBD: will

;; Separate tests with fake broker (non-interop):
;; TBD: failed connection (to an 'available' port)
;; TBD: dup packets
;; TBD: handle MQTT-ERRORs during message parsing (disconnect)
;; TBD: handle pings from server
;; TBD: max number of inflight messages
;; TBD: subscribe errors
