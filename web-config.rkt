#lang racket/base
(require net/url
         racket/string)

(provide web-acl
         web-reduced-redundancy?
         web-upload-metadata
         web-upload-metadata-mapping

         web-gzip-rx
         web-gzip-min-size

         web-make-redirect-download)

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

(define (web-make-redirect-download rx dest)
  (lambda (path)
    (cond
      [(regexp-match? rx path)
       (define sub-dest
         (cond
           [(link-exists? path)
            (define rel-dest (resolve-path path))
            (simplify-path (let-values ([(base name dir?) (split-path path)])
                             (if (eq? base 'relative)
                                 rel-dest
                                 (build-path base rel-dest))))]
           [else path]))
       (combine-url/relative dest
                             (string-join (map path-element->string (explode-path sub-dest))
                                          "/"))]
      [else #f])))
