;;;; Fragment data type

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
;;;
;;; A module defining data types for fragment. Fragment is a log of native
;;; compilation. Fragments are stored in hash table for later use.
;;;
;;; Code:

(define-module (system vm native tjit fragment)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-9)
  #:use-module (system vm native tjit parameters)
  #:export (<fragment>
            make-fragment
            fragment-id
            fragment-code
            fragment-exit-counts
            fragment-type-checker
            fragment-entry-ip
            fragment-parent-id
            fragment-parent-exit-id
            fragment-snapshots
            fragment-exit-codes
            fragment-trampoline
            fragment-loop-address
            fragment-loop-locals
            fragment-loop-vars
            fragment-end-address
            fragment-gdb-jit-entry
            fragment-storage
            fragment-bailout-code
            fragment-handle-interrupts?
            fragment-side-trace-ids set-fragment-side-trace-ids!

            put-fragment!
            get-fragment
            get-root-trace
            get-origin-fragment
            remove-fragment-and-side-traces))

;;;
;;; The fragment data
;;;

;; Record type to contain various information for compilation of trace to native
;; code.  Information stored in this record type is used when re-entering hot
;; bytecode IP, patching native code from side exit, ... etc.
;;
;; This record type is shared with C code. C macros written in
;; "libguile/vm-tjit.h" with "SCM_FRAGMENT" prefix are referring the fields.
;;
(define-record-type <fragment>
  (%make-fragment id code exit-counts downrec? uprec? type-checker entry-ip
                  parent-id parent-exit-id loop-address loop-locals loop-vars
                  snapshots trampoline end-address gdb-jit-entry storage
                  bailout-code handle-interrupts? side-trace-ids)
  fragment?

  ;; Trace id number.
  (id fragment-id)

  ;; Bytevector of compiled native code.
  (code fragment-code)

  ;; Hash-table containing number of exits taken, per exit-id.
  (exit-counts fragment-exit-counts)

  ;; Flag to tell whether the trace was down-recursion or not.
  (downrec? fragment-downrec?)

  ;; Flag to tell whether the trace was up-recursion or not.
  (uprec? fragment-uprec?)

  ;; Procedure to check types for entering native code.
  (type-checker fragment-type-checker)

  ;; Entry bytecode IP.
  (entry-ip fragment-entry-ip)

  ;; Trace id of parent trace, 0 for root trace.
  (parent-id fragment-parent-id)

  ;; Exit id taken by parent, root traces constantly have 0.
  (parent-exit-id fragment-parent-exit-id)

  ;; Address of start of loop.
  (loop-address fragment-loop-address)

  ;; Local header information of loop.
  (loop-locals fragment-loop-locals)

  ;; Variable header information of loop.
  (loop-vars fragment-loop-vars)

  ;; Snapshot locals and types.
  (snapshots fragment-snapshots)

  ;; Trampoline, native code containing jump destinations.
  (trampoline fragment-trampoline)

  ;; End address.
  (end-address fragment-end-address)

  ;; GDB JIT entry.
  (gdb-jit-entry fragment-gdb-jit-entry)

  ;; Hash table of variable symbol => assigned register
  (storage fragment-storage)

  ;; Native code for bailout.
  (bailout-code fragment-bailout-code)

  ;; Flag for handling interrupts
  (handle-interrupts? fragment-handle-interrupts?)

  ;; Side trace IDs of this fragment
  (side-trace-ids fragment-side-trace-ids set-fragment-side-trace-ids!))

(define make-fragment %make-fragment)

(define (root-trace-fragment? fragment)
  (zero? (fragment-parent-id fragment)))

(define (put-fragment! trace-id fragment)
  (hashq-set! (tjit-fragment) trace-id fragment)
  (when (root-trace-fragment? fragment)
    (tjit-add-root-ip! (fragment-entry-ip fragment))
    (let* ((tbl (tjit-root-trace))
           (ip (fragment-entry-ip fragment))
           (fragments (cond
                       ((hashq-ref tbl ip)
                        => (lambda (fragments)
                             (cons fragment fragments)))
                       (else
                        (list fragment)))))
      (hashq-set! tbl ip fragments))))

(define (get-fragment fragment-id)
  (hashq-ref (tjit-fragment) fragment-id #f))

(define (get-root-trace types locals ip)
  (let lp ((fragments (hashq-ref (tjit-root-trace) ip #f)))
    (match fragments
      ((fragment . fragments)
       (if ((fragment-type-checker fragment) types locals)
           fragment
           (lp fragments)))
      (_ #f))))

(define (get-origin-fragment fragment)
  "Get origin root trace fragment of FRAGMENT."
  (let lp ((fragment fragment))
    (if (not fragment)
        #f
        (let ((parent-id (fragment-parent-id fragment)))
          (if (zero? parent-id)
              fragment
              (lp (get-fragment parent-id)))))))

(define (remove-fragment-and-side-traces fragment)
  "Remove FRAGMENT and its side traces from global cached table."
  (letrec ((go (lambda (fragment)
                 (let lp ((ids (fragment-side-trace-ids fragment)))
                   (if (null? ids)
                       (tjit-remove-fragment! (fragment-id fragment))
                       (begin
                         (and=> (get-fragment (car ids)) go)
                         (lp (cdr ids))))))))
    (go fragment)))
