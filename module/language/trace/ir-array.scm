;;;; ANF IR for arrays, packed uniform arrays, and bytevectors

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
;;; Module containing ANF IR definitions for arrays, packed uniform arrays, and
;;; bytevectors.
;;;
;;; Code:

(define-module (language trace ir-array)
  #:use-module (system foreign)
  #:use-module (language trace error)
  #:use-module (language trace ir)
  #:use-module (language trace env)
  #:use-module (language trace primitives)
  #:use-module (language trace snapshot)
  #:use-module (language trace types)
  #:use-module (language trace variables))



;; XXX: load-typed-array
;; XXX: make-array

;; XXX: Bound check not yet done.
(define-ir (bv-u8-ref (u64! dst) (bytevector src) (u64 idx))
  (let* ((src/v (src-ref src))
         (idx/v (src-ref idx))
         (dst/v (dst-ref dst))
         (tmp (make-tmpvar 2)))
    (with-type-guard &bytevector src
      `(let ((,tmp (,%cref ,src/v 2)))
         (let ((,dst/v (,%u8ref ,tmp ,idx/v)))
           ,(next))))))

;; XXX: bv-s8-ref
;; XXX: bv-u16-ref
;; XXX: bv-s16-ref
;; XXX: bv-u32-ref
;; XXX: bv-s32-ref
;; XXX: bv-u64-ref
;; XXX: bv-s64-ref
;; XXX: bv-f32-ref
;; XXX: bv-f64-ref

;; XXX: Bound check not yet done.
(define-ir (bv-u8-set! (bytevector dst) (u64 idx) (u64 src))
  (let* ((idx/v (src-ref idx))
         (src/v (src-ref src))
         (dst/v (src-ref dst))
         (tmp1 (make-tmpvar 1))
         (tmp2 (make-tmpvar 2)))
    (with-type-guard &bytevector dst
      `(let ((,tmp2 (,%cref ,dst/v 2)))
         (let ((_ (,%u8set ,tmp2 ,idx/v ,src/v)))
           ,(next))))))

;; XXX: bv-s8-set!
;; XXX: bv-u16-set!
;; XXX: bv-s16-set!
;; XXX: bv-u32-set!
;; XXX: bv-s32-set!
;; XXX: bv-u64-set!
;; XXX: bv-s64-set!
;; XXX: bv-f32-set!
;; XXX: bv-f64-set!

(define-ir (bv-length (u64! dst) (bytevector src))
  (let* ((src/v (src-ref src))
         (dst/v (dst-ref dst)))
    (with-type-guard &bytevector src
      `(let ((,dst/v (,%cref ,src/v 1)))
         ,(next)))))
