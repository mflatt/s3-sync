#lang racket/base
(require file/gzip
         racket/path
         racket/port)

(provide make-gzip-handlers)

(define (call-with-gzipped-input-file f proc)
  (define-values (i o) (make-pipe))
  (define th
    (thread
     (lambda ()
       (call-with-input-file* 
        f
        (lambda (i)
          (gzip-through-ports i o (file-name-from-path f) 0)
          (close-output-port o))))))
  (begin0
   (proc i)
   (kill-thread th)))

(define (make-gzip-handlers gzip-rx 
                            #:min-size [gzip-size 0])
  (define (gzip? dest src)
    (and (regexp-match? gzip-rx dest)
         ((file-size src) . >= . gzip-size)))

  (values (lambda (dest src)
            (if (gzip? dest src)
                call-with-gzipped-input-file
                call-with-input-file))
          (lambda (dest src)
            (and (gzip? dest src)
                 "gzip"))))
