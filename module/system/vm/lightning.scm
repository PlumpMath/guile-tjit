;;; -*- mode: scheme; coding: utf-8; -*-

;;;; Copyright (C) 2014, 2015 Free Software Foundation, Inc.
;;;;
;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;;
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;;
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;;;; 02110-1301 USA
;;;;

;;; Commentary:

;;; JIT compiler from bytecode to native code with lightning.

;;; Code:

(define-module (system vm lightning)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 format)
  #:use-module (language bytecode)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-9)
  #:use-module (system foreign)
  #:use-module (system vm debug)
  #:use-module (system vm lightning binding)
  #:use-module (system vm lightning debug)
  #:use-module (system vm lightning trace)
  #:use-module (system vm program)
  #:use-module (system vm vm)
  #:export (compile-lightning
            call-lightning c-call-lightning
            jit-code-guardian)
  #:re-export (lightning-verbosity))


;;;
;;; Auxiliary
;;;

;; Modified later by function defined in "vm-lightning.c". Defined with
;; dummy body to silent warning message.
(define thread-i-data *unspecified*)

(define *vm-instr* (make-hash-table))

;; State used during compilation.
(define-record-type <lightning>
  (%make-lightning trace nodes ip labels pc fp nargs args nretvals
                   cached modified indent)
  lightning?

  ;; State from bytecode trace.
  (trace lightning-trace set-lightning-trace!)

  ;; Hash table containing compiled nodes.
  (nodes lightning-nodes)

  ;; Current bytecode IP.
  (ip lightning-ip set-lightning-ip!)

  ;; Label objects used by lightning.
  (labels lightning-labels)

  ;; Address of byte-compiled program code.
  (pc lightning-pc)

  ;; Frame pointer
  (fp lightning-fp)

  ;; Arguments.
  (args lightning-args)

  ;; Number of arguments.
  (nargs lightning-nargs)

  ;; Number of return values.
  (nretvals lightning-nretvals set-lightning-nretvals!)

  ;; Registers for cache.
  (cached lightning-cached set-lightning-cached!)

  ;; Modified cached registers, to be saved before calling procedure.
  (modified lightning-modified set-lightning-modified!)

  ;; Indentation level for debug message.
  (indent lightning-indent))

(define* (make-lightning trace nodes fp nargs args pc
                         indent
                         #:optional
                         (nretvals 1)
                         (ip 0)
                         (labels (make-hash-table)))
  (for-each (lambda (labeled-ip)
              (hashq-set! labels labeled-ip (jit-forward)))
            (trace-labeled-ips trace))
  (%make-lightning trace nodes ip labels pc fp nargs args nretvals
                   #f #f indent))

(define jit-code-guardian (make-guardian))

(define program-nretvals (make-object-property))


;;;
;;; Constants
;;;

(define-syntax-rule (tc3-struct) 1)
(define-syntax-rule (tc7-variable) 7)
(define-syntax-rule (tc7-vector) 13)
(define-syntax-rule (tc7-program) 69)
(define-syntax-rule (tc16-real) 535)
(define-syntax scm-undefined (identifier-syntax (make-pointer #x904)))
(define-syntax-rule (program-is-jit-compiled) (imm #x4000))


;;;
;;; Registers
;;;

;; Number of arguments.
(define-syntax reg-nargs (identifier-syntax v0))

;; Return value.
(define-syntax reg-retval (identifier-syntax v1))

;; Current thread.
(define-syntax reg-thread (identifier-syntax v2))


;;;
;;; VM op syntaxes
;;;

(define-syntax define-vm-op
  (syntax-rules ()
    ((_ (op st . args) body ...)
     (hashq-set! *vm-instr* 'op (lambda (st . args)
                                  body ...)))))

(define-syntax-rule (resolve-dst st offset)
  "Resolve jump destination with <lightning> state ST and OFFSET given as
argument in VM operation."
  (hashq-ref (lightning-labels st) (+ (lightning-ip st) offset)))

(define-syntax-rule (dereference-scm pointer)
  (pointer->scm (dereference-pointer pointer)))

(define-syntax-rule (reg=? a b)
  "Compare pointer address of register A and B."
  (= (pointer-address a) (pointer-address b)))

(define-syntax-rule (stored-ref st n)
  "Memory address of ST's local N."
  (imm (- (lightning-fp st) (* (sizeof '*) n))))

(define-syntax-rule (scm-makinumi n)
  "Make scheme small fixnum from N."
  (imm (+ (ash n 2) 2)))

(define-syntax-rule (scm-makinumr dst src)
  "Make scheme small fixnum from SRC and store to DST."
  (begin
    (jit-lshi dst src (imm 2))
    (jit-addi dst dst (imm 2))))

;;; === With argument caching ===

;; ;; XXX: For x86-64.
;; (define *cache-registers*
;;   (vector v0 v1 v2 v3 f0 f1 f2 f3 f4))

;; ;; XXX: Analyze which registers to cache, take benchmarks.
;; (define (cache-locals st nlocals)
;;   "Load memory contents of current locals from ST.
;; Naively load from 0 to (min NLOCALS (number of available cache registers))."
;;   (let* ((num-regs (vector-length *cache-registers*))
;;          (regs (make-vector (min nlocals num-regs))))
;;     (let lp ((n 0))
;;       (when (and (< n nlocals) (< n num-regs))
;;         (let ((reg (vector-ref *cache-registers* n)))
;;           (jit-ldxi reg (jit-fp) (stored-ref st n))
;;           (vector-set! regs n reg))
;;         (lp (+ n 1))))
;;     (set-lightning-cached! st regs)
;;     (set-lightning-modified! st (make-vector nlocals #f))))

;; (define (save-locals st)
;;   "Store modified registers in cache to memory."
;;   (let* ((cache (lightning-cached st))
;;          (ncache (vector-length cache))
;;          (modified (lightning-modified st)))
;;     (let lp ((n 0))
;;       (when (< n ncache)
;;         (when (vector-ref modified n)
;;           (jit-stxi (stored-ref st n) (jit-fp) (vector-ref cache n)))
;;         (lp (+ n 1))))))

;; (define-syntax local-ref
;;   (syntax-rules ()
;;     ((local-ref st n)
;;      (local-ref st n r0))
;;     ((local-ref st n reg)
;;      (or (let ((cache (lightning-cached st)))
;;            (and (< n (vector-length cache))
;;                 (vector-ref cache n)))
;;          (begin
;;            (jit-ldxi reg (jit-fp) (stored-ref st n))
;;            reg)))))

;; (define (local-set! st dst reg)
;;   (or (and (< dst (vector-length (lightning-cached st)))
;;            (let ((regb (vector-ref (lightning-cached st) dst)))
;;              (or (reg=? regb reg)
;;                  (jit-movr regb reg))
;;              (vector-set! (lightning-modified st) dst #t)))
;;       (jit-stxi (stored-ref st dst) (jit-fp) reg)))

;; (define (local-set-immediate! st dst val)
;;   (or (and (< dst (vector-length (lightning-cached st)))
;;            (let ((regb (vector-ref (lightning-cached st) dst)))
;;              (jit-movi regb val)
;;              (vector-set! (lightning-modified st) dst #t)))
;;       (and (jit-movi r0 val)
;;            (jit-stxi (stored-ref st dst) (jit-fp) r0))))

;;; === Without argument caching ===

(define-syntax-rule (cache-locals st nlocals)
  *unspecified*)

(define-syntax-rule (save-locals st)
  *unspecified*)

(define-syntax local-ref
  (syntax-rules ()
    ((local-ref st n)
     (local-ref st n r0))
    ((local-ref st n reg)
     (begin
       (jit-ldxi reg (jit-fp) (stored-ref st n))
       reg))))

(define-syntax-rule (local-set! st dst reg)
  (jit-stxi (stored-ref st dst) (jit-fp) reg))

(define-syntax-rule (local-set-immediate! st dst val)
  (begin
    (jit-movi r0 val)
    (jit-stxi (stored-ref st dst) (jit-fp) r0)))

;;;

(define-syntax-rule (offset-addr st offset)
  (+ (lightning-pc st) (* 4 (+ (lightning-ip st) offset))))

(define-syntax-rule (c-pointer name)
  (dynamic-func name (dynamic-link)))

(define-syntax-rule (scm-thread-dynamic-state st)
  (jit-ldxi r0 reg-thread (imm #xd8)))

(define-syntax-rule (scm-thread-pending-asyncs st)
  (jit-ldxi r0 reg-thread (imm #x104)))

;;;

;; XXX: Add pre and post as in vm-engine.c?
(define-syntax-rule (vm-handle-interrupts st)
  (let ((l1 (jit-forward)))
    (scm-thread-pending-asyncs r0)
    (jit-patch-at (jit-bmci r0 (imm 1)) l1)
    (jit-prepare)
    (jit-calli (c-pointer "scm_async_tick"))
    (jit-link l1)))

(define-syntax return-jmp
  (syntax-rules ()
    ((_ st)
     (return-jmp st r0))
    ((_ st reg)
     (begin
       ;; Get return address to jump
       (jit-ldxi reg (jit-fp) (stored-ref st -1))
       ;; Restore previous dynamic link to current frame pointer
       (jit-ldxi (jit-fp) (jit-fp) (stored-ref st -2))
       ;; ... then jump to return address.
       (jit-jmpr reg)))))

(define-syntax-rule (call-primitive st proc nlocals primitive)
  (let* ((pargs (program-arguments-alist primitive))
         (required (cdr (assoc 'required pargs)))
         (optionals (cdr (assoc 'optional pargs)))
         (rest (cdr (assoc 'rest pargs)))
         (num-required (length required))
         (num-optionals (length optionals))
         (num-req+opts (+ num-required num-optionals)))

    ;; If the primitive contained `rest' argument, build a list for rest
    ;; argument first, by calling `scm_list_n' or moving empty list to
    ;; register.
    (when rest
      (if (< (- nlocals 1) num-req+opts)
          (jit-movi r1 (scm->pointer '()))
          (begin
            (jit-prepare)
            (for-each (lambda (i)
                        (jit-pushargr
                         (local-ref st (+ proc i 1 num-req+opts))))
                      (iota (- nlocals num-req+opts 1)))
            ;; Additional `undefined', to end the arguments.
            (jit-pushargi scm-undefined)
            (jit-calli (c-pointer "scm_list_n"))
            (jit-retval r1))))

    ;; Pushing argument for primitive procedure.
    (jit-prepare)
    (for-each (lambda (i)
                (jit-pushargr (local-ref st (+ proc 1 i))))
              (iota (min (- nlocals 1) num-req+opts)))

    ;; Filling in unspecified optionals, if any.
    (when (not (null? optionals))
      (for-each (lambda (i)
                  (jit-pushargi scm-undefined))
                (iota (- num-req+opts (- nlocals 1)))))
    (when rest
      (jit-pushargr r1))
    (jit-calli (program-free-variable-ref primitive 0))
    (jit-retval reg-retval)))

(define-syntax-rule (call-scm st proc-or-addr)
  (let* ((addr (ensure-program-addr proc-or-addr))
         (callee (hashq-ref (lightning-nodes st) addr)))
    (jit-patch-at (jit-jmpi) callee)))

(define-syntax-rule (current-callee st)
  (hashq-ref (trace-callers (lightning-trace st)) (lightning-ip st)))

(define-syntax-rule (current-callee-args st)
  (hashq-ref (trace-callee-args (lightning-trace st)) (lightning-ip st)))

(define-syntax with-frame
  ;; Stack poionter stored in (jit-fp), decreasing for `proc * word' size to
  ;; shift the locals.  Then patching the address after the jmp, so that
  ;; called procedure can jump back. Two locals below proc get overwritten by
  ;; callee.
  (syntax-rules ()
    ((_ st proc body)
     (with-frame st r0 proc body))
    ((_ st reg proc body)
     (let ((ra (jit-movi reg (imm 0))))
       ;; Store return address.
       (jit-stxi (stored-ref st (- proc 1)) (jit-fp) reg)
       ;; Store dynamic link.
       (jit-stxi (stored-ref st (- proc 2)) (jit-fp) (jit-fp))
       ;; Shift the frame pointer register.
       (jit-subi (jit-fp) (jit-fp) (imm (* (sizeof '*) proc)))
       body
       (jit-patch ra)))))

(define-syntax-rule (call-apply st proc nlocals)
  (let ((nargs nlocals))

    ;; Last local, a list containing rest of arguments.
    (local-ref st (- (+ proc nargs) 1) r0)

    ;; Cons all the other arguments to rest, if any.
    (when (< 3 nargs)
      (for-each (lambda (n)
                  (jit-prepare)
                  (local-ref st (+ proc (- nargs 2 n)) r1)
                  (jit-pushargr reg-thread)
                  (jit-pushargr r1)
                  (jit-pushargr r0)
                  (jit-calli (c-pointer "scm_do_inline_cons"))
                  (jit-retval r0))
                (iota (- nargs 3))))

    ;; Call `%call-lightning' with thread, proc, and argument list.
    (jit-prepare)
    (jit-pushargr reg-thread)
    (jit-pushargr (local-ref st (+ proc 1) r1))
    (jit-pushargr r0)
    (jit-calli %call-lightning)
    (jit-retval reg-retval)))

(define-syntax call-local
  (syntax-rules ()
    ((_ st proc nlocals #f)
     (call-local st proc nlocals (with-frame st proc (jit-jmpr r1))))
    ((_ st proc nlocals #t)
     (call-local st proc nlocals (jit-jmpr r1)))
    ((_ st proc nlocals expr)
     (let ((l1 (jit-forward))
           (l2 (jit-forward)))

       (jit-ldr r0 (local-ref st proc))
       (jit-patch-at (jit-bmci r0 (program-is-jit-compiled)) l1)

       ;; Has compiled code.
       (jit-ldxi r1 (local-ref st proc) (imm (* (sizeof '*) 2)))
       expr
       (jit-patch-at (jit-jmpi) l2)

       ;; Does not have compiled code.
       ;;
       ;; XXX: Add test for primitive procedures, delegate the call to
       ;; vm-regular.
       (jit-link l1)
       (call-runtime st proc nlocals)
       (local-set! st (+ proc 1) r0)

       (jit-link l2)))))

(define-syntax-rule (call-runtime st proc nlocals)
  (begin
    (jit-prepare)
    (for-each (lambda (n)
                (jit-pushargr (local-ref st (+ proc n 1))))
              (iota (- nlocals 1)))
    (jit-pushargi scm-undefined)
    (jit-calli (c-pointer "scm_list_n"))
    (jit-retval r1)
    (jit-prepare)
    (jit-pushargr reg-thread)
    (jit-pushargr (local-ref st proc))
    (jit-pushargr r1)
    (jit-calli %call-lightning)
    (jit-retval reg-retval)))

(define-syntax compile-callee
  (syntax-rules (compile-lightning* with-frame)

    ;; Non tail call
    ((_ st1 proc nlocals callee-addr #f)
     (compile-callee st1 st2 proc nlocals callee-addr
                     (with-frame st2 proc
                                 (compile-lightning* st2 (jit-forward) #f))))

    ;; Tail call
    ((_ st1 proc nlocals callee-addr #t)
     (compile-callee st1 st2 proc nlocals callee-addr
                     (compile-lightning* st2 (jit-forward) #f)))

    ((_ st1 st2 proc nlocals callee-addr body)
     (let ((args (current-callee-args st1)))
       (cond
        ((program->trace callee-addr nlocals args)
         =>
         (lambda (trace)
           (let ((st2 (make-lightning trace
                                      (lightning-nodes st1)
                                      (lightning-fp st1)
                                      nlocals
                                      args
                                      callee-addr
                                      (+ 2 (lightning-indent st1)))))
             body)))
        (else
         (debug 1 ";;; Trace failed, calling 0x~x at runtime.~%" callee-addr)
         (call-runtime st1 proc nlocals)))))))

(define-syntax-rule (in-same-procedure? st label)
  ;; XXX: Could look the last IP of current procedure.  Instead, looking
  ;; for backward jump at the moment.
  (and (<= 0 (+ (lightning-ip st) label))
       (< label 0)))

(define-syntax-rule (recursion? st proc)
  (and (procedure? proc)
       (= (lightning-pc st) (ensure-program-addr proc))))

;; Currently, higher order procedures are recompiled every time.
(define-syntax-rule (reusable? v)
  (let lp ((n (- (vector-length v) 1)))
    (cond ((< n 1) #t)
          ((procedure? (vector-ref v n)) #f)
          ;; ((unknown? (vector-ref v n)) #f)
          (else (lp (- n 1))))))

(define-syntax-rule (compiled-node st addr)
  (hashq-ref (lightning-nodes st) addr))

(define-syntax-rule (define-label l body ...)
  (begin (jit-link l) body ...))

(define-syntax assert-wrong-num-args
  (syntax-rules ()
    ((_ st jit-op expected local)
     (let ((l1 (jit-forward)))
       (jit-patch-at (jit-op reg-nargs (imm expected)) l1)
       (jit-prepare)
       (jit-pushargr (local-ref st 0))
       (jit-calli (c-pointer "scm_wrong_num_args"))
       (jit-reti (scm->pointer *unspecified*))
       (jit-link l1)))))

(define-syntax define-br-nargs-op
  (syntax-rules ()
    ((_ (name st expected offset) jit-op)
     (define-vm-op (name st expected offset)
       (jit-patch-at
        (jit-op reg-nargs (imm expected))
        (resolve-dst st offset))))))

(define-syntax define-vm-br-unary-immediate-op
  (syntax-rules ()
    ((_ (name st a invert offset) expr)
     (define-vm-op (name st a invert offset)
       (when (< offset 0)
         (vm-handle-interrupts st))
       (jit-patch-at expr (resolve-dst st offset))))))

(define-syntax define-vm-br-unary-heap-object-op
  (syntax-rules ()
    ((_ (name st a invert offset) reg expr)
     (define-vm-op (name st a invert offset)
       (when (< offset 0)
         (vm-handle-interrupts st))
       (let ((l1 (jit-forward)))
         (local-ref st a reg)
         (jit-patch-at (jit-bmsi reg (imm 6))
                       (if invert (resolve-dst st offset) l1))
         (jit-ldr reg reg)
         (jit-patch-at expr
                       (if invert (resolve-dst st offset) l1))
         ;; XXX: Any other way?
         (when (not invert)
           (jit-patch-at (jit-jmpi) (resolve-dst st offset)))
         (jit-link l1))))))

(define-syntax define-vm-br-binary-op
  (syntax-rules ()
    ((_ (name st a b invert offset) cname)
     (define-vm-op (name st a b invert offset)
       (when (< offset 0)
         (vm-handle-interrupts st))
       (let ((l1 (jit-forward)))
         (local-ref st a r0)
         (local-ref st b r1)
         (jit-patch-at
          (jit-beqr r0 r1)
          (if invert l1 (resolve-dst st offset)))

         (jit-prepare)
         (jit-pushargr r0)
         (jit-pushargr r1)
         (jit-calli (c-pointer cname))
         (jit-retval r0)

         (jit-patch-at
          (jit-beqi r0 (scm->pointer #f))
          (if invert (resolve-dst st offset) l1))
         (when (not invert)
           (jit-patch-at (jit-jmpi) (resolve-dst st offset)))

         (jit-link l1))))))

(define-syntax define-vm-br-arithmetic-op
  (syntax-rules ()
    ((_ (name st a b invert offset)
        fx-op fx-invert-op fl-op fl-invert-op cname)
     (define-vm-op (name st a b invert offset)
       (when (< offset 0)
         (vm-handle-interrupts st))
       (let ((l1 (jit-forward))
             (l2 (jit-forward))
             (l3 (jit-forward))
             (l4 (jit-forward))
             (rega (local-ref st a r1))
             (regb (local-ref st b r2)))

         ;; fixnum x fixnum
         (jit-patch-at (jit-bmci rega (imm 2)) l2)
         (jit-patch-at (jit-bmci regb (imm 2)) l1)
         (jit-patch-at
          ((if invert fx-invert-op fx-op) rega regb)
          (resolve-dst st offset))
         (jit-patch-at (jit-jmpi) l4)

         ;; XXX: Convert fixnum to flonum when one of the argument is fixnum,
         ;; and the other flonum.
         (jit-link l1)
         (jit-patch-at (jit-bmsi rega (imm 2)) l3)

         ;; flonum x flonum
         (jit-link l2)
         (jit-patch-at (jit-bmsi rega (imm 6)) l3)
         (jit-ldr r0 rega)
         (jit-patch-at (jit-bnei r0 (imm (tc16-real))) l3)
         (jit-patch-at (jit-bmsi regb (imm 6)) l3)
         (jit-ldr r0 regb)
         (jit-patch-at (jit-bnei r0 (imm (tc16-real))) l3)
         (jit-ldxi-d f5 rega (imm (* 2 (sizeof '*))))
         (jit-ldxi-d f6 regb (imm (* 2 (sizeof '*))))
         (jit-patch-at
          ((if invert fl-invert-op fl-op) f5 f6)
          (resolve-dst st offset))
         (jit-patch-at (jit-jmpi) l4)

         ;; else
         (jit-link l3)
         (jit-prepare)
         (jit-pushargr rega)
         (jit-pushargr regb)
         (jit-calli (c-pointer cname))
         (jit-retval r0)
         (jit-patch-at
          ((if invert jit-beqi jit-bnei) r0 (scm->pointer #f))
          (resolve-dst st offset))

         (jit-link l4))))))

;; If var is not variable, resolve with `resolver' and move the resolved value
;; to var's address. Otherwise, var is `variable', move it to dst.
;;
;; At the moment, the variable is resolved at compilation time. May better to do
;; this variable resolution at run time when lightning code get preserved per
;; scheme procedure. Otherwise there is no way to update the procedure once it's
;; started.
(define-syntax define-vm-box-op
  (syntax-rules ()
    ((_ (name st mod-offset sym-offset) resolver ...)
     (define-vm-op (name st dst var-offset mod-offset sym-offset bound?)
       (let* ((current (lightning-ip st))
              (base (lightning-pc st))
              (offset->pointer
               (lambda (offset)
                 (make-pointer (+ base (* 4 (+ current offset))))))
              (var (dereference-scm (offset->pointer var-offset))))
         (if (variable? var)
             (local-set-immediate! st dst (scm->pointer var))
             (let ((resolved resolver ...))

               ;; XXX: In past, vm-regular was updating the offset
               ;; pointer of var. Though may better to do this in
               ;; lightning when updating procedure definition already
               ;; running in another thread.
               ;;
               ;; (local-set-immediate! st dst (scm->pointer resolved))
               ;;
               ;; Currently JIT code updates the contents of variable
               ;; offset.

               (jit-movi r0 (scm->pointer resolved))
               (jit-movi r1 (offset->pointer var-offset))
               (jit-str r1 r0)
               (local-set! st dst r0))))))))

(define-syntax define-vm-add-sub-op
  (syntax-rules ()
    ((_ (name st dst a b) fx-op-1 fx-op-2 fl-op c-name)
     (define-vm-op (name st dst a b)
       (let ((l1 (jit-forward))
             (l2 (jit-forward))
             (l3 (jit-forward))
             (l4 (jit-forward))
             (rega (local-ref st a r1))
             (regb (local-ref st b r2)))

         ;; Entry: a == small fixnum && b == small fixnum
         (jit-patch-at (jit-bmci rega (imm 2)) l2)
         (jit-patch-at (jit-bmci regb (imm 2)) l1)
         (jit-movr r0 rega)
         (jit-patch-at (fx-op-1 r0 regb) l3)
         (fx-op-2 r0 r0 (imm 2))
         (jit-patch-at (jit-jmpi) l4)

         ;; L1: Check for (a == small fixnum && b == flonm)
         (jit-link l1)
         (jit-patch-at (jit-bmsi rega (imm 2)) l3)

         ;; L2: flonum + flonum
         (jit-link l2)
         (jit-patch-at (jit-bmsi rega (imm 6)) l3)
         (jit-ldr r0 rega)
         (jit-patch-at (jit-bnei r0 (imm (tc16-real))) l3)
         (jit-patch-at (jit-bmsi regb (imm 6)) l3)
         (jit-ldr r0 regb)
         (jit-patch-at (jit-bnei r0 (imm (tc16-real))) l3)
         (jit-ldxi-d f5 rega (imm (* 2 (sizeof '*))))
         (jit-ldxi-d f6 regb (imm (* 2 (sizeof '*))))
         (fl-op f5 f5 f6)
         (jit-prepare)
         (jit-pushargr reg-thread)
         (jit-pushargr-d f5)
         (jit-calli (c-pointer "scm_do_inline_from_double"))
         (jit-retval r0)
         (jit-patch-at (jit-jmpi) l4)

         ;; L3: Call C function
         (jit-link l3)
         (jit-prepare)
         (jit-pushargr rega)
         (jit-pushargr regb)
         (jit-calli (c-pointer c-name))
         (jit-retval r0)

         (jit-link l4)
         (local-set! st dst r0))))))

(define-syntax define-vm-mul-div-op
  (syntax-rules ()
    ((_  (name st dst a b) fl-op cname)
     (define-vm-op (name st dst a b)
       (let ((l1 (jit-forward))
             (l2 (jit-forward))
             (l3 (jit-forward))
             (rega (local-ref st a r1))
             (regb (local-ref st b r2)))

         (jit-patch-at (jit-bmsi rega (imm 2)) l2)
         (jit-patch-at (jit-bmsi regb (imm 2)) l2)

         (jit-link l1)
         (jit-ldr r0 rega)
         (jit-patch-at (jit-bnei r0 (imm (tc16-real))) l2)
         (jit-ldr r0 regb)
         (jit-patch-at (jit-bnei r0 (imm (tc16-real))) l2)
         (jit-ldxi-d f5 rega (imm 16))
         (jit-ldxi-d f6 regb (imm 16))
         (fl-op f5 f5 f6)
         (jit-prepare)
         (jit-pushargr reg-thread)
         (jit-pushargr-d f5)
         (jit-calli (c-pointer "scm_do_inline_from_double"))
         (jit-retval r0)
         (jit-patch-at (jit-jmpi) l3)

         (jit-link l2)
         (jit-prepare)
         (jit-pushargr rega)
         (jit-pushargr regb)
         (jit-calli (c-pointer cname))
         (jit-retval r0)

         (jit-link l3)
         (local-set! st dst r0))))))

(define-syntax define-vm-unary-step-op
  (syntax-rules ()
    ((_ (name st dst src) fx-op fl-op cname)
     (define-vm-op (name st dst src)
       (let ((l1 (jit-forward))
             (l2 (jit-forward))
             (l3 (jit-forward))
             (reg (local-ref st src r1)))

         (jit-patch-at (jit-bmci reg (imm 2)) l1)
         (jit-movr r0 reg)
         (jit-patch-at (fx-op r0 (imm 4)) l1)
         (jit-patch-at (jit-jmpi) l3)

         (jit-link l1)
         (jit-ldr r0 reg)
         (jit-patch-at (jit-bnei r0 (imm (tc16-real))) l2)
         (jit-ldxi-d f5 reg (imm 16))
         (jit-movi r0 (imm 1))
         (jit-extr-d f6 r0)
         (fl-op f5 f5 f6)
         (jit-prepare)
         (jit-pushargr reg-thread)
         (jit-pushargr-d f5)
         (jit-calli (c-pointer "scm_do_inline_from_double"))
         (jit-retval r0)
         (jit-patch-at (jit-jmpi) l3)

         (jit-link l2)
         (jit-prepare)
         (jit-pushargr reg)
         (jit-pushargi (imm 6))
         (jit-calli (c-pointer cname))
         (jit-retval r0)

         (jit-link l3)
         (local-set! st dst r0))))))


;;;
;;; VM operations
;;;

;; Groupings are taken from "guile/libguile/vm-engine.c".


;;; Call and return
;;; ---------------

;;; XXX: Ensure enough space allocated for nlocals? How?

(define-vm-op (call st proc nlocals)
  (save-locals st)
  (vm-handle-interrupts st)
  (jit-movi reg-nargs (imm nlocals))
  (let ((callee (current-callee st)))
    (debug 1 ";;; call: callee=~a (~x)~%"
           callee (or (and (program? callee) (program-code callee)) 0))
    (cond
     ((builtin? callee)
      (case (builtin-name callee)
        ((apply) (call-apply st proc nlocals))))
     ((primitive? callee)
      (call-primitive st proc nlocals callee))
     ((closure? callee)
      ;; (cond
      ;;  ((and (reusable? (current-callee-args st))
      ;;        (compiled-node st (closure-addr callee)))
      ;;   =>
      ;;   (with-frame st proc (call-scm st (closure-addr callee))))
      ;;  (else
      ;;   (compile-callee st proc nlocals (closure-addr callee) #f)))
      (call-local st proc nlocals #f))
     ((recursion? st callee)
      (with-frame st proc (call-scm st callee)))
     ((jit-compiled-code callee)
      =>
      (lambda (code)
        (debug 1 ";;; call: found jit compiled-code at 0x~x~%" code)
        (with-frame st proc (begin (jit-movi r1 (imm code))
                                   (jit-jmpr r1)))))
     ((and (reusable? (current-callee-args st))
           (compiled-node st (ensure-program-addr callee)))
      =>
      (lambda (node)
        (with-frame st proc (jit-patch-at (jit-jmpi) node))))

     ;; XXX: Will inlined procedure work when the procedure redefined?
     ((procedure? callee)
      (compile-callee st proc nlocals (ensure-program-addr callee) #f))

     (else
      (call-local st proc nlocals #f)))))

(define-vm-op (call-label st proc nlocals label)
  (save-locals st)
  (vm-handle-interrupts st)
  (jit-movi reg-nargs (imm nlocals))
  (let ((addr (offset-addr st label)))
    (cond
     ((in-same-procedure? st label)
      (with-frame st proc (jit-patch-at (jit-jmpi) (resolve-dst st label))))
     ((compiled-node st addr)
      =>
      (lambda (node)
        (with-frame st proc (jit-patch-at (jit-jmpi) node))))
     (else
      (compile-callee st proc nlocals addr #f)))))

(define-vm-op (tail-call st nlocals)
  (save-locals st)
  (vm-handle-interrupts st)
  (jit-movi reg-nargs (imm nlocals))
  (let ((callee (current-callee st)))
    (debug 1  ";;; tail-call: callee=~a (~x)~%"
           callee (or (and (program? callee) (program-code callee)) 0))
    (cond
     ((builtin? callee)
      (case (builtin-name callee)
        ((apply) (call-apply st 0 nlocals))))
     ((primitive? callee)
      (call-primitive st 0 nlocals callee)
      (return-jmp st))
     ((closure? callee)
      ;; (cond
      ;;  ((and (reusable? (current-callee-args st))
      ;;        (compiled-node st (closure-addr callee)))
      ;;   =>
      ;;   (call-scm st (closure-addr callee)))
      ;;  ((closure-addr callee)
      ;;   =>
      ;;   (lambda (addr)
      ;;     (compile-callee st 0 nlocals addr #t)))
      ;;  (else
      ;;   (call-local st 0 nlocals #f)
      ;;   (return-jmp st)))
      (call-local st 0 nlocals #t))
     ((recursion? st callee)
      (call-scm st callee))
     ((jit-compiled-code callee)
      =>
      (lambda (code)
        (debug 1 ";;; tail-call: found jit compiled-code at ~x~%" code)
        (jit-movi r0 (imm code))
        (jit-jmpr r0)))
     ((and (reusable? (current-callee-args st))
           (compiled-node st (ensure-program-addr callee)))
      =>
      (lambda (node)
        (jit-patch-at (jit-jmpi) node)))
     ((procedure? callee)
      (compile-callee st 0 nlocals (ensure-program-addr callee) #t))
     (else
      (call-local st 0 nlocals #t)
      (return-jmp st)))))

(define-vm-op (tail-call-label st nlocals label)
  (save-locals st)
  (vm-handle-interrupts st)
  (jit-movi reg-nargs (imm nlocals))
  (cond
   ((in-same-procedure? st label)
    (jit-patch-at (jit-jmpi) (resolve-dst st label)))
   ((compiled-node st (offset-addr st label))
    =>
    (lambda (node)
      (jit-patch-at (jit-jmpi) node)))
   (else
    (compile-callee st 0 nlocals (offset-addr st label) #t))))

;; Return value stored in reg-retval by callee.
(define-vm-op (receive st dst proc nlocals)
  ;; (cache-locals st (lightning-nargs st))
  ;; (cache-locals st nlocals)
  (local-set! st dst reg-retval))

(define-vm-op (receive-values st proc allow-extra? nvalues)
  (save-locals st))

(define-vm-op (return st dst)
  (local-ref st dst reg-retval)
  (return-jmp st))

(define-vm-op (return-values st)
  (save-locals st)
  (return-jmp st))


;;; Specialized call stubs
;;; ----------------------

(define-vm-op (builtin-ref st dst src)
  (jit-prepare)
  (jit-pushargi (imm src))
  (jit-calli (c-pointer "scm_do_vm_builtin_ref"))
  (jit-retval r0)
  (local-set! st dst r0))


;;; Function prologues
;;; ------------------

(define-br-nargs-op (br-if-nargs-ne st expected offset)
  jit-bnei)

(define-br-nargs-op (br-if-nargs-lt st expected offset)
  jit-blti)

(define-br-nargs-op (br-if-nargs-gt st expected offset)
  jit-bgti)

(define-vm-op (assert-nargs-ee/locals st expected locals)
  (assert-wrong-num-args st jit-beqi expected 0))

(define-vm-op (bind-kwargs st nreq flags nreq-and-opt ntotal kw-offset)
  (jit-prepare)
  (jit-pushargr (jit-fp))
  (jit-pushargi (imm (lightning-fp st)))
  (jit-pushargr reg-nargs)
  (jit-pushargi (imm (+ (* 4 (lightning-ip st)) (lightning-pc st))))
  (jit-pushargi (imm nreq))
  (jit-pushargi (imm flags))
  (jit-pushargi (imm nreq-and-opt))
  (jit-pushargi (imm ntotal))
  (jit-pushargi (imm kw-offset))
  (jit-calli (c-pointer "scm_do_bind_kwargs")))

(define-vm-op (bind-rest st dst)
  (let ((l1 (jit-forward))
        (l2 (jit-forward)))

    (jit-movi r1 (imm (lightning-fp st)))
    (jit-movr r0 reg-nargs)
    (jit-subi r0 r0 (imm 1))
    (jit-muli r0 r0 (imm (sizeof '*)))
    (jit-subr r1 r1 r0)                 ; r1 = initial arg index.

    (jit-movi r0 (scm->pointer '()))    ; r0 = initial list.

    (jit-link l1)
    (jit-patch-at
     (jit-bgti r1 (imm (- (lightning-fp st) (* dst (sizeof '*)))))
     l2)
    (jit-prepare)
    (jit-pushargr reg-thread)
    (jit-ldxr r2 (jit-fp) r1)
    (jit-pushargr r2)
    (jit-pushargr r0)
    (jit-calli (c-pointer "scm_do_inline_cons"))
    (jit-retval r0)
    (jit-addi r1 r1 (imm (sizeof '*)))
    (jit-patch-at (jit-jmpi) l1)

    (jit-link l2)

    ;; Updating nargs to prevent following `alloc-frame' to override
    ;; the rest list with #<unspecified>.
    (jit-movi reg-nargs (imm (+ dst 1)))

    (local-set! st dst r0)))

(define-vm-op (assert-nargs-ee st expected)
  (assert-wrong-num-args st jit-beqi expected 0))

(define-vm-op (assert-nargs-ge st expected)
  (assert-wrong-num-args st jit-bgei expected 0))

(define-vm-op (assert-nargs-le st expected)
  (assert-wrong-num-args st jit-blei expected 0))

(define-vm-op (alloc-frame st nlocals)
  ;; (cache-locals st (lightning-nargs st))
  (let ((l1 (jit-forward))
        (l2 (jit-forward)))

    (jit-movr r1 reg-nargs)

    (jit-link l1)
    (jit-patch-at (jit-bgei r1 (imm nlocals)) l2)

    ;; Doing similar things to `stored-ref' in generated code. Using r2
    ;; as offset of location to store.
    (jit-movi r2 (imm (lightning-fp st)))
    (jit-movr r0 r1)
    (jit-muli r0 r0 (* (imm (sizeof '*))))
    (jit-subr r2 r2 r0)
    (jit-movi r0 scm-undefined)
    (jit-stxr r2 (jit-fp) r0)
    (jit-addi r1 r1 (imm 1))
    (jit-patch-at (jit-jmpi) l1)

    (jit-link l2)))

;; XXX: Modify to manage (jit-fp) with absolute value of nlocal?
;;
;; Caching was once causing infinite loops and disabled. Brought back
;; after running `run-nfa' procedure, locals were mixed up from callee.
(define-vm-op (reset-frame st nlocals)
  ;; (save-locals st)
  ;; (cache-locals st (lightning-nargs st))
  ;; (cache-locals st nlocals)
  *unspecified*)


;;; Branching instructions
;;; ----------------------

(define-vm-op (br st dst)
  (when (< dst 0)
    (vm-handle-interrupts st))
  (jit-patch-at (jit-jmpi) (resolve-dst st dst)))

(define-vm-br-unary-immediate-op (br-if-true st a invert offset)
  ((if invert jit-beqi jit-bnei) (local-ref st a) (scm->pointer #f)))

(define-vm-br-unary-immediate-op (br-if-null st a invert offset)
  ((if invert jit-bnei jit-beqi) (local-ref st a) (scm->pointer '())))

;; XXX: br-if-nil

(define-vm-br-unary-heap-object-op (br-if-pair st a invert offset)
  r0 (jit-bmsi r0 (imm 1)))

(define-vm-br-unary-heap-object-op (br-if-struct st a invert offset)
  r0 (begin (jit-andi r0 r0 (imm 7))
            (jit-bnei r0 (imm 1))))

(define-vm-br-unary-immediate-op (br-if-char st a invert offset)
  ((if invert jit-bnei jit-beqi)
   (begin (local-ref st a r0)
          (jit-andi r0 r0 (imm #xff))
          r0)
   (imm 12)))

(define-vm-op (br-if-tc7 st a invert tc7 offset)
  (when (< offset 0)
    (vm-handle-interrupts st))
  (let ((l1 (jit-forward)))
    (local-ref st a r0)
    (jit-patch-at (jit-bmsi r0 (imm 6))
                  (if invert (resolve-dst st offset) l1))
    (jit-ldr r0 r0)
    (jit-patch-at (begin (jit-andi r0 r0 (imm #x7f))
                         (jit-bnei r0 (imm tc7)))
                  (if invert (resolve-dst st offset) l1))
    (when (not invert)
      (jit-patch-at (jit-jmpi) (resolve-dst st offset)))
    (jit-link l1)))

(define-vm-op (br-if-eq st a b invert offset)
  (when (< offset 0)
    (vm-handle-interrupts st))
  (jit-patch-at
   ((if invert jit-bner jit-beqr)
    (local-ref st a r0)
    (local-ref st b r1))
   (resolve-dst st offset)))

(define-vm-br-binary-op (br-if-eqv st a b invert offset)
  "scm_eqv_p")

(define-vm-br-binary-op (br-if-equal st a b invert offset)
  "scm_equal_p")

(define-vm-br-arithmetic-op (br-if-< st a b invert offset)
  jit-bltr jit-bger jit-bltr-d jit-bunltr-d "scm_less_p")

(define-vm-br-arithmetic-op (br-if-<= st a b invert offset)
  jit-bler jit-bgtr jit-bler-d jit-bunler-d "scm_leq_p")

(define-vm-br-arithmetic-op (br-if-= st a b invert offset)
  jit-beqr jit-bner jit-beqr-d jit-bner-d "scm_num_eq_p")


;;; Lexical binding instructions
;;; ----------------------------

(define-vm-op (mov st dst src)
  (local-set! st dst (local-ref st src)))

(define-vm-op (box st dst src)
  (jit-prepare)
  (jit-pushargr reg-thread)
  (jit-pushargi (imm (tc7-variable)))
  (jit-pushargr (local-ref st src))
  (jit-calli (c-pointer "scm_do_inline_cell"))
  (jit-retval r0)
  (local-set! st dst r0))

(define-vm-op (box-ref st dst src)
  (jit-ldxi r0 (local-ref st src) (imm (sizeof '*)))
  (local-set! st dst r0))

(define-vm-op (box-set! st dst src)
  (jit-stxi (imm (sizeof '*)) (local-ref st dst r0) (local-ref st src r1)))

(define-vm-op (make-closure st dst offset nfree)
  (jit-prepare)
  (jit-pushargr reg-thread)
  (jit-pushargi (imm (logior (tc7-program) (ash nfree 16))))
  (jit-pushargi (imm (+ nfree 3)))
  (jit-calli (c-pointer "scm_do_inline_words"))
  (jit-retval r0)

  ;; Storing address of byte-compiled program code.
  (jit-movi r1 (imm (offset-addr st offset)))
  (jit-stxi (imm (sizeof '*)) r0 r1)

  ;; XXX: Storing JIT compiled code. Could fill in the address if
  ;; already compiled, but not done yet.
  (jit-movi r1 scm-undefined)
  (jit-stxi (imm (* 2 (sizeof '*))) r0 r1)

  (jit-movi r1 (scm->pointer #f))
  (for-each (lambda (n)
              (jit-stxi (imm (* (sizeof '*) (+ n 2))) r0 r1))
            (iota nfree))
  (local-set! st dst r0))

(define-vm-op (free-ref st dst src idx)
  (jit-ldxi r0 (local-ref st src) (imm (* (sizeof '*) (+ idx 3))))
  (local-set! st dst r0))

(define-vm-op (free-set! st dst src idx)
  (jit-stxi (imm (* (sizeof '*) (+ idx 3)))
            (local-ref st dst r1)
            (local-ref st src r0)))


;;; Immediates and statically allocated non-immediates
;;; --------------------------------------------------

(define-vm-op (make-short-immediate st dst a)
  (local-set-immediate! st dst (imm a)))

(define-vm-op (make-long-immediate st dst a)
  (local-set-immediate! st dst (imm a)))

(define-vm-op (make-long-long-immediate st dst hi lo)
  (jit-movi r0 (imm hi))
  (jit-movi r1 (imm lo))
  (jit-lshi r0 r0 (imm 32))
  (jit-orr r0 r0 r1)
  (local-set! st dst r0))

(define-vm-op (make-non-immediate st dst offset)
  (jit-movi r0 (imm (offset-addr st offset)))
  (local-set! st dst r0))

(define-vm-op (static-ref st dst offset)
  (jit-ldi r0 (imm (offset-addr st offset)))
  (local-set! st dst r0))


;;; Mutable top-level bindings
;;; --------------------------

(define-vm-op (current-module st dst)
  (jit-prepare)
  (jit-calli (c-pointer "scm_current_module"))
  (jit-retval r0)
  (local-set! st dst r0))

(define-vm-box-op (toplevel-box st mod-offset sym-offset)
  (module-variable
   (or (dereference-scm (make-pointer (offset-addr st mod-offset)))
       the-root-module)
   (dereference-scm (make-pointer (offset-addr st sym-offset)))))

(define-vm-box-op (module-box st mod-offset sym-offset)
  (module-variable
   (resolve-module
    (cdr (pointer->scm (make-pointer (offset-addr st mod-offset)))))
   (dereference-scm (make-pointer (offset-addr st sym-offset)))))


;;; The dynamic environment
;;; -----------------------

;;; XXX: prompt

;;; XXX: Not tested yet.
(define-vm-op (wind st winder unwinder)
  (jit-prepare)
  (jit-pushargr reg-thread)
  (local-ref st winder r0)
  (jit-pushargr r0)
  (local-ref st unwinder r0)
  (jit-pushargr r0)
  (jit-calli (c-pointer "scm_do_dynstack_push_dynwind")))

;;; XXX: Not tested yet.
(define-vm-op (unwind st)
  (jit-prepare)
  (jit-pushargr reg-thread)
  (jit-calli (c-pointer "scm_do_dynstack_pop")))

(define-vm-op (push-fluid st fluid value)
  (jit-prepare)
  (jit-pushargr reg-thread)
  (local-ref st fluid r0)
  (jit-pushargr r0)
  (local-ref st value r0)
  (jit-pushargr r0)
  (jit-calli (c-pointer "scm_do_dynstack_push_fluid")))

(define-vm-op (pop-fluid st)
  (jit-prepare)
  (jit-pushargr reg-thread)
  (jit-calli (c-pointer "scm_do_unwind_fluid")))

(define-vm-op (fluid-ref st dst src)
  (let ((l1 (jit-forward)))
    (local-ref st src r0)

    ;; r0 = fluids, in thread:
    ;;   thread->dynamic_state
    (scm-thread-dynamic-state r0)
    ;;   SCM_I_DYNAMIC_STATE_FLUIDS (dynstack)
    ;;   (i.e. SCM_CELL_WORD_1 (dynstack))
    (jit-ldxi r0 r0 (imm 8))

    ;; r1 = fluid, from local:
    (local-ref st src r1)

    ;; r2 = num, vector index.
    (jit-ldr r2 r1)
    (jit-rshi r2 r2 (imm 8))
    (jit-addi r2 r2 (imm 1))
    (jit-muli r2 r2 (imm 8))

    ;; r0 = fluid value
    (jit-ldxr r0 r0 r2)

    ;; Load default value from local fluid if not set.
    (jit-patch-at (jit-bnei r0 scm-undefined) l1)
    (jit-ldxi r0 r1 (imm 8))
    (jit-link l1)
    (local-set! st dst r0)))

;;; XXX: fluid-set

;;; String, symbols, and keywords
;;; -----------------------------

(define-vm-op (string-length st dst src)
  (jit-ldxi r0 (local-ref st src) (imm (* 3 (sizeof '*))))
  (scm-makinumr r0 r0)
  (local-set! st dst r0))

;;; XXX: Inline with JIT code.
(define-vm-op (string-ref st dst src idx)
  (jit-prepare)
  (jit-pushargr (local-ref st src))
  (jit-pushargr (local-ref st idx))
  (jit-calli (c-pointer "scm_string_ref"))
  (jit-retval r0)
  (local-set! st dst r0))

(define-vm-op (string->number st dst src)
  (jit-prepare)
  (jit-pushargr (local-ref st src))
  (jit-pushargi scm-undefined)
  (jit-calli (c-pointer "scm_string_to_number"))
  (jit-retval r0)
  (local-set! st dst r0))

(define-vm-op (string->symbol st dst src)
  (jit-prepare)
  (jit-pushargr (local-ref st src))
  (jit-calli (c-pointer "scm_string_to_symbol"))
  (jit-retval r0)
  (local-set! st dst r0))

(define-vm-op (symbol->keyword st dst src)
  (jit-prepare)
  (jit-pushargr (local-ref st src))
  (jit-calli (c-pointer "scm_symbol_to_keyword"))
  (jit-retval r0)
  (local-set! st dst r0))


;;; Pairs
;;; -----

(define-vm-op (cons st dst car cdr)
  (jit-prepare)
  (jit-pushargr reg-thread)
  (jit-pushargr (local-ref st car))
  (jit-pushargr (local-ref st cdr))
  (jit-calli (c-pointer "scm_do_inline_cons"))
  (jit-retval r0)
  (local-set! st dst r0))

(define-vm-op (car st dst src)
  (jit-ldr r0 (local-ref st src))
  (local-set! st dst r0))

(define-vm-op (cdr st dst src)
  (jit-ldxi r0 (local-ref st src) (imm (sizeof '*)))
  (local-set! st dst r0))

(define-vm-op (set-car! st pair car)
  (jit-str (local-ref st pair r0) (local-ref st car r1)))

(define-vm-op (set-cdr! st pair cdr)
  (jit-stxi (imm (sizeof '*)) (local-ref st pair r0) (local-ref st cdr r1)))


;;; Numeric operations
;;; ------------------

(define-vm-add-sub-op (add st dst a b)
  jit-boaddr jit-subi jit-addr-d "scm_sum")

(define-vm-unary-step-op (add1 st dst src)
  jit-boaddi jit-addr-d "scm_sum")

(define-vm-add-sub-op (sub st dst a b)
  jit-bosubr jit-addi jit-subr-d "scm_difference")

(define-vm-unary-step-op (sub1 st dst src)
  jit-bosubi jit-subr-d "scm_difference")

(define-vm-mul-div-op (mul st dst a b)
  jit-mulr-d "scm_product")

(define-vm-mul-div-op (div st dst a b)
  jit-divr-d "scm_divide")

(define-vm-op (quo st dst a b)
  (jit-prepare)
  (jit-pushargr (local-ref st a))
  (jit-pushargr (local-ref st b))
  (jit-calli (c-pointer "scm_quotient"))
  (jit-retval r0)
  (local-set! st dst r0))

(define-vm-op (rem st dst a b)
  (jit-prepare)
  (jit-pushargr (local-ref st a))
  (jit-pushargr (local-ref st b))
  (jit-calli (c-pointer "scm_remainder"))
  (jit-retval r0)
  (local-set! st dst r0))

(define-vm-op (make-vector st dst length init)
  (jit-prepare)
  (jit-pushargr (local-ref st length))
  (jit-pushargr (local-ref st init))
  (jit-calli (c-pointer "scm_make_vector"))
  (jit-retval r0)
  (local-set! st dst r0))

(define-vm-op (make-vector/immediate st dst length init)
  (jit-prepare)
  (jit-pushargr reg-thread)
  (jit-pushargi (imm (logior (tc7-vector) (ash length 8))))
  (jit-pushargi (imm (+ length 1)))
  (jit-calli (c-pointer "scm_do_inline_words"))
  (jit-retval r0)
  (local-ref st init r1)
  (for-each (lambda (n)
              (jit-stxi (imm (* (+ n 1) (sizeof '*))) r0 r1))
            (iota length))
  (local-set! st dst r0))

(define-vm-op (vector-length st dst src)
  (local-ref st src r0)
  (jit-ldr r0 r0)
  (jit-rshi r0 r0 (imm 8))
  (scm-makinumr r0 r0)
  (local-set! st dst r0))

(define-vm-op (vector-ref st dst src idx)
  (local-ref st src r0)
  (local-ref st idx r1)
  (jit-rshi r1 r1 (imm 2))
  (jit-addi r1 r1 (imm 1))
  (jit-muli r1 r1 (imm (sizeof '*)))
  (jit-ldxr r0 r0 r1)
  (local-set! st dst r0))

(define-vm-op (vector-ref/immediate st dst src idx)
  (local-ref st src r0)
  (jit-ldxi r0 r0 (imm (* (+ idx 1) (sizeof '*))))
  (local-set! st dst r0))

(define-vm-op (vector-set! st dst idx src)
  (local-ref st dst r0)
  (local-ref st idx r1)
  (local-ref st src r2)
  (jit-rshi r1 r1 (imm 2))
  (jit-addi r1 r1 (imm 1))
  (jit-muli r1 r1 (imm (sizeof '*)))
  (jit-stxr r1 r0 r2))

(define-vm-op (vector-set!/immediate st dst idx src)
  (local-ref st dst r0)
  (local-ref st src r1)
  (jit-stxi (imm (* (+ idx 1) (sizeof '*))) r0 r1))


;;; Structs and GOOPS
;;; -----------------

(define-vm-op (struct-vtable st dst src)
  (local-ref st src r0)
  (jit-ldr r0 r0)
  (jit-subi r0 r0 (imm (tc3-struct)))
  (jit-ldxi r0 r0 (imm (* 2 (sizeof '*))))
  (local-set! st dst r0))

(define-vm-op (allocate-struct/immediate st dst vtable nfields)
  (local-ref st vtable r0)
  (jit-prepare)
  (jit-pushargr r0)
  (jit-pushargi (scm-makinumi nfields))
  (jit-calli (program-free-variable-ref allocate-struct 0))
  (jit-retval r0)
  (local-set! st dst r0))

(define-vm-op (struct-ref st dst src idx)
  (local-ref st src r0)
  (local-ref st idx r1)
  (jit-rshi r1 r1 (imm 2))
  (jit-muli r1 r1 (imm (sizeof '*)))
  (jit-ldxi r0 r0 (imm (sizeof '*)))
  (jit-ldxr r0 r0 r1)
  (local-set! st dst r0))

(define-vm-op (struct-ref/immediate st dst src idx)
  (local-ref st src r0)
  (jit-ldxi r0 r0 (imm (sizeof '*)))
  (jit-ldxi r0 r0 (imm (* idx (sizeof '*))))
  (local-set! st dst r0))

(define-vm-op (struct-set!/immediate st dst idx src)
  (local-ref st dst r0)
  (local-ref st src r1)
  (jit-ldxi r0 r0 (imm (sizeof '*)))
  (jit-stxi (imm (* idx (sizeof '*))) r0 r1))

;;; XXX: class-of
;;; XXX: allocate-struct
;;; XXX: struct-set!


;;; Arrays, packed uniform arrays, and bytevectors
;;; ----------------------------------------------

;;; load-typed-array
;;; make-array
;;; bv-u8-ref
;;; bv-s8-ref
;;; bv-u16-ref
;;; bv-s16-ref
;;; bv-u32-ref
;;; bv-s32-ref
;;; bv-u64-ref
;;; bv-s64-ref
;;; bv-f32-ref
;;; bv-f64-ref
;;; bv-u8-set!
;;; bv-s8-set!
;;; bv-u16-set!
;;; bv-s16-set!
;;; bv-u32-set!
;;; bv-s32-set!
;;; bv-u64-set!
;;; bv-s64-set!
;;; bv-f32-set!
;;; bv-f64-set!

;;;
;;; Compilation
;;;

(define (compile-lightning st entry)
  "Compile <lightning> data specified by ST to native code using
lightning, with ENTRY as lightning's node to itself."
  (compile-lightning* st entry #t))

(define (compile-lightning* st entry toplevel?)
  "Compile <lightning> data specified by ST to native code using
lightning, with ENTRY as lightning's node to itself. If TOPLEVEL? is
true, the compiled result is for top level ."

  (define (destination-label st)
    (hashq-ref (lightning-labels st) (lightning-ip st)))

  (define (assemble-one st ip-x-op)
    (let* ((ip (car ip-x-op))
           (op (cdr ip-x-op))
           (instr (car op))
           (args (cdr op)))
      (set-lightning-ip! st ip)
      (let ((emitter (hashq-ref *vm-instr* instr)))
        (jit-note (format #f "~a" op) (lightning-ip st))
        ;; (debug 2 (make-string (lightning-indent st) #\space))
        ;; (debug 2 "~3d: ~a~%" ip op)
        ;; Link if this bytecode intruction is labeled as destination.
        (cond ((destination-label st)
               =>
               (lambda (label)
                 (jit-link label))))
        (or (and emitter (apply emitter st args))
            (format #t "compile-lightning: VM op not found `~a'~%" instr)))))

  (let* ((program-or-addr (lightning-pc st))
         (args (lightning-args st))
         (addr (ensure-program-addr program-or-addr))
         (trace (lightning-trace st))
         (name (program-name program-or-addr)))

    (hashq-set! (lightning-nodes st) addr entry)
    (jit-note name addr)

    ;; Link and compile the entry point.
    (jit-link entry)
    (jit-patch entry)
    (debug 1 ";;; compile-lightning: Start compiling ~a (~x)~%" name addr)
    (for-each (lambda (chunk)
                (assemble-one st chunk))
              (trace-ops trace))
    (set-lightning-nretvals! st (trace-nretvals (lightning-trace st)))
    (debug 1 ";;; compile-lightning: Finished compiling ~a (~x)~%" name addr)

    entry))


;;;
;;; Code generation and execution
;;;

(define (unwrap-non-program args program-or-addr)
  (cond
   ((struct? program-or-addr)
    (vector-set! args 0 (struct-ref program-or-addr 0))
    args)
   (else
    args)))

(define (write-code-to-file file pointer)
  (call-with-output-file file
    (lambda (port)
      (put-bytevector port (pointer->bytevector pointer (jit-code-size))))))

(define (call-lightning proc . args)
  "Compile PROC with lightning, and run with ARGS."
  (c-call-lightning (thread-i-data (current-thread)) proc args))

(define (c-call-lightning* thread proc args)
  "Like `c-call-lightning', but ARGS and PROC are pointers to scheme
values. Returned value of this procedure is a pointer to scheme value."
  (scm->pointer
   (c-call-lightning thread (pointer->scm proc) (pointer->scm args))))

(define %call-lightning
  (procedure->pointer '* c-call-lightning* '(* * *)))

(define (c-call-lightning thread proc args)
  "Compile PROC with lightning and run with ARGS, within THREAD."

  (define-syntax-rule (with-jit-state . expr)
    (parameterize ((jit-state (jit-new-state)))
      (call-with-values
          (lambda () . expr)
        (lambda vals
          (jit-destroy-state)
          (apply values vals)))))

  (define-syntax-rule (offset->addr offset)
    (imm (- (+ #xffffffffffffffff 1) (* offset (sizeof '*)))))

  (define-syntax vm-prolog
    (syntax-rules ()
      ((_ expr)
       (vm-prolog fp-addr expr))
      ((_ fp-addr expr)
       ;; XXX: Use vp->sp?
       (let* ((fp (jit-allocai (imm (* (sizeof '*) (+ 3 (length args))))))
              (fp-addr (logxor #xffffffff00000000 (pointer-address fp)))
              (return-address (jit-movi r1 (imm 0))))

         ;; XXX: Allocating constant amount at beginning of function call.
         ;; Might better to allocate at compile time or runtime.
         (jit-frame (imm (* 4 4096)))

         ;; Initial dynamic link, frame pointer.
         (jit-stxi (offset->addr 1) (jit-fp) (jit-fp))

         ;; Return address.
         (jit-stxi (offset->addr 2) (jit-fp) r1)

         ;; Argument 0, self procedure.
         (jit-movi r0 (scm->pointer proc))
         (jit-stxi (offset->addr 3) (jit-fp) r0)

         ;; Pointers of given args.
         (let lp ((args args) (offset 4))
           (unless (null? args)
             (jit-movi r0 (scm->pointer (car args)))
             (jit-stxi (offset->addr offset) (jit-fp) r0)
             (lp (cdr args) (+ offset 1))))

         ;; Initialize registers.
         (jit-movi reg-nargs (imm (+ (length args) 1)))
         (jit-movi reg-thread thread)
         (jit-movi reg-retval (scm->pointer *unspecified*))

         expr

         ;; Link the return address.
         (jit-patch return-address)))))

  (define-syntax-rule (vm-epilog nretvals)
    ;; Check number of return values, call C function `scm_values' if
    ;; 1 < number of values.
    (cond
     ((<= nretvals 1)
      (jit-retr reg-retval))
     (else
      (jit-prepare)
      (jit-movi r1 (offset->addr 4))
      (for-each (lambda (n)
                  (jit-ldxi r0 (jit-fp) (offset->addr (+ 4 n)))
                  (jit-pushargr r0))
                (iota nretvals))
      (jit-pushargi scm-undefined)
      (jit-calli (c-pointer "scm_list_n"))
      (jit-retval r1)
      (jit-prepare)
      (jit-pushargr r1)
      (jit-calli (c-pointer "scm_values"))
      (jit-retval r0)
      (jit-retr r0))))

  (let ((addr2 (ensure-program-addr proc))
        (args2 (apply vector proc args)))
    (cond
     ((primitive? proc)
      (debug 1 ";;; calling primitive: ~a~%" proc)
      (apply proc args))

     ((jit-compiled-code proc)
      =>
      (lambda (compiled)
        (debug 1 ";;; found jit compiled code of ~a at 0x~x.~%" proc compiled)
        (with-jit-state
         (jit-prolog)
         (vm-prolog (let ((entry (make-pointer compiled)))
                      (jit-movi r0 entry)
                      (jit-jmpr r0)))
         (vm-epilog (program-nretvals proc))
         (jit-epilog)
         (jit-realize)
         (let* ((fptr (jit-emit))
                (thunk (pointer->procedure '* fptr '())))
           (let ((verbosity (lightning-verbosity)))
             (when (and verbosity (<= 3 verbosity))
               (jit-print)
               (jit-clear-state)))
           (pointer->scm (thunk))))))

     ((program->trace addr2 (+ (length args) 1) #f)
      =>
      (lambda (trace)
        (with-jit-state
         (jit-prolog)
         (let* ((entry (jit-forward))
                (lightning #f))
           (vm-prolog fp-addr
                      (let* ((nargs (+ (length args) 1))
                             (args (apply vector proc args))
                             (fp0 (+ fp-addr (* (sizeof '*) nargs)))
                             (st (make-lightning trace
                                                 (make-hash-table)
                                                 fp0
                                                 nargs
                                                 args
                                                 addr2
                                                 0)))
                        (set! lightning st)
                        (compile-lightning lightning entry)))

           ;; XXX: Storing number of return values with object
           ;; property. When the program has variable number of return
           ;; values, (e.g: when calling `values' with `apply'), this
           ;; approach may not work.
           (set! (program-nretvals proc) (lightning-nretvals lightning))

           (vm-epilog (lightning-nretvals lightning))
           (jit-epilog)
           (jit-realize)

           ;; Emit and call the thunk.
           (let* ((estimated-code-size (jit-code-size))
                  (bv (make-bytevector estimated-code-size))
                  (_ (jit-set-code (bytevector->pointer bv)
                                   (imm estimated-code-size)))
                  (fptr (jit-emit))
                  (thunk (pointer->procedure '* fptr '())))

             ;; XXX: Any where else to store `bv'?
             (jit-code-guardian bv)
             (set-jit-compiled-code! proc (jit-address entry))
             (debug 1 ";;; set jit compiled code of ~a to ~a~%"
                    proc (jit-address entry))

             (let ((verbosity (lightning-verbosity)))
               (when (and verbosity (<= 3 verbosity))
                 (write-code-to-file
                  (format #f "/tmp/~a.o" (procedure-name proc)) fptr)
                 (jit-print)
                 (jit-clear-state)))

             (make-bytevector-executable! bv)
             (pointer->scm (thunk)))))))
     (else
      (debug 0 ";;; Trace failed, interpreting: ~a~%" (cons proc args))
      (let ((engine (vm-engine)))
        (dynamic-wind
          (lambda () (set-vm-engine! 'regular))
          (lambda () (apply proc args))
          (lambda () (set-vm-engine! engine))))))))


;;; This procedure is called from C function `vm_lightning'.
(define (vm-lightning thread fp registers nargs resume)
  (let* ((addr->scm
          (lambda (addr)
            (pointer->scm (dereference-pointer (make-pointer addr)))))
         (deref (lambda (addr)
                  (dereference-pointer (make-pointer addr))))
         (args (let lp ((n (- nargs 1)) (acc '()))
                 (if (< n 1)
                     acc
                     (lp (- n 1)
                         (cons (addr->scm (+ fp (* n (sizeof '*))))
                               acc))))))
    (c-call-lightning (make-pointer thread) (addr->scm fp) args)))


;;;
;;; Initialization
;;;

(init-jit "")
(load-extension (string-append "libguile-" (effective-version))
                "scm_init_vm_lightning")