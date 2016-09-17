;;;; Copyright (c) 2011-2016 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :mezzano.supervisor)

(defun initialize-boot-cpu ()
  (let* ((addr (align-up (- (sys.int::lisp-object-address sys.int::*bsp-info-vector*)
                            sys.int::+tag-object+)
                         1024)))
    (flet ((gen-vector (offset common entry)
             (let ((base (+ addr offset))
                   (common-entry (sys.int::%object-ref-signed-byte-64
                                  common
                                  sys.int::+function-entry-point+))
                   (entry-fref (sys.int::%object-ref-t
                                entry
                                sys.int::+symbol-function+)))
               ;; sub sp, sp, #x30. Space for the iret frame & frame pointer
               (setf (sys.int::memref-unsigned-byte-32 base 0) #xD100C3FF)
               ;; str x29, [sp]
               (setf (sys.int::memref-unsigned-byte-32 base 1) #xF90003FD)
               ;; ldr x29, [fn]
               (setf (sys.int::memref-unsigned-byte-32 base 2) #x5800005D)
               ;; b common-entry
               (let ((entry-rel (- common-entry (+ base 12))))
                 (setf (sys.int::memref-unsigned-byte-32 base 3)
                       (logior #x14000000
                               (ldb (byte 26 2) entry-rel))))
               ;; fn: entry-fref
               (setf (sys.int::memref-t base 2) entry-fref)))
           (gen-invalid (offset)
             ;; HLT #1
             (setf (sys.int::memref-unsigned-byte-32 (+ addr offset) 0) #xD4400020)))
      (declare (dynamic-extent #'gen-vector #'gen-invalid))
      (gen-vector #x000 #'%el0-common '%synchronous-handler)
      (gen-vector #x080 #'%el0-common '%irq-handler)
      (gen-vector #x100 #'%el0-common '%fiq-handler)
      (gen-vector #x180 #'%el0-common '%serror-handler)
      (gen-vector #x200 #'%elx-common '%synchronous-handler)
      (gen-vector #x280 #'%elx-common '%irq-handler)
      (gen-vector #x300 #'%elx-common '%fiq-handler)
      (gen-vector #x380 #'%elx-common '%serror-handler)
      (dotimes (i 8)
        (gen-invalid (+ #x400 (* i #x80)))))
    (%load-cpu-bits (+ sys.int::*bsp-wired-stack-base* sys.int::*bsp-wired-stack-size*)
                    'bsp
                    addr)))

(sys.int::define-lap-function %load-cpu-bits ((sp-el1 cpu-data vbar-el1))
  ;; Switch to SP_EL1.
  (mezzano.lap.arm64:msr :spsel 1)
  ;; Unbox sp-el1.
  (mezzano.lap.arm64:add :x9 :xzr :x0 :asr #.sys.int::+n-fixnum-bits+)
  ;; Set SP_EL1.
  (mezzano.lap.arm64:add :sp :x9 0)
  ;; Move back to SP_EL0.
  (mezzano.lap.arm64:msr :spsel 0)
  ;; Set the current CPU register.
  (mezzano.lap.arm64:orr :x27 :xzr :x1)
  ;; Set VBAR_EL1.
  (mezzano.lap.arm64:add :x9 :xzr :x2 :asr #.sys.int::+n-fixnum-bits+)
  (mezzano.lap.arm64:msr :vbar-el1 :x9)
  (mezzano.lap.arm64:ret))

(sys.int::define-lap-function local-cpu-info (())
  (mezzano.lap.arm64:orr :x0 :xzr :x27)
  (mezzano.lap.arm64:movz :x5 #.(ash 1 sys.int::+n-fixnum-bits+))
  (mezzano.lap.arm64:ret))

(sys.int::define-lap-function %el0-common ()
  ;; Stack looks like:
  ;; +40 pad (ss on x86-64)
  ;; +32 sp (not set)
  ;; +24 cspr (not set)
  ;; +16 pad (cs on x86-64)
  ;; +8 pc (not set)
  ;; +0 x29 (frame pointer)
  ;; x29 contains function to branch to.
  ;; Push registers in the same order as x86-64.
  (mezzano.lap.arm64:stp :x5 :x9 (:pre :sp -16))
  (mezzano.lap.arm64:stp :x6 :x10 (:pre :sp -16))
  (mezzano.lap.arm64:stp :x12 :x11 (:pre :sp -16))
  (mezzano.lap.arm64:stp :x1 :x0 (:pre :sp -16))
  (mezzano.lap.arm64:stp :x3 :x2 (:pre :sp -16))
  (mezzano.lap.arm64:stp :x7 :x4 (:pre :sp -16))
  (mezzano.lap.arm64:stp :x14 :x13 (:pre :sp -16))
  ;; Read & save SP_EL0
  (mezzano.lap.arm64:mrs :x9 :sp-el0)
  (mezzano.lap.arm64:str :x9 (:sp #x90))
  ;; Read & save ELR_EL1
  (mezzano.lap.arm64:mrs :x9 :elr-el1)
  (mezzano.lap.arm64:str :x9 (:sp #x78))
  ;; Read & save SPSR_EL1
  (mezzano.lap.arm64:mrs :x9 :spsr-el1)
  (mezzano.lap.arm64:str :x9 (:sp #x88))
  ;; Set up for call to handler.
  (mezzano.lap.arm64:orr :x7 :xzr :x29)
  (mezzano.lap.arm64:movz :x5 #.(ash 2 sys.int::+n-fixnum-bits+)) ; 2 args
  ;; Build frame.
  (mezzano.lap.arm64:add :x29 :sp #x70)
  ;; Build interrupt frame object.
  (mezzano.lap.arm64:sub :sp :sp 16)
  (mezzano.lap.arm64:movz :x9 #.(ash sys.int::+object-tag-interrupt-frame+ sys.int::+object-type-shift+))
  (mezzano.lap.arm64:str :x9 (:sp))
  (mezzano.lap.arm64:add :x9 :xzr :x29 :lsl #.sys.int::+n-fixnum-bits+)
  (mezzano.lap.arm64:str :x9 (:sp 8))
  (mezzano.lap.arm64:add :x0 :sp #.sys.int::+tag-object+)
  (:gc :frame :interrupt t)
  ;; Call handler.
  (mezzano.lap.arm64:ldr :x9 (:object :x7 #.sys.int::+fref-entry-point+))
  (mezzano.lap.arm64:blr :x9)
  (mezzano.lap.arm64:hlt 3))

(sys.int::define-lap-function %elx-common ()
  ;; Stack looks like:
  ;; +40 pad (ss on x86-64)
  ;; +32 sp (not set)
  ;; +24 cspr (not set)
  ;; +16 pad (cs on x86-64)
  ;; +8 pc (not set)
  ;; +0 x29 (frame pointer)
  ;; x29 contains function to branch to.
  ;; Push registers in the same order as x86-64.
  (mezzano.lap.arm64:stp :x5 :x9 (:pre :sp -16))
  (mezzano.lap.arm64:stp :x6 :x10 (:pre :sp -16))
  (mezzano.lap.arm64:stp :x12 :x11 (:pre :sp -16))
  (mezzano.lap.arm64:stp :x1 :x0 (:pre :sp -16))
  (mezzano.lap.arm64:stp :x3 :x2 (:pre :sp -16))
  (mezzano.lap.arm64:stp :x7 :x4 (:pre :sp -16))
  (mezzano.lap.arm64:stp :x14 :x13 (:pre :sp -16))
  ;; Read & save SP.
  (mezzano.lap.arm64:add :x9 :sp 0)
  (mezzano.lap.arm64:str :x9 (:sp #x90))
  ;; Read & save ELR_EL1
  (mezzano.lap.arm64:mrs :x9 :elr-el1)
  (mezzano.lap.arm64:str :x9 (:sp #x78))
  ;; Read & save SPSR_EL1
  (mezzano.lap.arm64:mrs :x9 :spsr-el1)
  (mezzano.lap.arm64:str :x9 (:sp #x88))
  ;; Set up for call to handler.
  (mezzano.lap.arm64:orr :x7 :xzr :x29)
  (mezzano.lap.arm64:movz :x5 #.(ash 2 sys.int::+n-fixnum-bits+)) ; 2 args
  ;; Build frame.
  (mezzano.lap.arm64:add :x29 :sp #x68)
  ;; Build interrupt frame object.
  (mezzano.lap.arm64:sub :sp :sp 16)
  (mezzano.lap.arm64:movz :x9 #.(ash sys.int::+object-tag-interrupt-frame+ sys.int::+object-type-shift+))
  (mezzano.lap.arm64:str :x9 (:sp))
  (mezzano.lap.arm64:add :x9 :xzr :x29 :lsl #.sys.int::+n-fixnum-bits+)
  (mezzano.lap.arm64:str :x9 (:sp 8))
  (mezzano.lap.arm64:add :x0 :sp #.sys.int::+tag-object+)
  (:gc :frame :interrupt t)
  ;; Call handler.
  (mezzano.lap.arm64:ldr :x9 (:object :x7 #.sys.int::+fref-entry-point+))
  (mezzano.lap.arm64:blr :x9)
  (mezzano.lap.arm64:hlt 4))