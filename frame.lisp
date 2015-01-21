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

(defun make-mqtt-frame-reader (callback)
  (let ((state :start)
        (buf (make-array *initial-input-buffer-size*
                         :adjustable t
                         :fill-pointer 0
                         :element-type '(unsigned-byte 8)))
        var-header-start
        len)
    #'(lambda (bytes)
        (assert (> (length bytes) 0))
        (let ((pos 0))
          (iter (while (< pos (length bytes)))
                #++
                (dbg "in: ~s ~s ~s" state pos len)
                (setf state
                      (flet ((finished ()
                               (funcall callback buf var-header-start)
                               (setf var-header-start 0 len 1)
                               :start))
                        (ecase state
                          (:start
                           (setf (fill-pointer buf) 1
                                 len 0
                                 var-header-start 1
                                 (aref buf 0) (elt bytes pos))
                           (incf pos)
                           0)
                          ((0 1 2 3)
                           (let ((b (aref bytes pos)))
                             (vector-push-extend b buf)
                             (setf len (+ (ash (logand b #x7f) (* state 7)) len))
                             (incf pos)
                             (incf var-header-start)
                             (cond ((and (not (logbitp 7 b))
                                         (zerop len))
                                    (finished))
                                   ((not (logbitp 7 b))
                                    :body)
                                   ((eq state 3)
                                    (mqtt-error "invalid length field"))
                                   (t (1+ state)))))
                          (:body
                           (when (> len *max-packet-len*)
                             (mqtt-error "max length exceeded"))
                           (cond ((zerop len)
                                  (finished))
                                 (t
                                  (let ((count (append-to-vector
                                                buf bytes pos
                                                (min (length bytes) (+ pos len)))))
                                    (incf pos count)
                                    (cond ((zerop (decf len count))
                                           (finished))
                                          (t :body)))))))))
                #++
                (dbg "out: ~s ~s ~s" state pos len)))
        (values buf len))))

(defun store-packet-length (buf len)
  (iter (let ((b (ldb (byte 7 0) len)))
          (setf len (ash len -7))
          (vector-push-extend (if (zerop len) b (logior #x80 b)) buf))
        (while (plusp len))))
