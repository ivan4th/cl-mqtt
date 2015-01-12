;;;; cl-mqtt.asd

(asdf:defsystem :cl-mqtt
  :serial t
  :description "Common Lisp MQTT implementation for cl-async"
  :author "Ivan Shvedunov <ivan4th@gmail.com>"
  :license "TBD"
  :depends-on (:alexandria
               :iterate
               :babel
               :i4-diet-utils
               :cl-async
               :blackbird)
  :components ((:file "package")
               (:file "specials")
               (:file "conditions")
               (:file "binary")
               (:file "frame")
               (:file "message")
               (:file "client")))
