;;;; ANF IR for specialized call stubs

;;;; Copyright (C) 2015, 2016 Free Software Foundation, Inc.
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
;;;
;;; Module containing ANF IR definitions for specialized call stub operations.
;;;
;;; Code:

(define-module (language trace ir-specialized)
  #:use-module (system foreign)
  #:use-module (system vm program)
  #:use-module (system vm native debug)
  #:use-module (language trace error)
  #:use-module (language trace ir)
  #:use-module (language trace env)
  #:use-module (language trace parameters)
  #:use-module (language trace primitives)
  #:use-module (language trace snapshot)
  #:use-module (language trace types)
  #:use-module (language trace variables))



(define-scan (subr-call)
  (let* ((stack-size (vector-length locals))
         (proc-offset (- stack-size 1))
         (ra-offset stack-size)
         (dl-offset (+ ra-offset 1))
         (sp-offset (env-sp-offset env)))
    (let lp ((n 0) (types '()))
      (if (= n proc-offset)
          (set-entry-types! env types)
          (lp (+ n 1) (cons (cons n &scm) types))))
    (set-scan-initial-fields! env)
    (add-env-return! env)
    (pop-scan-sp-offset! env (- stack-size 2))
    (pop-scan-fp-offset! env dl)))

;;; XXX: Multiple values return not yet implemented.
(define-ti (subr-call)
  ;; Filling in return address and dynamic link with false.
  (let* ((stack-size (vector-length locals))
         (sp-offset (current-sp-for-ti))
         (proc-offset (+ (- stack-size 1) sp-offset))
         (ra-offset (+ proc-offset 1))
         (dl-offset (+ ra-offset 1)))
    (set-inferred-type! env ra-offset &false)
    (set-inferred-type! env dl-offset &false)
    ;; Returned value from C function is stored in (- proc-offset 1). The stack
    ;; item type of the returned value is always `scm'.
    (set-inferred-type! env (- proc-offset 1) &scm)))

(define-anf (subr-call)
  (let* ((stack-size (vector-length locals))
         (dst/v (dst-ref (- stack-size 2)))
         (subr/l (scm-ref (- stack-size 1)))
         (subr/a (object-address subr/l))
         (ccode (and (program? subr/l)
                     (program-code subr/l)))
         (proc-addr (object-address subr/l))
         (emit-ccall
          (lambda ()
            (if (inline-current-return?)
                `(let ((,dst/v (,%ccall ,proc-addr)))
                   ,(next))
                `(let ((_ ,(take-snapshot! ip 0)))
                   (let ((_ (,%return ,dl ,ra)))
                     (let ((,dst/v (,%ccall ,proc-addr)))
                       ,(next)))))))
         (r1 (make-tmpvar 1))
         (r2 (make-tmpvar 2)))
    (define-syntax-rule (subr? subr)
      (eq? subr/a (object-address subr)))
    (when (not (primitive-code? ccode))
      (failure 'subr-call "not a primitive ~s" subr/l))
    ;; Inline if callee was known C function.
    (cond
     ;; pairs.c
     ((subr? cons)
      (set-env-handle-interrupts! env #t)
      `(let ((,dst/v (,%cell ,(src-ref 1) ,(src-ref 0))))
         ,(next)))
     ((subr? car)
      (with-type-guard &pair 0
        `(let ((,dst/v (,%cref ,(src-ref 0) 0)))
           ,(next))))
     ((subr? cdr)
      (with-type-guard &pair 0
        `(let ((,dst/v (,%cref ,(src-ref 0) 1)))
           ,(next))))
     ((subr? cadr)
      `(let ((_ ,(take-snapshot! ip 0)))
         ,(with-type-guard &pair 0
            `(let ((,r1 (,%cref ,(src-ref 0) 1)))
               (let ((_ (,%tceq ,r1 1 ,%tc3-cons)))
                 (let ((,dst/v (,%cref ,r1 0)))
                   ,(next)))))))
     ;; ports.c
     ((subr? eof-object?)
      (if (eof-object? (scm-ref 0))
          `(let ((_ (,%eq ,(src-ref 0) #xa04)))
             (let ((,dst/v #t))
               ,(next)))
          `(let ((_ (,%ne ,(src-ref 0) #xa04)))
             (let ((,dst/v #f))
               ,(next)))))
     ;; strings.c
     ((subr? string-ref)
      `(let ((_ (,%carg ,(src-ref 0))))
         (let ((_ (,%carg ,(src-ref 1))))
           (let ((,dst/v (,%ccall ,(object-address scm-do-i-string-ref))))
             ,(next)))))
     (else
      ;; Not inlineable, emit `%ccall' primitive.
      (set-env-handle-interrupts! env #t)
      (let lp ((n 0))
        (if (< n (- stack-size 1))
            (let ((n/v (src-ref n))
                  (n/l (scm-ref n))
                  (r1 (make-tmpvar 2))
                  (t (type-ref n)))
              (with-boxing t n/v r1
                (lambda (boxed)
                  `(let ((_ (,%carg ,boxed)))
                     ,(lp (+ n 1))))))
            (emit-ccall)))))))

;; XXX: foreign-call

;; XXX: continuation-call
;; (define-ir (continuation-call (const contreg-idx))
;;   (let* ((stack-size (vector-length locals))
;;          (cont/i (- stack-size 1))
;;          (cont/v (src-ref cont/i))
;;          (cont/l (scm-ref cont/i))
;;          (contreg (program-free-variable-ref cont/l contreg-idx))
;;          (next-ip (continuation-next-ip contreg))
;;          (r2 (make-tmpvar 2))
;;          (test (lambda _ #t))
;;          (live-indices (env-live-indices env))
;;          (snapshot-id (ir-snapshot-id ir)))
;;     (debug 1 ";;; [IR] continuation-call, next-ip=~x~%" next-ip)
;;     (set-env-live-indices! env (list (current-sp-offset)))
;;     `(let ((_ ,(take-snapshot! ip 0)))
;;        (let ((,r2 (%cref ,cont/v ,(+ 2 contreg-idx))))
;;          (let ((_ (%callcnt ,(var-ref 0) ,cont/i ,snapshot-id ,next-ip)))
;;            ,(next))))))

;; XXX: compose-continuation
;; XXX: tail-apply

(define-ir (call/cc)
  (let ((cont/v (var-ref 0))
        (dst/v (var-ref 1))
        (cont/l (scm-ref 0))
        (r2 (make-tmpvar 2)))
    ;; Using special IP key to skip restoring stack element on bailout. Before
    ;; bailout code of call/cc, stack elements have been filled in with captured
    ;; data data by continuation-call.
    `(let ((_ ,(take-snapshot! *ip-key-longjmp* 0)))
       (let ((,r2 (,%call/cc ,(- (ir-snapshot-id ir) 1))))
         (let ((,dst/v ,cont/v))
           (let ((,cont/v ,r2))
             ,(next)))))))

;; XXX: abort

(define-ir (builtin-ref (scm! dst) (const idx))
  (let ((ref (case idx
               ((0) apply)
               ((1) values)
               ((2) abort-to-prompt)
               ((3) call-with-values)
               ((4) call-with-current-continuation)
               (else (failure 'builtin-ref "unknown builtin ~a" idx)))))
    `(let ((,(dst-ref dst) ,(object-address ref)))
       ,(next))))
