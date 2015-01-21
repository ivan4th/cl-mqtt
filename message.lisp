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

(in-package :cl-mqtt)

(defstruct (mqtt-message
            (:constructor %make-mqtt-message
                (&key fixed-header
                   protocol-name
                   protocol-level
                   connect-flags
                   connect-keepalive
                   client-id
                   mid
                   topic
                   payload
                   subscription-qos-raw
                 &allow-other-keys)))
  (fixed-header 0 :type (unsigned-byte 8))
  (protocol-name "" :type string)
  (protocol-level 0 :type (unsigned-byte 8))
  (connect-flags 0 :type (unsigned-byte 8))
  (connect-keepalive 0 :type (unsigned-byte 16))
  (ret-code-raw 0 :type (unsigned-byte 8))
  (client-id "" :type string)
  (mid 0 :type (unsigned-byte 16))
  (topic "" :type string)
  (payload (make-array 0 :element-type '(unsigned-byte 8)) :type (vector (unsigned-byte 8)))
  (subscription-qos-raw 0 :type (unsigned-byte 8)))

(defun packet-type-to-raw (type)
  (assert type () "NIL packet type")
  (or (position type *control-packet-types*)
      (error "bad MQTT packet type ~s" type)))

(defun packet-type-from-raw (raw-type)
  (or (aref *control-packet-types* raw-type)
      (mqtt-error "bad packet type #x~2,'0x" raw-type)))

(defun ret-code-to-raw (ret-code)
  (or (position ret-code *ret-codes*)
      (error "bad connack ret code ~s" ret-code)))

;; Unlike packet type which is limited to 4 bits,
;; ret code may be outside acceptable array bounds.
;; There are no reserved (NIL) values in this table though.
(defun ret-code-from-raw (ret-code)
  (if (< ret-code (length *ret-codes*))
      (aref *ret-codes* ret-code)
      (error "invalid connack ret code ~s" ret-code)))

(defun bool-from-raw (value) (plusp value))
(defun bool-to-raw (value) (if value 1 0))

(define-message-accessor type fixed-header 4 4 packet-type-from-raw packet-type-to-raw)
(define-message-accessor dup fixed-header 1 3)
(define-message-accessor qos fixed-header 2 1)
(define-message-accessor retain fixed-header 1 0 bool-from-raw bool-to-raw)

(define-message-accessor connect-username-flag connect-flags 1 7)
(define-message-accessor connect-password-flag connect-flags 1 6)
(define-message-accessor connect-will-retain connect-flags 1 5)
(define-message-accessor connect-will-qos connect-flags 2 3)
(define-message-accessor connect-will-flag connect-flags 1 2)
(define-message-accessor connect-clean-session-flag connect-flags 1 1)

(define-message-accessor ret-code ret-code-raw nil nil ret-code-from-raw ret-code-to-raw)
(define-message-accessor subscription-qos subscription-qos-raw 2 0)

(defun make-mqtt-message (&rest initargs)
  (when-let ((payload (getf initargs :payload)))
    (unless (typep payload '(vector (unsigned-byte 8)))
      (setf (getf initargs :payload)
            (coerce payload '(vector (unsigned-byte 8))))))
  (let ((msg (apply #'%make-mqtt-message initargs)))
    (doplist (k v initargs)
      (when-let ((setter (gethash k *mqtt-message-extra-initargs*)))
        (funcall setter v msg)))
    msg))

;; Optional third item in field spec may specify condition
;; for optional fields. Condition may be just a field name.
;; The optional field must be present if cond field is > 0
;; (this will work for QoS, too)

;; optional field spec can be also used to specify lists using '+'
;; (i.e. consume till the end of the packet)

(define-packet :connect
  (protocol-name :str)
  (protocol-level :u8)
  (connect-flags :u8)
  (connect-keepalive :u16)
  (client-id :str))

(define-packet :connack
  (:unused :u8)
  (ret-code-raw :u8))

(define-packet :publish
  (topic :str)
  (mid :u16 qos)
  (payload :bytes))

(define-packet :puback
  (mid :u16))

(define-packet :pubrec
  (mid :u16))

(define-packet :pubrel
  (mid :u16))

(define-packet :pubcomp
  (mid :u16))

;; FIXME: actually, it's possible to subscribe for multiple topics
;; via the single request
(define-packet :subscribe
  (mid :u16)
  (topic :str)
  (subscription-qos-raw :u8))

(define-packet :suback
  (mid :u16)
  (subscription-qos-raw :u8))

(define-packet :unsubscribe
  (mid :u16)
  (topic :str))

(define-packet :unsuback
  (mid :u16))

(define-packet :pingreq)

(define-packet :pingresp)

(define-packet :disconnect)

(defun build-packet (buf message)
  (funcall (or (gethash (mqtt-message-type message) *mqtt-packet-builders*)
               (error "cannot build message of type ~s" (mqtt-message-type message)))
           buf message)
  buf)

(defun parse-packet (buf var-header-start &optional (message (make-mqtt-message)))
  (let ((packet-type (packet-type-from-raw (ldb (byte 4 4) (aref buf 0)))))
    (funcall (or (gethash packet-type *mqtt-packet-parsers*)
                 (mqtt-error "cannot parse message of type ~s" packet-type))
             buf message var-header-start)
    message))

;; TBD: PRINT-OBJECT for MQTT-MESSAGE
