(in-package :cl-mqtt)

(defun append-to-vector (target-array source-array &optional (start 0) (end (length source-array)))
  (let* ((to-copy (- end start))
         (target-pos (fill-pointer target-array))
         (new-end (+ target-pos to-copy)))
    (if (> new-end (array-total-size target-array))
        (setf target-array
              (adjust-array target-array (* 2 new-end) :fill-pointer new-end))
        (setf (fill-pointer target-array) new-end))
    (replace target-array source-array :start1 target-pos :end1 new-end :start2 start)
    to-copy))

(defmacro define-message-accessor (name slot size position &optional from-raw to-raw)
  (flet ((maybe-convert (expr converter)
           (if (null converter)
               expr
               `(,converter ,expr))))
    (let ((accessor-name (symbolicate 'mqtt-message- name))
          (slot-accessor (symbolicate 'mqtt-message- slot))
          (initarg (make-keyword name)))
      (with-gensyms (msg value)
        `(progn
           (defun ,accessor-name (,msg)
             ,(maybe-convert
               (if size
                   `(ldb (byte ,size ,position) (,slot-accessor ,msg))
                   `(,slot-accessor ,msg))
               from-raw))
           (defun (setf ,accessor-name) (,value ,msg)
             (setf (,slot-accessor ,msg)
                   ,(if size
                        `(dpb ,(maybe-convert value to-raw)
                              (byte ,size ,position)
                              (,slot-accessor ,msg))
                        (maybe-convert value to-raw))))
           (setf (gethash ,initarg *mqtt-message-extra-initargs*)
                 #'(setf ,accessor-name)))))))

(defun expand-field-ref (msg name)
  (list (symbolicate 'mqtt-message- name) msg))

(defun expand-field-let-clause (msg field)
  (destructuring-bind (name type &optional multiplicity) field
    (let* ((accessor-name (symbolicate 'mqtt-message- name))
           (value-expr `(,accessor-name ,msg)))
      (if (eq :unused name)
          (assert (eq :u8 type) () "only :u8 can be :unused")
          (list name
                (let ((expr (ecase type
                              ((:u8 :u16 :bytes) value-expr)
                              (:str `(babel:string-to-octets
                                      ,value-expr
                                      :encoding :utf-8)))))
                  (if multiplicity
                      `(when (plusp ,(expand-field-ref msg multiplicity))
                         ,expr)
                      expr)))))))

(defun expand-field-len (msg field)
  (destructuring-bind (name type &optional multiplicity) field
    (let ((expr (ecase type
                  (:u8 1)
                  (:u16 2)
                  (:bytes `(length ,name))
                  (:str `(+ 2 (length ,name))))))
      (if multiplicity
          `(if (plusp ,(expand-field-ref msg multiplicity))
               ,expr
               0)
          expr))))

(defun expand-field-store (msg buf field)
  (destructuring-bind (name type &optional multiplicity)
      field
    (let ((exprs
            (if (eq :unused name)
                `((vector-push-extend 0 ,buf))
                (ecase type
                  (:u8
                   `((vector-push-extend ,name ,buf)))
                  (:u16
                   `((vector-push-extend (ldb (byte 8 8) ,name) ,buf)
                     (vector-push-extend (ldb (byte 8 0) ,name) ,buf)))
                  (:bytes
                   `((append-to-vector ,buf ,name)))
                  (:str
                   (with-gensyms (strlen)
                     `((let ((,strlen (length ,name)))
                         (vector-push-extend (ldb (byte 8 8) ,strlen) ,buf)
                         (vector-push-extend (ldb (byte 8 0) ,strlen) ,buf)
                         (append-to-vector ,buf ,name)))))))))
      (if multiplicity
          `((when (plusp ,(expand-field-ref msg multiplicity))
              ,@exprs))
          exprs))))

(defun expand-build-packet (type fields)
  (let ((build-func-name (symbolicate 'build-packet- type)))
    (with-gensyms (buf msg len)
      `((defun ,build-func-name (,buf ,msg)
          (let* (,@(remove nil (mapcar (curry #'expand-field-let-clause msg) fields))
                 (,len (+ ,@(mapcar (curry #'expand-field-len msg) fields))))
            (vector-push-extend (mqtt-message-fixed-header ,msg) ,buf)
            (store-packet-length ,buf ,len)
            ,@(mappend (curry #'expand-field-store msg buf) fields)))
        (setf (gethash ,type *mqtt-packet-builders*)
              ',build-func-name)))))

(defun expand-load-field (msg field)
  (destructuring-bind (name type &optional multiplicity)
      field
    (let ((accessor-name (symbolicate 'mqtt-message- name)))
      (let ((expr
              (cond ((not (eq :unused name))
                     `(setf (,accessor-name ,msg)
                            (,(ecase type
                                (:u8 'load-u8)
                                (:u16 'load-u16)
                                (:str 'load-str)
                                (:bytes 'load-bytes)))))
                    ((eq :u8 type)
                     `(load-skip))
                    (t
                     (error "only :u8 can be :unused")))))
        (if multiplicity
            `(when (plusp ,(expand-field-ref msg multiplicity))
               ,expr)
            expr)))))

(defun expand-parse-packet (type fields)
  (let ((parse-func-name (symbolicate 'parse-packet- type)))
    (with-gensyms (buf msg pos total len)
      `((defun ,parse-func-name (,buf ,msg ,pos)
          (let ((,total (length ,buf)))
            (labels ((load-u8 ()
                       (when (>= ,pos ,total)
                         (mqtt-error "packet too short"))
                       (prog1
                           (aref ,buf ,pos)
                         (incf ,pos)))
                     (load-u16 ()
                       (when (>= ,pos (1- ,total))
                         (mqtt-error "packet too short"))
                       (prog1
                           (+ (ash (aref ,buf ,pos) 8)
                              (aref ,buf (1+ ,pos)))
                         (incf ,pos 2)))
                     (load-str ()
                       (let ((,len (load-u16)))
                         (when (> ,pos (- ,total ,len))
                           (mqtt-error "packet too short"))
                         (prog1
                             (handler-case
                                 (babel:octets-to-string ,buf
                                                         :start ,pos
                                                         :end (+ ,pos ,len)
                                                         :errorp t
                                                         :encoding :utf-8)
                               (babel:character-coding-error ()
                                 (mqtt-error "invalid utf-8 string")))
                           (incf ,pos ,len))))
                     (load-bytes ()
                       (prog1
                           (subseq ,buf ,pos)
                         (setf ,pos ,total)))
                     (load-skip ()
                       (incf ,pos)))
              (declare (ignorable #'load-u8 #'load-u16 #'load-str #'load-bytes #'load-skip))
              (setf (mqtt-message-fixed-header ,msg) (aref ,buf 0))
              ,@(mapcar (curry #'expand-load-field msg) fields)
              (unless (= ,pos ,total)
                (mqtt-error "excess content in the packet")))))
        (setf (gethash ,type *mqtt-packet-parsers*)
              ',parse-func-name)))))

(defmacro define-packet (type &body fields)
  `(progn
     ,@(expand-build-packet type fields)
     ,@(expand-parse-packet type fields)))
