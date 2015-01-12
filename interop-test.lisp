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

(defun verify-publish (qos)
  (with-broker (host port error-cb)
    (let ((messages '())
          (expected-mid (if (plusp qos) 1 0)))
      (flet ((connect ()
               (mqtt:connect host
                             :port port
                             :error-handler error-cb
                             :on-message
                             #'(lambda (message)
                                 (dbg "on-messsage: ~s" message)
                                 (is (= qos (mqtt:mqtt-message-qos message)))
                                 (is (= expected-mid (mqtt:mqtt-message-mid message)))
                                 (push (list (mqtt:mqtt-message-topic message)
                                             (babel:octets-to-string
                                              (mqtt:mqtt-message-payload message)
                                              :encoding :utf-8)
                                             (mqtt:mqtt-message-retain message))
                                       messages)))))
        (bb:alet ((conn (connect)))
          (bb:walk (mqtt:subscribe conn "/a/#")
            (mqtt:publish conn "/a/b/c" "42" :qos qos :retain nil)
            (bb:wait (wait-for messages)
              (is (equal '(("/a/b/c" "42" nil)) (nreverse (shiftf messages nil))))
              (when (plusp qos)
                (incf expected-mid))
              (bb:wait
                  (mqtt:publish conn "/a/b/d" "4242" :qos qos :retain t)
                ;; expected-retain is still NIL.
                ;; The broker publishes the message back without the retain bit
                ;; because it isn't published as the result of new subscription.
                (bb:wait (wait-for messages)
                  (is (equal '(("/a/b/d" "4242" nil))
                             (nreverse (shiftf messages nil))))
                  ;; reconnect and look for the retained message
                  (bb:wait (mqtt:disconnect conn)
                    (bb:alet ((conn (connect)))
                      (when (plusp qos)
                        (setf expected-mid 1))
                      (bb:walk
                        (mqtt:subscribe conn "/a/#")
                        (bb:wait (wait-for messages)
                          (is (equal '(("/a/b/d" "4242" t))
                                     (nreverse (shiftf messages nil))))
                          (mqtt:disconnect conn))))))))))))))

(deftest test-publish-qos0 () (interop-fixture)
  (verify-publish 0))

(deftest test-publish-qos1 () (interop-fixture)
  (verify-publish 1))

(deftest test-publish-qos2 () (interop-fixture)
  (verify-publish 2))

(deftest test-unsubscribe () (interop-fixture)
  (with-broker (host port error-cb)
    (let ((messages '()))
      (bb:alet ((conn (mqtt:connect host
                                    :port port
                                    :error-handler error-cb
                                    :on-message #'(lambda (message)
                                                    (push (babel:octets-to-string
                                                           (mqtt:mqtt-message-payload message)
                                                           :encoding :utf-8)
                                                          messages)))))
        (bb:walk
          (mqtt:subscribe conn "/a/#")
          (mqtt:subscribe conn "/b/#")
          (mqtt:unsubscribe conn "/a/#")
          (mqtt:publish conn "/a/b" "whatever")
          (mqtt:publish conn "/b/c" "foobar")
          ;; "foobar" goes after whatever, so, if "foobar" was received,
          ;; "whatever" is already skipped
          (wait-for messages)
          (is (equal '("foobar") messages)))))))

(deftest test-ping () (interop-fixture)
  (with-broker (host port error-cb)
    (bb:alet ((conn (mqtt:connect host :port port :error-handler error-cb)))
      (mqtt:ping conn))))

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
