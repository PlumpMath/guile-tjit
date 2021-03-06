;;;; Fragment data type

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
;;; A module defining data types for fragment. Fragment is a log of native
;;; compilation. Fragments are stored in hash table for later use.
;;;
;;; Code:

(define-module (language trace fragment)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (system vm native debug)
  #:use-module (language trace parameters)
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
            fragment-bailout-code set-fragment-bailout-code!
            fragment-handle-interrupts?
            fragment-side-trace-ids set-fragment-side-trace-ids!
            fragment-linked-root-ids set-fragment-linked-root-ids!
            fragment-num-child set-fragment-num-child!

            put-fragment!
            get-fragment
            get-root-trace
            get-origin-fragment
            increment-fragment-num-child!
            remove-fragment-and-side-traces))


;;;; The fragment data

;; Record type to contain various information for compilation of trace to native
;; code.  Information stored in this record type is used when re-entering hot
;; bytecode IP, patching native code from side exit, ... etc.
;;
;; This record type is shared with C code. C macros written in
;; "libguile/vm-tjit.h" with "SCM_FRAGMENT" prefix are referring the fields.
;;
(define-record-type <fragment>
  (%make-fragment id code exit-counts downrec? uprec? type-checker entry-ip
                  num-child parent-id parent-exit-id
                  loop-address loop-locals loop-vars
                  snapshots trampoline end-address gdb-jit-entry storage
                  bailout-code handle-interrupts?
                  side-trace-ids linked-root-ids)
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

  ;; Number of child traces, for root trace only.
  (num-child fragment-num-child set-fragment-num-child!)

  ;; Trace id of parent trace, or #f for root trace.
  (parent-id fragment-parent-id)

  ;; Exit id taken by parent, or #f for root trace.
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
  (bailout-code fragment-bailout-code set-fragment-bailout-code!)

  ;; Flag for handling interrupts.
  (handle-interrupts? fragment-handle-interrupts?)

  ;; Side trace IDs of this fragment, referred when removing.
  (side-trace-ids fragment-side-trace-ids set-fragment-side-trace-ids!)

  ;; Root trace IDs linked via side trace, referred when removing.
  (linked-root-ids fragment-linked-root-ids set-fragment-linked-root-ids!))

(define make-fragment %make-fragment)

(define (print-fragment fragment port)
  (format port "#<fragment id:~a entry-ip:~x parent-id:~a>"
          (fragment-id fragment)
          (fragment-entry-ip fragment)
          (fragment-parent-id fragment)))

(set-record-type-printer! <fragment> print-fragment)

(define-inlinable (root-trace-fragment? fragment)
  (not (fragment-parent-id fragment)))

(define (put-fragment! trace-id fragment)
  (hashq-set! (tjit-fragment) trace-id fragment)
  (when (root-trace-fragment? fragment)
    (tjit-add-root-ip! (fragment-entry-ip fragment))
    (let* ((tbl (tjit-root-trace))
           (ip (fragment-entry-ip fragment))
           (fragments (or (and=> (hashq-ref tbl ip)
                                 (lambda (fragments)
                                   (cons fragment fragments)))
                          (list fragment))))
      (hashq-set! tbl ip fragments))))

(define (get-fragment fragment-id)
  (and fragment-id (hashq-ref (tjit-fragment) fragment-id #f)))

(define (get-root-trace types ip)
  (let lp ((fragments (hashq-ref (tjit-root-trace) ip #f)))
    (match fragments
      ((fragment . fragments)
       (if ((fragment-type-checker fragment) types)
           fragment
           (lp fragments)))
      (_ #f))))

(define (get-origin-fragment fragment)
  "Get origin root trace fragment of FRAGMENT."
  (let lp ((fragment fragment))
    (and fragment
         (let ((parent-id (fragment-parent-id fragment)))
           (if parent-id
               (lp (get-fragment parent-id))
               fragment)))))

(define (increment-fragment-num-child! fragment)
  (let ((num-child (fragment-num-child fragment)))
    (set-fragment-num-child! fragment (+ num-child 1))))

(define (remove-fragment-and-side-traces fragment)
  "Removes FRAGMENT, which is a root trace.

Removes the FRAGMENT itself, its side traces and linked fragment from global
cache."
  (letrec ((cache (tjit-fragment))
           (root-ip (fragment-entry-ip fragment))
           (linked-ids (fragment-linked-root-ids fragment))
           (remove-side-traces-and-self
            (lambda (fragment)
              (let lp ((ids (fragment-side-trace-ids fragment)))
                (if (null? ids)
                    (let ((id (fragment-id fragment)))
                      (hashq-remove! cache id))
                    (begin
                      (and=> (get-fragment (car ids))
                             remove-side-traces-and-self)
                      (lp (cdr ids)))))))
           (remove-root-trace
            (lambda (fragment)
              ;; Remove root trace from cache table, and update `root_ip_ref'
              ;; via C function, then remove left over side traces.
              (tjit-remove-root-ip! (fragment-entry-ip fragment))
              (remove-side-traces-and-self fragment)

              ;; Call remove-side-traces-and-self for linked root traces.
              (let lp ((ids (fragment-linked-root-ids fragment)))
                (unless (null? ids)
                  (let ((linked-fragment (get-fragment (car ids))))
                    (when linked-fragment
                      (let ((linked-fragment-ip
                             (fragment-entry-ip linked-fragment)))
                        (remove-root-trace linked-fragment)
                        (tjit-remove-root-ip! linked-fragment-ip))))
                  (lp (cdr ids)))))))
    (remove-root-trace fragment)))
