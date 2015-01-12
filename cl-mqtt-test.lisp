(defpackage :cl-mqtt.tests
  (:use :cl :alexandria :iterate :i4-diet-utils :vtf))

(in-package :cl-mqtt.tests)

(defparameter *message-tests*
  '((:connect
     #(#x10 ;; Fixed header, message type=0x01 (CONNECT), DUP=0, QoS=0, Retain=0
       #x1F ;; Remaining length=31
       #x00 #x04 ;; Protocol Name -- len
       #x4d #x51 #x54 #x54 ;; Protocol Name -- MQTT for MQTT 3.1.1
       #x04 ;; Protocol level -- 4 for MQTT 3.1.1
       #x02 ;; Flags:
       ;; Username Flag: 0
       ;; Password Flag: 0
       ;; Will Retain Flag: 0
       ;; Will QoS: 0 (2 bits)
       ;; Will Flag: 0
       ;; Clean Session Flag: 1
       ;; (bit 0 is reserved)
       #x00 #x3c ;; Keep Alive (secs): 60
       #x00 #x13 ;; Client ID len = 19
       #x6d #x6f #x73 #x71 #x73 #x75 #x62 #x2f ;; Client ID = mosqsub/10224-think
       #x31 #x30 #x32 #x32 #x34 #x2d #x74 #x68
       #x69 #x6e #x6b)
     (:type :connect
      :dup 0
      :qos 0
      :retain 0
      :protocol-name "MQTT"
      :protocol-level 4
      :connect-username-flag 0
      :connect-password-flag 0
      :connect-will-qos 0
      :connect-will-flag 0
      :connect-clean-session-flag 1
      :connect-keepalive 60
      :client-id "mosqsub/10224-think"))
    #++
    (:connect
     #(#x10 ;; Fixed header, message type=0x01 (CONNECT), DUP=0, QoS=0, Retain=0
       #x21 ;; Remaining length=33
       #x00 #x06 ;; Protocol Name -- len
       #x4d #x51 #x49 #x73 #x64 #x70 ;; Protocol Name -- string "MQIsdp" (should be MQTT in MQTT 3.1.1)
       #x03      ;; Protocol level -- 3 (should be 4 in MQTT 3.1.1)
       #x02      ;; Flags:
       ;; Username Flag: 0
       ;; Password Flag: 0
       ;; Will Retain Flag: 0
       ;; Will QoS: 0 (2 bits)
       ;; Will Flag: 0
       ;; Clean Session Flag: 1
       ;; (bit 0 is reserved)
       #x00 #x3c ;; Keep Alive (secs): 60
       #x00 #x13 ;; Client ID len = 19
       #x6d #x6f #x73 #x71 #x73 #x75 #x62 #x2f ;; Client ID = mosqsub/10224-think
       #x31 #x30 #x32 #x32 #x34 #x2d #x74 #x68
       #x69 #x6e #x6b)
     (:type :connect
      :dup 0
      :qos 0
      :retain 0
      :protocol-name "MQIsdp"
      :protocol-level 3
      :connect-username-flag 0
      :connect-password-flag 0
      :connect-will-qos 0
      :connect-will-flag 0
      :connect-clean-session-flag 1
      :connect-keepalive 60
      :client-id "mosqsub/10224-think"))

    (:connack
     #(#x20 ;; Fixed header, message type=0x02 (CONNACK), DUP=0, QoS=0, Retain=0
       #x02 ;; Remaining length=2
       #x00 ;; (unused)
       #x00 ;; Return code = 0x00 (connection accepted)
       )
     (:type :connack
      :dup 0
      :qos 0
      :retain 0
      :ret-code :accepted))

    (:subscribe
     #(#x82 ;; Fixed header, message type=0x08 (SUBSCRIBE), DUP=0, QoS=1, Retain=0
       #x06 ;; Remaining length=6
       #x00 #x01 ;; Message ID=1
       #x00 #x01 ;; Topic len=1
       #x23      ;; Topic: '#'
       #x00      ;; Requested QoS = 0 (use lower 2 bits)
       )
     (:type :subscribe
      :dup 0
      :qos 1
      :retain 0
      :mid 1
      :topic "#"
      :subscription-qos 0))

    (:suback
     #(#x90 ;; Fixed header, message type=0x08 (SUBACK), DUP=0, QoS=0, Retain=0
       #x03 ;; Remaining length=3
       #x00 #x01 ;; Message ID=1
       #x00      ;; Granted QoS=0 (use lower 2 bits)
       )
     (:type :suback
      :dup 0
      :qos 0
      :retain 0
      :mid 1
      :subscription-qos 0))

    (:publish
     #(#x31 ;; Fixed header, message type=0x03 (PUBLISH), DUP=0, QoS=0, Retain=1
       #x32 ;; Remaining length=50
       #x00 #x20 ;; Topic len=32
       ;; Topic: '/devices/zonebeast011c/meta/name'
       #x2f #x64 #x65 #x76 #x69 #x63 #x65 #x73
       #x2f #x7a #x6f #x6e #x65 #x62 #x65 #x61
       #x73 #x74 #x30 #x31 #x31 #x63 #x2f #x6d
       #x65 #x74 #x61 #x2f #x6e #x61 #x6d #x65
       ;; Payload: 'Zone Beast 01:1c'
       #x5a #x6f #x6e #x65 #x20 #x42 #x65 #x61
       #x73 #x74 #x20 #x30 #x31 #x3a #x31 #x63)
     (:type :publish
      :dup 0
      :qos 0
      :retain 1
      :topic "/devices/zonebeast011c/meta/name"
      :payload #.(babel:string-to-octets "Zone Beast 01:1c" :encoding :utf-8)))

    (:publish1
     #(#x33 ;; Fixed header, message type=0x03 (PUBLISH), DUP=0, QoS=1, Retain=1
       #x34 ;; Remaining length=50
       #x00 #x20 ;; Topic len=32
       ;; Topic: '/devices/zonebeast011c/meta/name'
       #x2f #x64 #x65 #x76 #x69 #x63 #x65 #x73
       #x2f #x7a #x6f #x6e #x65 #x62 #x65 #x61
       #x73 #x74 #x30 #x31 #x31 #x63 #x2f #x6d
       #x65 #x74 #x61 #x2f #x6e #x61 #x6d #x65
       #x00 #x02 ;; Message ID=2
       ;; Payload: 'Zone Beast 01:1c'
       #x5a #x6f #x6e #x65 #x20 #x42 #x65 #x61
       #x73 #x74 #x20 #x30 #x31 #x3a #x31 #x63)
     (:type :publish
      :dup 0
      :qos 1
      :retain 1
      :topic "/devices/zonebeast011c/meta/name"
      :mid 2
      :payload #.(babel:string-to-octets "Zone Beast 01:1c" :encoding :utf-8)))

    (:publish2
     #(#x35 ;; Fixed header, message type=0x03 (PUBLISH), DUP=0, QoS=2, Retain=1
       #x09 ;; Remaining length=9
       #x00 #x04 ;; Topic len=4
       ;; Topic: '/d/z'
       #x2f #x64 #x2f #x7a
       #x02 #x03 ;; Message ID=515
       ;; Payload: '1'
       #x31)
     (:type :publish
      :dup 0
      :qos 2
      :retain 1
      :topic "/d/z"
      :mid 515
      :payload #(#x31)))

    (:pingreq
     #(#xc0 ;; Fixed header, message type=0x0c (PINGREQ)
       #x00 ;; Remaining length=0
       )
     (:type :pingreq))

    (:pingresp
     #(#xd0 ;; Fixed header, message type=0x0d (PINGRESP)
       #x00 ;; Remaining length=0
       )
     (:type :pingresp))

    (:disconnect
     #(#xe0 ;; Fixed header, message type=0x0e (DISCONNECT)
       #x00 ;; Remaining length=0
       )
     (:type :disconnect))))

(defstruct (message-test (:type list))
  type packet message)

(deftest test-frame-reader () ()
  (dolist (packet (mapcar #'message-test-packet *message-tests*))
    (let ((called-p nil))
      (flet ((cbk (buf var-header-start)
               (is-false called-p)
               (is (equalp buf packet))
               (is (= 2 var-header-start))
               (setf called-p t)))
        (let ((reader (mqtt::make-mqtt-frame-reader #'cbk)))
          (macrolet ((chk (&body body)
                       `(progn
                          (setf called-p nil)
                          ,@body
                          (is-true called-p))))
            (chk
             (funcall reader packet))
            (chk
             (iter (for i from 0 below (length packet))
                   (funcall reader (subseq packet i (1+ i)))))
            (iter (for i from 1 below (1- (length packet)))
                  (chk
                   (funcall reader (subseq packet 0 i))
                   (funcall reader (subseq packet i))))))))))

(deftest test-packet-building () ()
  ;; TBD: test all
  (dolist (message-test *message-tests*)
    (let ((message (apply #'mqtt::make-mqtt-message
                          (message-test-message message-test)))
          (buf (make-array 1024 :element-type '(unsigned-byte 8)
                                :fill-pointer 0
                                :adjustable t)))
      (mqtt::build-packet buf message)
      (dbg-show buf)
      (is (equalp (message-test-packet message-test) buf)))))

(deftest test-packet-parsing () ()
  (dolist (message-test *message-tests*)
    (let* ((expected-message (apply #'mqtt::make-mqtt-message
                                    (message-test-message message-test)))
           (actual-message nil)
           (reader (mqtt::make-mqtt-frame-reader
                    #'(lambda (act-buf var-header-start)
                        (setf actual-message (mqtt::parse-packet act-buf var-header-start))))))
      (funcall reader (message-test-packet message-test))
      ;; this ignores case in string comparison, but this will hardly
      ;; cause any false positives
      (is (equalp expected-message actual-message)))))

;; TBD: multi-topic subscriptions (need (* :str), (* :u8) types)
;; TBD: use simpler sample publish message(s)
;; TBD: frame reader length decoder test based on values returned from the reader
;; TBD: handle DUPs
;; TBD: (note for homA stuff: subscribe w/QoS=1 for metadata topics)
;; TBD: auth
;; TBD: will
;; TBD: test parsing bad packets
;; TBD: MQTT 3.1.1

;; TBD: (note) need to send PINGREQ / PINGRESP at some interval < keep alive time
