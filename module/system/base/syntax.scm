;;; Guile VM specific syntaxes and utilities

;; Copyright (C) 2001 Free Software Foundation, Inc

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA

;;; Code:

(define-module (system base syntax)
  :use-module (srfi srfi-9)
  :export (%make-struct slot
           %slot-1 %slot-2 %slot-3 %slot-4 %slot-5
           %slot-6 %slot-7 %slot-8 %slot-9
           list-fold)
  :export-syntax (syntax define-type define-record record-case)
  :re-export-syntax (define-record-type))
(export-syntax |) ;; emacs doesn't like the |


;;;
;;; Keywords by `:KEYWORD
;;;

(read-set! keywords 'prefix)


;;;
;;; Dot expansion
;;;

;; FOO.BAR -> (slot FOO 'BAR)

(define (expand-dot! x)
  (cond ((symbol? x) (expand-symbol x))
	((pair? x)
	 (cond ((eq? (car x) 'quote) x)
	       (else (set-car! x (expand-dot! (car x)))
		     (set-cdr! x (expand-dot! (cdr x)))
		     x)))
	(else x)))

(define (expand-symbol x)
  (let* ((str (symbol->string x)))
    (if (string-index str #\.)
        (let ((parts (map string->symbol (string-split str #\.))))
          `(slot ,(car parts)
                 ,@(map (lambda (key) `',key) (cdr parts))))
        x)))

(define syntax expand-dot!)


;;;
;;; Type
;;;

(define-macro (define-type name sig) sig)

;;;
;;; Record
;;;

(define-macro (define-record def)
  (let ((name (car def)) (slots (cdr def)))
    `(begin
       (define (,name . args)
	 (vector ',name (%make-struct
			 args
			 (list ,@(map (lambda (slot)
					(if (pair? slot)
					  `(cons ',(car slot) ,(cadr slot))
					  `',slot))
				      slots)))))
       (define (,(symbol-append name '?) x)
	 (and (vector? x) (eq? (vector-ref x 0) ',name)))
       ,@(do ((n 1 (1+ n))
	      (slots (cdr def) (cdr slots))
	      (ls '() (cons (let* ((slot (car slots))
				   (slot (if (pair? slot) (car slot) slot)))
			      `(define ,(string->symbol
					 (format #f "~A-~A" name n))
				 (lambda (x) (slot x ',slot))))
			    ls)))
	     ((null? slots) (reverse! ls))))))

(define *unbound* "#<unbound>")

(define (%make-struct args slots)
  (map (lambda (slot)
	 (let* ((key (if (pair? slot) (car slot) slot))
		(def (if (pair? slot) (cdr slot) *unbound*))
		(val (get-key args (symbol->keyword key) def)))
	   (if (eq? val *unbound*)
	     (error "slot unbound" key)
	     (cons key val))))
       slots))

(define (get-key klist key def)
  (do ((ls klist (cddr ls)))
      ((or (null? ls) (eq? (car ls) key))
       (if (null? ls) def (cadr ls)))))

(define (get-slot struct name . names)
  (let ((data (assq name (vector-ref struct 1))))
    (cond ((not data) (error "unknown slot" name))
          ((null? names) (cdr data))
          (else (apply get-slot (cdr data) names)))))

(define (set-slot! struct name . rest)
  (let ((data (assq name (vector-ref struct 1))))
    (cond ((not data) (error "unknown slot" name))
          ((null? (cdr rest)) (set-cdr! data (car rest)))
          (else (apply set-slot! (cdr data) rest)))))

(define slot
  (make-procedure-with-setter get-slot set-slot!))


;;;
;;; Variants
;;;

(define-macro (| . rest)
  `(begin ,@(map %make-variant-type rest)))

(define (%make-variant-type def)
  (let ((name (car def)) (slots (cdr def)))
    `(begin
       (define ,def (vector ',name ,@slots))
       (define (,(symbol-append name '?) x)
	 (and (vector? x) (eq? (vector-ref x 0) ',name)))
       ,@(do ((n 1 (1+ n))
	      (slots slots (cdr slots))
	      (ls '() (cons `(define ,(string->symbol
				       (format #f "~A-~A" name n))
			       ,(string->symbol (format #f "%slot-~A" n)))
			    ls)))
	     ((null? slots) (reverse! ls))))))

(define (%slot-1 x) (vector-ref x 1))
(define (%slot-2 x) (vector-ref x 2))
(define (%slot-3 x) (vector-ref x 3))
(define (%slot-4 x) (vector-ref x 4))
(define (%slot-5 x) (vector-ref x 5))
(define (%slot-6 x) (vector-ref x 6))
(define (%slot-7 x) (vector-ref x 7))
(define (%slot-8 x) (vector-ref x 8))
(define (%slot-9 x) (vector-ref x 9))

(define-macro (record-case record . clauses)
  (let ((r (gensym)))
    (define (process-clause clause)
      (let ((record-type (caar clause))
            (slots (cdar clause))
            (body (cdr clause)))
        `(((record-predicate ,record-type) ,r)
          (let ,(map (lambda (slot)
                       `(,slot ((record-accessor ,record-type ',slot) ,r)))
                     slots)
            ,@body))))
    `(let ((,r ,record))
       (cond ,@(map process-clause clauses)
             (else (error "unhandled record" ,r))))))

;; These are short-lived, and headed to the chopping block.
(use-modules (ice-9 match))
(define-macro (record-case record . clauses)
  (define (process-clause clause)
    (if (eq? (car clause) 'else)
        clause
        `(($ ,@(car clause)) ,@(cdr clause))))
  `(match ,record ,@(map process-clause clauses)))

(define (record? x)
  (and (vector? x)
       (not (zero? (vector-length x)))
       (symbol? (vector-ref x 0))
       (eqv? (string-ref (symbol->string (vector-ref x 0)) 0) #\<)))
(export record?)


;;;
;;; Utilities
;;;

(define (list-fold f d l)
  (if (null? l)
      d
      (list-fold f (f (car l) d) (cdr l))))
