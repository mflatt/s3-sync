#lang racket/base
(require aws/keys
         aws/s3
         racket/file
         racket/path
         racket/string
         racket/cmdline
         racket/format
         racket/port
         racket/set
         openssl/md5
         net/url
         net/uri-codec
         http/head
         xml)

(provide s3-sync)

(define-logger s3-sync)

(define (path->content-type p)
  (case (filename-extension p)
    [(#"html") "text/html"]
    [(#"png") "image/png"]
    [(#"gif") "image/gif"]
    [(#"js") "text/javascript"]
    [(#"css") "text/css"]
    [else "application/octet-stream"]))

(define (encode-path p)
  (string-join
   (map uri-encode (string-split p "/"))
   "/"))

(define MULTIPART-THRESHOLD (* 1024 1024 10))
(define CHUNK-SIZE MULTIPART-THRESHOLD)

(define (file-md5 f)
  (cond
   [((file-size f) . > . MULTIPART-THRESHOLD)
    (define buffer (make-bytes CHUNK-SIZE))
    (define-values (i o) (make-pipe))
    (define n 
      (call-with-input-file f
        (lambda (i)
          (let loop ([n 0])
            (define m (read-bytes! buffer i))
            (cond
             [(eof-object? m) n]
             [(= m CHUNK-SIZE)
              (display (md5-bytes (open-input-bytes buffer)) o)
              (loop (add1 n))]
             [else
              (display (md5-bytes (open-input-bytes (subbytes buffer 0 m))) o)
              (add1 n)])))))
    (close-output-port o)
    (string-append (md5 i) "-" (number->string n))]
   [else
    (call-with-input-file f md5)]))

(define (s3-sync src-dir bucket sub
                 #:upload? [upload? #t]
                 #:error [error error]
                 #:dry-run? [dry-run? #f]
                 #:delete? [delete? #f]
                 #:include [include-rx #f]
                 #:exclude [exclude-rx #f]
                 #:acl [acl #f]
                 #:reduced-redundancy? [reduced-redundancy? #f]
                 #:link-mode [link-mode 'error]
                 #:log [log-info (lambda (s)
                                   (log-s3-sync-info s))])
  (log-info (let ([remote (~a bucket
                              (if sub (~a "/" (encode-path sub)) ""))]
                  [local src-dir])
              (format "Syncing: ~a from: ~a"
                      (if upload? remote local)
                      (if upload? local remote))))

  (define download? (not upload?))
  
  (define upload-props
    (let* ([ht (hash)]
           [ht (if reduced-redundancy?
                   (hash-set ht 'x-amz-storage-class "REDUCED_REDUNDANCY")
                   ht)]
           [ht (if acl
                   (hash-set ht 'x-amz-acl acl) ; "public-read"
                   ht)])
      ht))

  (define (included? s)
    (let ([s (if (path? s)
                 ;; Force unix-style path:
                 (string-join (map path->string (explode-path s)) "/")
                 s)])
      (and (or (not include-rx)
               (regexp-match? include-rx s))
           (or (not exclude-rx)
               (not (regexp-match? exclude-rx s))))))
  
  (log-info "Getting current S3 content...")
  (define (get-name x)
    (caddr (assq 'Key (cddr x))))
  (define (get-etag x)
    (cadddr (assq 'ETag (cddr x))))
  (define remote-content
    (ls/proc (~a bucket "/" (if sub
                                (~a (encode-path sub) "/")
                                ""))
             (lambda (ht xs)
               (for/fold ([ht ht]) ([x (in-list xs)]
                                    #:when (included? (get-name x)))
                 (hash-set ht
                           (get-name x)
                           (get-etag x))))
             (hash)))
  (log-info "... got it.")

  (define (check-link-exists f)
    (if (link-exists? f)
        (error 's3-sync
               (~a "encountered soft link\n"
                   "  path: ~a")
               f)
        #t))

  (define (failure what f s)
    (error 's3-sync (~a "~a failed\n"
                        "  path: ~a\n"
                        "  server response: ~s")
           what
           f
           s))

  (define (download key f)
    (log-info (format "Download: ~a to: ~a" key f))
    (unless dry-run?
      (let-values ([(base name dir?) (split-path (build-path src-dir f))])
        (when (path? base)
          (make-directory* base)))
      (get/file (b+p f)
                (build-path src-dir f)
                #:exists 'truncate/replace)))

  (define (b+p f)
    (~a bucket "/"
        (if sub (~a (encode-path sub) "/") "")
        (encode-path (string-join (map path-element->string (explode-path f))
                                  "/"))))

  (define (key->f key)
    (define p (cond
               [sub
                (define len (string-length sub))
                (unless (and ((string-length key) . > . (add1 len))
                             (string=? sub (substring key 0 len))
                             (char=? #\/ (string-ref key len)))
                  (error 's3-sync "internal error: bad prefix on key"))
                (substring key (add1 len))]
               [else key]))
    (apply build-path (string-split p "/")))
  
  (define local-content
    (if (and download?
             (not (directory-exists? src-dir))
             (not (link-exists? src-dir)))
        (set)
        (parameterize ([current-directory src-dir])
          (for/set ([f (in-directory #f (lambda (dir)
                                          (and (included? dir)
                                               (case link-mode
                                                 [(redirect ignore) (not (link-exists? dir))]
                                                 [(error) (check-link-exists dir)]
                                                 [else #t]))))]
                    #:when (and (included? f)
                                (case link-mode
                                  [(follow) #t]
                                  [(redirect ignore) (not (link-exists? f))]
                                  [(error) (check-link-exists f)])
                                (file-exists? f)))
            
            (define key (path->string (if sub (build-path sub f) f)))
            (define old (hash-ref remote-content key #f))
            (define new (file-md5 f))
            (cond
             [(equal? old new)
              (void)]
             [upload?
              (log-info (format "Upload: ~a to: ~a as: ~a" f key (path->content-type f)))
              (unless dry-run?
                (define s
                  ((if ((file-size f) . > . MULTIPART-THRESHOLD)
                       multipart-put-file-via-bytes
                       put-file-via-bytes)
                   (b+p f)
                   f
                   (path->content-type f)
                   upload-props))
                (when s
                  (failure "put" f s)))]
             [old
              (download key f)])
            key))))

  (when download?
    (for ([key (in-hash-keys remote-content)])
      (unless (regexp-match? #rx"/$" key)
        (unless (set-member? local-content key)
          (download key (key->f key))))))

  (when (and delete? upload?)
    (for ([key (in-hash-keys remote-content)])
      (unless (set-member? local-content key)
        (log-info (format "Removing remote: ~a" key))
        (unless dry-run?
          (define s
            (delete (~a bucket "/" (encode-path key))))
          (unless (member (extract-http-code s) '(200 204))
            (failure "delete" key s))))))
  
  (when (and delete? download?)
    (for ([key (in-set local-content)])
      (unless (hash-ref remote-content key #f)
        (define f (key->f key))
        (log-info (format "Removing local: ~a" f))
        (unless dry-run?
          (delete-file (build-path src-dir f))))))

  (when (and upload? (eq? link-mode 'redirect))
    (define abs-src-dir (path->complete-path src-dir))
    (define link-content
      (parameterize ([current-directory src-dir])
        (for/list ([f (in-directory #f (lambda (dir)
                                         (not (link-exists? dir))))]
                   #:when (and (included? f)
                               (link-exists? f)))
          (define raw-dest (resolve-path f))
          (define dest (path->complete-path 
                        raw-dest
                        (let-values ([(base name dir?) (split-path f)])
                          (build-path abs-src-dir base))))
          (define rel-dest (find-relative-path (simplify-path abs-src-dir #f)
                                               (simplify-path dest #f)))
          (unless (and (relative-path? rel-dest)
                       (not (memq 'up (explode-path rel-dest))))
            (error 's3-sync
                   (~a "link does not stay within directory\n"
                       "  source path: ~a\n"
                       "  destination path: ~a")
                   f
                   raw-dest))
          (cons (path->string (if sub (build-path sub f) f))
                (path->string (if sub (build-path sub rel-dest) rel-dest))))))
    (unless (null? link-content)
      (add-links bucket link-content log-info error))))

(define (put-file-via-bytes dest fn mime-type heads)
  (define s (put/bytes dest (file->bytes fn) mime-type heads))
  (if (member (extract-http-code s) '(200))
      #f ; => ok
      s))
  
(define (multipart-put-file-via-bytes dest fn mime-type heads)
  (define s
    (multipart-put dest
		   (ceiling (/ (file-size fn) CHUNK-SIZE))
		   (lambda (n)
		     (call-with-input-file fn
		       (lambda (i)
			 (file-position i (* n CHUNK-SIZE))
			 (read-bytes CHUNK-SIZE i))))
		   mime-type
		   heads))
  ;; How do we check s?
  #f)
  

;; add-links : string (listof (cons/c src dest))
(define (add-links bucket links log-info error)
  (define bstr (get/bytes (~a bucket "/?website")))

  (define config-doc
    (read-xml (open-input-bytes bstr)))
  (define config (document-element config-doc))
  (unless (eq? (element-name config) 'WebsiteConfiguration)
    (error 's3-sync "not a WebsiteConfiguration"))

  (define (find-sub name e)
    (for/or ([c (element-content e)])
      (and (element? c)
           (eq? name (element-name c))
           c)))
  
  (define (replace e name sub-e)
    (struct-copy element e
                 [content 
                  (if (find-sub name e)
                      (for/list ([c (in-list (element-content e))])
                        (if (and (element? c)
                                 (eq? (element-name c) name))
                            sub-e
                            c))
                      (append (element-content e)
                              (list sub-e)))]))

  (define (content-string e)
    (cond
     [(pcdata? e) (pcdata-string e)]
     [(element? e) (apply string-append
                          (map content-string (element-content e)))]
     [else ""]))
  
  (define (elem name . content)
    (make-element #f #f name null content))
  
  (define routing
    (or (find-sub 'RoutingRules config)
        (make-element #f #f 'RoutingRules null null)))
  
  (define (add-rule routing prefix replacement)
    (struct-copy element routing
                 [content
                  (append
                   (for/list ([r (in-list (element-content routing))]
                              #:unless (and (element? r)
                                            (eq? 'RoutingRule (element-name r))
                                            (let ([c (find-sub 'Condition r)])
                                              (or (not c)
                                                  (let ([p (find-sub 'KeyPrefixEquals c)])
                                                    (or (not p)
                                                        (equal? (content-string p) prefix)))))))
                     r)
                   (list
                    (elem 'RoutingRule
                          (elem 'Condition 
                                (elem 'KeyPrefixEquals
                                      (pcdata #f #f prefix)))
                          (elem 'Redirect
                                (elem 'ReplaceKeyPrefixWith
                                      (pcdata #f #f replacement))))))]))
  
  (define o (open-output-bytes))
  (write-xml
   (struct-copy document config-doc
                [element (replace config 'RoutingRules 
                                  (for/fold ([routing routing]) ([link (in-list links)])
                                    (add-rule routing (car link) (cdr link))))])
   o)

  (log-info "Updating redirection rules")

  (define resp
    (put/bytes (~a bucket "/?website") (get-output-bytes o) "application/octet-stream"))
  (unless (member (extract-http-code resp) '(200))
    (error 's3-sync "redirection-rules update failed")))

(module+ main
  (define s3-hostname "s3.amazonaws.com")

  (define dry-run? #f)
  (define delete? #f)
  (define link-mode 'error)
  (define include-rx #f)
  (define exclude-rx #f)
  (define s3-acl #f)
  (define reduced-redundancy? #f)

  (define (check-regexp rx)
    (with-handlers ([exn:fail? (lambda (exn)
                                 (raise-user-error 's3-sync
                                                   (~a "ill-formed regular expression\n"
                                                       "  given: ~a\n"
                                                       "  decoding error: ~s")
                                                   rx
                                                   (exn-message exn)))])
      (pregexp rx)))

  (define-values (src dest)
    (command-line
     #:once-each
     [("--dry-run") "Show changes without making them"
      (set! dry-run? #t)]
     [("--delete") "Remove files in destination with no source"
      (set! delete? #t)]
     [("--acl") acl "Access control list for upload"
      (set! s3-acl acl)]
     [("--reduced") "Upload with reduced redundancy"
      (set! reduced-redundancy? #t)]
     [("--include") rx "Include matching remote paths"
      (set! include-rx (check-regexp rx))]
     [("--exclude") rx "Exclude matching remote paths"
      (set! exclude-rx (check-regexp rx))]
     [("--s3-hostname") hostname "Set S3 hostname (instead of `s3.amazon.com`)"
      (set! s3-hostname hostname)]
     #:once-any
     [("--error-links") "Treat soft links as errors (the default)"
      (set! link-mode 'error)]
     [("--redirect-links") "Treat soft links as redirection rules"
      (set! link-mode 'redirect)]
     [("--follow-links") "Follow soft links"
      (set! link-mode 'follow)]
     [("--ignore-links") "Ignore soft links"
      (set! link-mode 'ignore)]
     #:args
     (src dest)
     (values src dest)))

  (define (s3? s) (regexp-match? #rx"^s3://" s))

  (define-values (local-dir s3-url upload?)
    (cond
     [(and (s3? src) (s3? dest))
      (raise-user-error 's3-sync "both source and destination are `s3://...` URLs")]
     [(s3? src) (values dest src #f)]
     [(s3? dest) (values src dest #t)]
     [else
      (raise-user-error 's3-sync "either source or destination must be a `s3://...` URL")]))

  (define-values (s3-bucket s3-sub)
    (with-handlers ([exn:fail? (lambda (exn)
                                 (raise-user-error 's3-sync
                                                   (~a "ill-formed S3 URL\n"
                                                       "  given: ~a\n"
                                                       "  decoding error: ~s")
                                                   s3-url
                                                   (exn-message exn)))])
      (define u (string->url s3-url))
      (unless (url-host u) (error "no host"))
      (values (url-host u)
              (let ([s (regexp-replace* 
                        #rx"/$"
                        (string-join (map path/param-path (url-path u))
                                     "/")
                        "")])
                (if (string=? s "")
                    #f
                    s)))))

  (ensure-have-keys)
  (s3-host s3-hostname)

  (s3-sync local-dir
           s3-bucket
           s3-sub
           #:upload? upload?
           #:acl s3-acl
           #:reduced-redundancy? reduced-redundancy?
           #:error raise-user-error
           #:include include-rx
           #:exclude exclude-rx
           #:log displayln
           #:link-mode link-mode
           #:delete? delete?
           #:dry-run? dry-run?))
