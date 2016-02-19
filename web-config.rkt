#lang racket/base

(provide web-acl
         web-reduced-redundancy?
         web-upload-metadata
         web-upload-metadata-mapping

         web-gzip-rx
         web-gzip-min-size)

(define web-acl "public-read")
(define web-reduced-redundancy? #t)
(define web-upload-metadata (hash 'Cache-Control "max-age=0, no-cache"))
(define web-upload-metadata-mapping
  (lambda (key)
    (if (regexp-match? #rx"[.](?:css|js|png|jpe?g|gif|svg|ico|woff)$" key)
        ;; Cache for one year:
        (hash 'Cache-Control "max-age=31536000, public")
        (hash))))
(define web-gzip-rx #rx"[.](html|css|js|svg)$")
(define web-gzip-min-size 1024)
