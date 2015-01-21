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
