(in-package :cl-mqtt.tests)

(define-fixture interop-fixture () ())

#++
(setf blackbird:*promise-finish-hook*
      #'(lambda (fn)
          (as:with-delay () (funcall fn))))
#++
(defmethod run-fixture-test-case :around ((fixture interop-fixture) test-case teardown-p debug-p)
  (with-broker (host port)
    (call-next-method)))

(deftest test-connect () (interop-fixture)
  (with-broker (host port error-cb)
    (bb:alet ((conn (mqtt:connect host
                                  :port port
                                  :error-handler error-cb)))
      (mqtt:disconnect conn))))

(deftest test-subscribe () (interop-fixture)
  (with-broker (host port error-cb)
    (bb:alet ((conn (mqtt:connect host :port port :error-handler error-cb)))
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
          (mqtt:disconnect conn))))))

(defun verify-publish (qos retain)
  (with-broker (host port error-cb)
    (let ((messages '())
          (expected-mid (if (plusp qos) 1 0)))
      (bb:alet ((conn (mqtt:connect
                       host
                       :port port
                       :error-handler error-cb
                       :on-message #'(lambda (message)
                                       (is (= qos (mqtt:mqtt-message-qos message)))
                                       (is (= expected-mid (mqtt:mqtt-message-mid message)))
                                       (is (eq retain (mqtt:mqtt-message-retain message)))
                                       (push (list (mqtt:mqtt-message-topic message)
                                                   (babel:octets-to-string
                                                    (mqtt:mqtt-message-payload message)
                                                    :encoding :utf-8))
                                             messages)))))
        (bb:walk (mqtt:subscribe conn "/a/#")
          (mqtt:publish conn "/a/b/c" "42" :qos qos :retain retain)
          (bb:wait (wait-for messages)
            (is (equal '(("/a/b/c" "42")) (nreverse messages)))))))))

(deftest test-publish-qos0 () (interop-fixture)
  (verify-publish 0 nil))

(deftest test-publish-qos1 () (interop-fixture)
  (verify-publish 1 nil))

(deftest test-publish-qos2 () (interop-fixture)
  (verify-publish 2 nil))

;; TBD: unsubscribe, unsuback
;; TBD: retained messages for each QoS level
;;      (perhaps better just use two publish calls in each VERIFY-PUBLISH;
;;      also, reconnect & make sure the messages are there)
;; TBD: use 'observe'
;; TBD: multi-topic subscriptions
;; TBD: subscribe errors
;; TBD: failed connection (to an 'available' port)
;; TBD: :event-cb for CONNECT is just TOO wrong
;; TBD: as:dump-event-loop-status at the end giving many handles?
;; TBD: an option auto text decoding for payload (but handle babel decoding errors!)
;; TBD: dup packets (perhaps not interop)
;; TBD: max number of inflight messages
