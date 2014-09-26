(in-package :mezzanine.supervisor)

;;; FIXME: Should not be here.
;;; >>>>>>

(defun string-length (string)
  (assert (sys.int::character-array-p string))
  (sys.int::%array-like-ref-t string 3))

(defun sys.int::assert-error (test-form datum &rest arguments)
  (debug-write-string "Assert error ")
  (debug-write-line datum)
  (sys.int::%sti)
  (loop))

;; Back-compat.
(defmacro with-gc-deferred (&body body)
  `(with-pseudo-atomic ,@body))

(defun call-with-gc-deferred (thunk)
  (call-with-pseudo-atomic thunk))

(defun find-extent-named (name largep)
  (cond ((store-extent-p name) name)
        (t (dolist (extent *extent-table*
                    (error "can't find extent..."))
             (when (and (or (eql (store-extent-type extent) name)
                            (and (eql name :wired)
                                 (eql (store-extent-type extent) :pinned)
                                 (store-extent-wired-p extent)))
                        (not (store-extent-finished-p extent))
                        (eql (store-extent-large-p extent) largep))
               (return extent))))))

(defun stack-base (stack)
  (car stack))

(defun stack-size (stack)
  (cdr stack))

;; TODO: Actually allocate virtual memory.
(defun %allocate-stack (size)
  ;; 4k align the size.
  (setf size (logand (+ size #xFFF) (lognot #xFFF)))
  (let* ((addr (with-symbol-spinlock (mezzanine.runtime::*wired-allocator-lock*)
                 (prog1 (logior (+ sys.int::*stack-area-bump* #x200000)
                                (ash sys.int::+address-tag-stack+ sys.int::+address-tag-shift+))
                   ;; 2m align the memory region.
                   (incf sys.int::*stack-area-bump* (+ (logand (+ size #x1FFFFF) (lognot #x1FFFFF))
                                                       #x200000)))))
         (stack (sys.int::cons-in-area addr size :wired)))
    ;; Allocate blocks.
    (with-mutex (*vm-lock*)
      (dotimes (i (ceiling size #x1000))
        (allocate-new-block-for-virtual-address (+ addr (* i #x1000))
                                                (logior sys.int::+block-map-present+
                                                        sys.int::+block-map-writable+
                                                        sys.int::+block-map-zero-fill+))))
    stack))

;; TODO.
(defun sleep (seconds)
  nil)

(defun sys.int::raise-undefined-function (fref)
  (debug-write-string "Undefined function ")
  (let ((name (sys.int::%array-like-ref-t fref sys.int::+fref-name+)))
    (cond ((consp name)
           (debug-write-string "(")
           (debug-write-string (symbol-name (car name)))
           (debug-write-string " ")
           (debug-write-string (symbol-name (car (cdr name))))
           (debug-write-line ")"))
          (t (debug-write-line (symbol-name name)))))
  (sys.int::%sti)
  (loop))

(defun sys.int::raise-unbound-error (symbol)
  (debug-write-string "Unbound symbol ")
  (debug-write-line (symbol-name symbol))
  (sys.int::%sti)
  (loop))

(in-package :sys.int)

(defstruct (cold-stream (:area :wired)))

(in-package :mezzanine.supervisor)

(defvar *cold-unread-char*)

(defun sys.int::cold-write-char (c stream)
  (declare (ignore stream))
  (debug-write-char c))

(defun sys.int::cold-start-line-p (stream)
  (declare (ignore stream))
  (debug-start-line-p))

(defun sys.int::cold-read-char (stream)
  (declare (ignore stream))
  (cond (*cold-unread-char*
         (prog1 *cold-unread-char*
           (setf *cold-unread-char* nil)))
        (t (debug-read-char))))

(defun sys.int::cold-unread-char (character stream)
  (declare (ignore stream))
  (when *cold-unread-char*
    (error "Multiple unread-char!"))
  (setf *cold-unread-char* character))

;;; <<<<<<

(defvar *boot-information-page*)


(defconstant +n-physical-buddy-bins+ 32)
(defconstant +buddy-bin-size+ 16)

(defconstant +boot-information-boot-uuid-offset+ 0)
(defconstant +boot-information-physical-buddy-bins-offset+ 16)
(defconstant +boot-information-framebuffer-physical-address+ 528)
(defconstant +boot-information-framebuffer-width+ 536)
(defconstant +boot-information-framebuffer-pitch+ 544)
(defconstant +boot-information-framebuffer-height+ 552)
(defconstant +boot-information-framebuffer-layout+ 560)
(defconstant +boot-information-module-base+ 568)
(defconstant +boot-information-module-limit+ 576)

(defun boot-uuid (offset)
  (check-type offset (integer 0 15))
  (sys.int::memref-unsigned-byte-8 *boot-information-page* offset))

;; This thunk exists purely so that the GC knows when to stop unwinding the initial process' stack.
;; I'd like to get rid of it somehow...
(sys.int::define-lap-function sys.int::%%bootloader-entry-point ()
  (:gc :no-frame)
  ;; Drop the bootloader's return address.
  (sys.lap-x86::add64 :rsp 8)
  ;; Call the real entry point.
  (sys.lap-x86:mov64 :r13 (:function sys.int::bootloader-entry-point))
  (sys.lap-x86:call (:object :r13 #.sys.int::+fref-entry-point+))
  (sys.lap-x86:ud2))

(defvar *boot-hook-lock* (make-mutex "Boot Hook Lock"))
(defvar *boot-hooks* '())

(defun add-boot-hook (fn)
  (with-mutex (*boot-hook-lock*)
    (push fn *boot-hooks*)))

(defun remove-boot-hook (fn)
  (with-mutex (*boot-hook-lock*)
    (setf *boot-hooks* (remove fn *boot-hooks*))))

(defun run-boot-hooks ()
  (dolist (hook *boot-hooks*)
    (handler-case (funcall hook)
      (error (c)
        (format t "~&Error ~A while running boot hook ~S.~%" c hook)))))

(defvar *boot-modules*)

(defun align-up (value power-of-two)
  "Align VALUE up to the nearest multiple of POWER-OF-TWO."
  (logand (+ value (1- power-of-two))
          (lognot (1- power-of-two))))

(defun initialize-boot-modules ()
  (do ((base (+ +physical-map-base+ (sys.int::memref-t (+ *boot-information-page* +boot-information-module-base+) 0)))
       (limit (sys.int::memref-t (+ *boot-information-page* +boot-information-module-limit+) 0))
       (offset 0)
       (new-modules '()))
      ((>= offset limit)
       (setf *boot-modules* (append *boot-modules*
                                    (reverse new-modules))))
    (let* ((module-base (+ +physical-map-base+ (sys.int::memref-t (+ base offset) 0)))
           (module-size (sys.int::memref-t (+ base offset) 1))
           (name-size (sys.int::memref-t (+ base offset) 2))
           (name-base (+ base offset 24))
           (module (make-array module-size :element-type '(unsigned-byte 8)))
           (name (make-array name-size :element-type 'character)))
      (incf offset (align-up (+ 24 name-size) 16))
      (dotimes (i module-size)
        (setf (aref module i) (sys.int::memref-unsigned-byte-8 module-base i)))
      (dotimes (i name-size)
        (setf (aref name i) (code-char (sys.int::memref-unsigned-byte-8 name-base i))))
      (push (cons name module) new-modules))))

(defun fetch-boot-modules ()
  (loop
     ;; Grab the modules and reset the symbol atomically.
     (let ((modules (sys.int::symbol-global-value '*boot-modules*)))
       (when (sys.int::%cas-symbol-global-value '*boot-modules* modules '())
         (return modules)))))

(defun sys.int::bootloader-entry-point (boot-information-page)
  (let ((first-run-p nil))
    (initialize-initial-thread)
    (setf *boot-information-page* boot-information-page
          *block-cache* nil
          *cold-unread-char* nil
          *snapshot-in-progress* nil
          mezzanine.runtime::*paranoid-allocation* nil
          *disks* '()
          *paging-disk* nil)
    (initialize-physical-allocator)
    (initialize-early-video)
    (initialize-boot-cpu)
    (when (not (boundp 'mezzanine.runtime::*tls-lock*))
      (setf first-run-p t)
      (mezzanine.runtime::first-run-initialize-allocator)
      ;; FIXME: Should be done by cold generator
      (setf mezzanine.runtime::*tls-lock* :unlocked
            mezzanine.runtime::*active-catch-handlers* 'nil
            *boot-modules* '())
      ;; Bootstrap the defstruct system.
      ;; 1) Initialize *structure-type-type* so make-struct-definition works.
      (setf sys.int::*structure-type-type* nil)
      ;; 2) Create the real definition, with broken type.
      (setf sys.int::*structure-type-type* (sys.int::make-struct-definition
                                            'sys.int::structure-definition
                                            ;; (name accessor initial-value type read-only atomic).
                                            '((sys.int::name sys.int::structure-name nil t t nil)
                                              (sys.int::slots sys.int::structure-slots nil t t nil)
                                              (sys.int::parent sys.int::structure-parent nil t t nil)
                                              (sys.int::area sys.int::structure-area nil t t nil)
                                              (sys.int::class sys.int::structure-class nil t nil nil))
                                            nil
                                            :wired))
      ;; 3) Patch up the broken structure type.
      (setf (sys.int::%struct-slot sys.int::*structure-type-type* 0) sys.int::*structure-type-type*))
    (initialize-interrupts)
    (initialize-i8259)
    (initialize-threads)
    (initialize-pager)
    (sys.int::%sti)
    (initialize-debug-serial #x3F8 4 38400)
    ;;(debug-set-output-pesudostream (lambda (op &optional arg) (declare (ignore op arg))))
    (debug-write-line "Hello, Debug World!")
    (initialize-ata)
    (when (not *paging-disk*)
      (debug-write-line "Could not find boot device. Sorry.")
      (loop))
    (initialize-ps/2)
    (initialize-video)
    (initialize-boot-modules)
    (cond (first-run-p
           (make-thread #'sys.int::initialize-lisp :name "Main thread"))
          (t (make-thread #'run-boot-hooks :name "Boot hook thread")))
    (finish-initial-thread)))
