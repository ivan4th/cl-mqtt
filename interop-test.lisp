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

;; TBD: response timeouts
;; TBD: handle connack
;; TBD: multi-topic subscriptions
;; TBD: subscribe errors
;; TBD: failed connection (to an 'available' port)
;; TBD: :event-cb for CONNECT is just TOO wrong
;; TBD: as:dump-event-loop-status at the end giving many handles?
