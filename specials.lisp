(in-package :cl-mqtt)

(defparameter *initial-input-buffer-size* 1024)
(defparameter *max-packet-len* (* 1024 1024)) ;; FIXME (should be configurable)
(defvar *mqtt-message-extra-initargs* (make-hash-table))
(defvar *mqtt-packet-builders* (make-hash-table))
(defvar *mqtt-packet-parsers* (make-hash-table))

(defparameter *control-packet-types*
  #(nil
    :connect                            ; 1
    :connack                            ; 2
    :publish                            ; 3
    :puback                             ; 4
    :pubrec                             ; 5
    :pubrel                             ; 6
    :pubcomp                            ; 7
    :subscribe                          ; 8
    :suback                             ; 9
    :unsubscribe                        ; 10
    :unsuback                           ; 11
    :pingreq                            ; 12
    :pingresp                           ; 13
    :disconnect                         ; 14
    nil))

(defparameter *ret-codes*
  #(:accepted
    :unacceptable-protocol-version
    :identifier-rejected
    :server-unavailable
    :bad-user-name-or-password
    :not-authorized))
