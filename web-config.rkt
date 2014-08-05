#lang racket/base

(provide web-acl
         web-reduced-redundancy?
         web-upload-metadata

         web-gzip-rx
         web-gzip-min-size)

(define web-acl "public-read")
(define web-reduced-redundancy? #t)
(define web-upload-metadata (hash 'Cache-Control "max-age=0, no-cache"))

(define web-gzip-rx #rx"[.](html|css|js)$")
(define web-gzip-min-size 1024)
