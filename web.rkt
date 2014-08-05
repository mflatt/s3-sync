#lang racket/base
(require "main.rkt"
         "web-config.rkt"
         "gzip.rkt")

(provide s3-web-sync)

(define-values (call-with-gzip-file gzip-content-encoding)
  (make-gzip-handlers web-gzip-rx #:min-size web-gzip-min-size))

(define s3-web-sync
  (let-values ([(req-kws allowed-kws) (procedure-keywords s3-sync)])
    (procedure-reduce-keyword-arity
     (make-keyword-procedure
      (lambda (in-kws in-kw-vals . rest)
        (define-values (kws kw-vals)
          (add* in-kws in-kw-vals
                (list '#:acl web-acl
                      '#:reduced-redundancy? web-reduced-redundancy?
                      '#:upload-metadata web-upload-metadata
                      '#:make-call-with-input-file call-with-gzip-file
                      '#:get-content-encoding gzip-content-encoding)))
        (keyword-apply s3-sync kws kw-vals rest)))
     (procedure-arity s3-sync)
     req-kws
     allowed-kws)))

(define (add* kws kw-vals adjs)
  (define ht (for/hash ([kw (in-list kws)]
                        [kw-val (in-list kw-vals)])
               (values kw kw-val)))
  (define new-ht
    (let loop ([ht ht] [adjs adjs])
      (cond
       [(null? adjs) ht]
       [else
        (define kw (car adjs))
        (define kw-val (cadr adjs))
        (cond
         [(hash-ref ht kw #f)
          (loop ht (cddr adjs))]
         [else
          (loop (hash-set ht kw kw-val) (cddr adjs))])])))
  (define l (hash-map new-ht cons))
  (define sorted-l (sort l keyword<? #:key car))
  (values (map car sorted-l)
          (map cdr sorted-l)))
