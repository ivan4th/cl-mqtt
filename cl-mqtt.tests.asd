;;;; cl-mqtt.tests.asd

(asdf:defsystem :cl-mqtt.tests
  :serial t
  :description "Common Lisp MQTT implementation for cl-async -- tests"
  :author "Ivan Shvedunov <ivan4th@gmail.com>"
  :license "TBD"
  :depends-on (:alexandria
               :iterate
               :vtf
               :i4-diet-utils
               :cl-mqtt)
  :components ((:file "cl-mqtt-test")
               (:file "interop-broker")
               (:file "interop-test")))
