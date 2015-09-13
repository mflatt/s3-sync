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
         racket/list
         openssl/md5
         net/url
         net/uri-codec
         http/head
         http/request
         xml
         raco/command-name)

(provide s3-sync)

(define-logger s3-sync)

(define (path->content-type p)
  (case (filename-extension p)
    [(#"html") "text/html; charset=utf-8"]
    [(#"txt") "text/plain; charset=utf-8"]
    [(#"png") "image/png"]
    [(#"gif") "image/gif"]
    [(#"svg") "image/svg+xml"]
    [(#"js") "text/javascript"]
    [(#"css") "text/css"]
    [else "application/octet-stream"]))

(define (encode-path p)
  (string-join
   (map uri-encode (string-split p "/"))
   "/"))

(define MULTIPART-THRESHOLD (* 1024 1024 10))
(define CHUNK-SIZE MULTIPART-THRESHOLD)

(define (file-md5 f call-with-file-stream)
  (cond
   [((file-size f) . > . MULTIPART-THRESHOLD)
    (define buffer (make-bytes CHUNK-SIZE))
    (define-values (i o) (make-pipe))
    (define n 
      (call-with-file-stream f
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
    (call-with-file-stream f md5)]))

(define (s3-sync src bucket given-sub
                 #:upload? [upload? #t]
                 #:error [error error]
                 #:dry-run? [dry-run? #f]
                 #:delete? [delete? #f]
                 #:shallow? [shallow? #f]
                 #:jobs [jobs 1]
                 #:include [include-rx #f]
                 #:exclude [exclude-rx #f]
                 #:make-call-with-input-file [make-call-with-file-stream #f]
                 #:get-content-type [get-content-type #f]
                 #:get-content-encoding [get-content-encoding #f]
                 #:acl [acl #f]
                 #:upload-metadata [upload-metadata (hash)]
                 #:reduced-redundancy? [reduced-redundancy? #f]
                 #:link-mode [link-mode 'error]
                 #:log [log-info (lambda (s)
                                   (log-s3-sync-info s))])
  
  (define sub-is-dir? (or (not given-sub)
                          (regexp-match? #rx"/$" given-sub)))
  
  (when upload?
    (unless (or (file-exists? src)
                (directory-exists? src)
                (link-exists? src))
      (error 's3-sync (~a "given local path not found for upload\n"
                          "  path: ~a")
             src)))
  
  (define src-kind
    (let-values ([(base name dir?) (split-path src)])
      (cond
       [dir? 'directory]
       [(directory-exists? src) 'directory]
       [(file-exists? src) 'file]
       [upload?
        (error 's3-sync "no such file or directory to upload\n  path: ~a" src)]
       [else #f])))

  (define task-sema (make-semaphore jobs))
  (define tasks (make-hash))
  (define failures (make-hash))
  
  (define task-id-lock (make-semaphore 1))
  (define task-ids (hash-copy (for/hash ([i (in-range jobs)])
                                (values i #t))))
  
  (define (sync-tasks)
    (for ([t (in-list (hash-keys tasks))])
      (sync t))
    (for ([exn (in-hash-keys failures)])
      ((error-display-handler) (exn-message exn) exn))
    (when (positive? (hash-count failures))
      (error 's3-sync "error in background task")))

  (define (interrupt-tasks)
    (map break-thread (hash-keys tasks))
    (sync-tasks))

  (with-handlers ([exn:break? (lambda (exn)
                                (interrupt-tasks)
                                (raise exn))])
    (parameterize ([current-pool-timeout 10]) ; from http/request (version 0.2)

      (define clean-sub
        ;; Clean up empty `sub' and/or trailing "/"
        (and given-sub
             (if (equal? given-sub "")
                 #f
                 (regexp-replace #rx"/+$" given-sub ""))))

      (log-info (let ([remote (~a bucket
                                  (if clean-sub
                                      (~a "/" (encode-path clean-sub))
                                      ""))]
                      [local src])
                  (format "Syncing: ~a from: ~a"
                          (if upload? remote local)
                          (if upload? local remote))))

      (define download? (not upload?))
      
      (define upload-props
        (let* ([ht upload-metadata]
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

      (define (in-sub f [sub sub])
        ;; relies on item names matching path syntax:
        (path->string (if sub (build-path sub f) f)))

      (define (check-link-exists f)
        (if (link-exists? f)
            (error 's3-sync
                   (~a "encountered soft link\n"
                       "  path: ~a")
                   f)
            #t))

      (define (use-src-dir? dir)
        ;; Don't check inclusions or exclusions here, because
        ;; those are meant to be applied to item names, not partial
        ;; item names.
        (case link-mode
          [(redirect ignore) (not (link-exists? dir))]
          [(error) (check-link-exists dir)]
          [else #t]))

      (define local-directories
        (and shallow?
             (if (eq? src-kind 'directory)
                 (parameterize ([current-directory src])
                   (set-add
                    (for/set ([f (in-directory #f use-src-dir?)]
                              #:when (and (directory-exists? f)
                                          (use-src-dir? f)))
                      (in-sub f clean-sub))
                    #f))
                 (set))))

      (log-info "Getting current S3 content...")
      (define (get-name x)
        (caddr (assq 'Key (cddr x))))
      (define (get-prefix x)
        (caddr (assq 'Prefix (cddr x))))
      (define (get-etag x)
        (cadddr (assq 'ETag (cddr x))))
      (define (make-ls-handler handle-null included? handle-prefix empty-hash)
        (lambda (ht xs)
          (cond
           [(null? xs)
            (handle-null)]
           [else
            (for/fold ([ht (or ht empty-hash)]) ([x (in-list xs)])
              (case (car x)
                [(Contents)
                 (define name (get-name x))
                 (cond
                  [(regexp-match? #rx"/$" name)
                   ;; ignore any element that ends with "/",
                   ;; because we can't represent it on the filesystem
                   ht]
                  [(included? name)
                   (hash-set (or ht (hash)) name (get-etag x))]
                  [else
                   ;; not included
                   ht])]
                [(CommonPrefixes)
                 (define prefix (get-prefix x))
                 (define prefix-no-/
                   (substring prefix 0 (sub1 (string-length prefix))))
                 (handle-prefix prefix-no-/ ht)]))])))
      (define remote-content-as-directory
        (let loop ([sub clean-sub] [ht #f] [initial? #t])
          (if (or (not shallow?)
                  (not (eq? src-kind 'directory))
                  (set-member? local-directories sub))
              (ls/proc (~a bucket "/" (if sub
                                          (~a (encode-path sub) "/")
                                          ""))
                       #:delimiter (and shallow? "/")
                       (make-ls-handler (lambda ()
                                          (if (and initial? sub)
                                              #f
                                              (or ht (hash))))
                                        included?
                                        (lambda (prefix-no-/ ht)
                                          (loop prefix-no-/ ht #f))
                                        (hash))
                       ht)
              ht)))
      (define-values (remote-content remote-kind)
        (cond
         [(not remote-content-as-directory)
          (define remote-content-as-file
            (and clean-sub
                 (ls/proc (~a bucket "/" (encode-path clean-sub))
                          #:delimiter "/"
                          (let ([sub-name (last (string-split clean-sub "/"))])
                            (make-ls-handler (lambda ()
                                               (unless upload?
                                                 (error 's3-sync
                                                        (~a "remote content not found\n"
                                                            "  remote path: ~a")
                                                        clean-sub))
                                               #f)
                                             (lambda (name)
                                               (and (equal? name sub-name)
                                                    (included? name)))
                                             (lambda (prefix-no-/ ht) #f)
                                             #f))
                          #f)))
          (if remote-content-as-file
              (begin
                (when sub-is-dir?
                  (error 's3-sync
                         (~a "given bucket path was a directory, found a file\n"
                             "  path: ~a\n"
                             "  bucket: ~a")
                         given-sub
                         bucket))
                ;; remote names a file:
                (values remote-content-as-file 'file))
              ;; no content or disposition:
              (values (hash) (if sub-is-dir?
                                 'directory
                                 #f)))]
         [else
          (values remote-content-as-directory 'directory)]))
      (log-info "... got it.")
      
      (unless (or (not src-kind)
                  (not remote-kind)
                  (eq? src-kind remote-kind)
                  (and upload? (eq? src-kind 'file))
                  (and (not upload?) (eq? remote-kind 'file)))
        (error 's3-sync
               (~a "mismatch between remote and local types\n"
                   "  remote type: ~a\n"
                   "  local type: ~a\n"
                   "  remote bucket: ~a\n"
                   "  remote path: ~a\n"
                   "  local path: ~a\n")
               remote-kind
               src-kind
               bucket
               (or given-sub "[none]")
               src))
      
      (define-values (src-dir src-file)
        (cond
         [(or (eq? src-kind 'file)
              (and (not src-kind)
                   (eq? remote-kind 'file)))
          (define-values (base name dir?) (split-path src))
          (values (if (path? base) base (current-directory))
                  name)]
         [else
          (values src #f)]))
      
      (define-values (sub sub-file)
        (cond
         [(or (eq? remote-kind 'file)
              (and (not remote-kind)
                   (eq? src-kind 'file)))
          (define l (string-split clean-sub "/"))
          (values (if (= 1 (length l))
                      #f
                      (string-join (drop-right l) "/"))
                  (last l))]
         [else
          (values clean-sub #f)]))

      (unless upload?
        ;; Double-check that the remote content does not imply
        ;; a file and directory with the same name:
        (for ([k (in-hash-keys remote-content)])
          (let loop ([l (cdr (reverse (string-split k "/")))])
            (define p (string-join l "/"))
            (when (hash-ref remote-content p #f)
              (error 's3-sync
                     (~a "remote path corresponds to both a file and a directory\n"
                         "  path: ~a")
                     p)))))

      (define (failure what f s)
        (error 's3-sync (~a "~a failed\n"
                            "  path: ~a\n"
                            "  server response: ~s")
               what
               f
               s))

      (define (format-to key f)
        (define key-s (~a key))
        (define f-s (~a f))
        (if (equal? key-s f-s)
            key-s
            (format "~a to: ~a" key-s f-s)))

      ;; Call `get-task-id` to get permission to run a task
      ;; and an id to report in logging:
      (define (get-task-id)
        (cond
         [(or dry-run? (= 1 jobs)) #f]
         [else
          (semaphore-wait task-sema)
          (when (positive? (hash-count failures))
            (interrupt-tasks))
          (call-with-semaphore
           task-id-lock
           (lambda ()
             (define id (hash-iterate-key task-ids (hash-iterate-first task-ids)))
             (hash-remove! task-ids id)
             id))]))

      (define (task-id-str task-id)
        (if task-id
            (format " [~s]" task-id)
            ""))

      ;; Start a task for which an id has been obtained:
      (define (task! task-id thunk)
        (if (not task-id)
            (thunk)
            (let ([go (make-semaphore)])
              (hash-set! tasks
                         (parameterize-break
                          #f
                          (thread
                           (lambda ()
                             (with-handlers ([exn:break? void])
                               (parameterize-break
                                #t
                                (semaphore-wait go)
                                (with-handlers ([exn:fail? (lambda (exn)
                                                             (hash-set! failures exn #t))])
                                  (thunk))))
                             (call-with-semaphore
                              task-id-lock
                              (lambda ()
                                (hash-set! task-ids task-id #t)))
                             (semaphore-post task-sema)
                             (hash-remove! tasks (current-thread)))))
                         #t)
              (semaphore-post go))))

      (define (download what key f)
        (define task-id (get-task-id))
        (log-info (format "Download ~a: ~a~a" what (format-to key f) (task-id-str task-id)))
        (unless dry-run?
          (let-values ([(base name dir?) (split-path f)])
            (when (path? base)
              (make-directory* base)))
          (task!
           task-id
           (lambda ()
             (get/file (b+k key)
                       f
                       #:exists 'truncate/replace)))))

      (define abs-src-dir (path->complete-path src-dir))
      (define (link->dest f)
        (define raw-dest (resolve-path f))
        (define dest (path->complete-path 
                      raw-dest
                      (let-values ([(base name dir?) (split-path f)])
                        (if (eq? base 'relative)
                            abs-src-dir
                            (build-path abs-src-dir base)))))
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
        rel-dest)

      (define (f->key f)
        (~a (if sub (~a (encode-path sub) "/") "")
            (encode-path (string-join (map path-element->string (explode-path f))
                                      "/"))))
      
      (define (b+k key)
        (~a bucket "/" key))

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
      
      (define (maybe-upload f key in-link)
        (define old (hash-ref remote-content key #f))
        (define call-with-file-stream (if in-link
                                          (lambda (f p) (p (open-input-bytes #"")))
                                          (and make-call-with-file-stream
                                               (make-call-with-file-stream key f))))
        (define new (file-md5 f (or call-with-file-stream call-with-input-file*)))
        (cond
         [(equal? old new)
          (void)]
         [upload?
          (define content-type (and (not in-link)
                                    (or (and get-content-type
                                             (get-content-type key f))
                                        (path->content-type key))))
          (define content-encoding (and (not in-link)
                                        get-content-encoding
                                        (get-content-encoding key f)))
          (define task-id (get-task-id))
          (log-info (format "Upload: ~a as: ~a~a~a"
                            (format-to f key)
                            (if in-link 'redirect content-type)
                            (if content-encoding (format " ~a" content-encoding) "")
                            (task-id-str task-id)))
          (unless dry-run?
            (task!
             task-id
             (lambda ()
               (define s
                 ((if (and (not in-link)
                           ((file-size f) . > . MULTIPART-THRESHOLD))
                      multipart-put-file-via-bytes
                      put-file-via-bytes)
                  (b+k key)
                  f
                  call-with-file-stream
                  (or content-type "application/octet-stream")
                  (cond
                   [in-link
                    (define rel-path
                      (string-append
                       "/"
                       (encode-path (string-join (map path-element->string
                                                      (explode-path
                                                       (if sub
                                                           (build-path sub in-link)
                                                           in-link)))
                                                 "/"))))
                    (hash-set upload-props 'x-amz-website-redirect-location rel-path)]
                   [content-encoding
                    (hash-set upload-props 'Content-Encoding content-encoding)]
                   [else upload-props])))
               (when s
                 (failure "put" f s)))))]
         [old
          (download "changed" key f)]))
      
      (define local-content
        (cond
         [src-file
          ;; If we have both src & remote as files, report remote name
          (define fn (build-path src-dir src-file))
          (if (file-exists? fn)
              (let ([key (or (and sub-file
                                  clean-sub)
                             (f->key src-file))])
                (maybe-upload fn key #f)
                (set key))
              (set))]
         [(and download?
               (not (directory-exists? src-dir))
               (not (link-exists? src-dir)))
          (set)]
         [else
          (parameterize ([current-directory src-dir])
            (let loop ([f #f] [in-link #f] [result (set)])
              (cond
               [(not f)
                (for/fold ([result result]) ([s (filter use-src-dir? (directory-list))])
                  (loop s #f result))]
               [(not (and (or (included? (in-sub f))
                              (directory-exists? f))
                          (case link-mode
                            [(follow redirects) #t]
                            [(redirect ignore) (not (link-exists? f))]
                            [(error) (check-link-exists f)])))
                result]
               [(and (not in-link)
                     (eq? link-mode 'redirects)
                     (link-exists? f))
                (loop f (link->dest f) result)]
               [(directory-exists? f)
                (for/fold ([result result]) ([s (filter use-src-dir? (directory-list f))])
                  (loop (build-path f s)
                        (and in-link (build-path in-link s))
                        result))]
               [(file-exists? f)
                (define key (in-sub f))
                (maybe-upload f key in-link)
                (set-add result key)]
               [else
                (error 's3-sync "path error or broken link\n  path: ~e" f)])))]))

      (sync-tasks)

      (when download?
        ;; Get list of needed files, then sort, then download:
        (define needed
          (for/list ([key (in-hash-keys remote-content)]
                     #:unless (set-member? local-content key))
            key))
        (unless (null? needed)
          (let ([needed (sort needed string<?)])
            (make-directory* src-dir)
            (parameterize ([current-directory src-dir])
              (for ([key (in-list needed)])
                (download "new" key (or src-file
                                        (key->f key)))))
            (sync-tasks))))

      (when (and delete? upload?)
        (define discards
          (for/list ([key (in-hash-keys remote-content)]
                     #:unless (set-member? local-content key))
            key))
        (let loop ([discards (sort discards string<?)]
                   [len (length discards)])
          (unless (zero? len)
            (define this-len (min 500 len))
            (define keys (take discards this-len))
            (for ([key (in-list keys)])
              (log-info (format "Removing remote: ~a" key)))
            (unless dry-run?
              (define s
                (delete-multiple bucket keys))
              (unless (member (extract-http-code s) '(200 204))
                (failure "delete" (first keys) s)))
            (loop (list-tail discards this-len) (- len this-len)))))
      
      (when (and delete? download?)
        (for ([key (in-set local-content)])
          (unless (hash-ref remote-content key #f)
            (define f (key->f key))
            (log-info (format "Removing local: ~a" f))
            (unless dry-run?
              (delete-file (build-path src-dir f))))))

      (when (and upload? (eq? link-mode 'redirect))
        (define link-content
          (parameterize ([current-directory src-dir])
            (for/list ([f (in-directory #f (lambda (dir)
                                             (not (link-exists? dir))))]
                       #:when (and (included? (in-sub f))
                                   (link-exists? f)))
              (define rel-dest (link->dest f))
              (cons (path->string (if sub (build-path sub f) f))
                    (path->string (if sub (build-path sub rel-dest) rel-dest))))))
        (unless (null? link-content)
          (add-links bucket link-content log-info error))))))

(define (put-file-via-bytes dest fn call-with-file-stream mime-type heads)
  (define s (put/bytes dest 
                       (if call-with-file-stream 
                           (call-with-file-stream fn port->bytes)
                           (file->bytes fn))
                       mime-type
                       heads))
  (if (member (extract-http-code s) '(200))
      #f ; => ok
      s))
  
(define (multipart-put-file-via-bytes dest fn call-with-file-stream mime-type heads)
  (define bytes
    (and call-with-file-stream
         (call-with-file-stream fn port->bytes)))
        
  (define s
    (multipart-put dest
		   (ceiling (/ (if bytes
                                   (bytes-length bytes)
                                   (file-size fn))
                               CHUNK-SIZE))
		   (lambda (n)
                     (if bytes
                         (subbytes bytes (* n CHUNK-SIZE) 
                                   (min (* (add1 n) CHUNK-SIZE)
                                        (bytes-length bytes)))
                         (call-with-input-file fn
                           (lambda (i)
                             (file-position i (* n CHUNK-SIZE))
                             (read-bytes CHUNK-SIZE i)))))
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
  (require "web-config.rkt"
           "gzip.rkt")

  (define s3-hostname "s3.amazonaws.com")
  (define use-region #f)

  (define dry-run? #f)
  (define jobs 1)
  (define shallow? #f)
  (define delete? #f)
  (define link-mode 'error)
  (define include-rx #f)
  (define exclude-rx #f)
  (define gzip-rx #f)
  (define gzip-size -1)
  (define s3-acl #f)
  (define upload-metadata (hash))
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
     #:program (short-program+command-name)
     #:once-each
     [("--dry-run") "Show changes without making them"
      (set! dry-run? #t)]
     [("-j" "--jobs") n "Download/upload up to <n> in parallel"
      (define j (string->number n))
      (unless (exact-positive-integer? j)
        (raise-user-error 's3-sync "bad number: ~a" n))
      (set! jobs j)]
     [("--shallow") "Constrain to existing <src> directories"
      (set! shallow? #t)]
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
     [("--gzip") rx "Gzip matching remote paths"
      (set! gzip-rx (check-regexp rx))]
     [("--gzip-min") bytes "Gzip only files larger than <bytes>"
      (define n (string->number bytes))
      (unless (exact-nonnegative-integer? n)
        (raise-user-error 's3-sync "bad number: ~a" bytes))
      (set! gzip-size n)]
     #:multi
     [("++upload-metadata") name value "Add <name>: <value> to metadata"
      (set! upload-metadata
            (hash-set upload-metadata
                      (string->symbol name)
                      value))]
     #:once-each
     [("--s3-hostname") hostname "Set S3 hostname (instead of `s3.amazon.com`)"
      (set! s3-hostname hostname)]
     [("--region") region "Set S3 region (instead of issuing a query)"
      (set! use-region region)]
     #:once-any
     [("--error-links") "Treat soft links as errors (the default)"
      (set! link-mode 'error)]
     [("--redirect-links") "Treat soft links as a table of redirection rules"
      (set! link-mode 'redirect)]
     [("--redirects-links") "Treat soft links as individual redirections"
      (set! link-mode 'redirects)]
     [("--follow-links") "Follow soft links"
      (set! link-mode 'follow)]
     [("--ignore-links") "Ignore soft links"
      (set! link-mode 'ignore)]
     #:once-each
     [("--web") "Set defaults suitable for web sites"
      (unless s3-acl (set! s3-acl "public-read"))
      (set! reduced-redundancy? #t)
      (unless gzip-rx (set! gzip-rx web-gzip-rx))
      (when (= -1 gzip-size) (set! gzip-size web-gzip-min-size))
      (set! upload-metadata
            (for/fold ([ht upload-metadata]) ([(k v) (in-hash web-upload-metadata)])
              (if (hash-ref ht k #f)
                  ht
                  (hash-set ht k v))))]
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
              (let ([s (string-join (map path/param-path (url-path u))
                                    "/")])
                (if (or (string=? s "")
                        (string=? s "/"))
                    #f
                    s)))))

  (ensure-have-keys)
  (s3-host s3-hostname)

  (s3-region
   (or use-region
       (bucket-location s3-bucket)))

  (define-values (call-with-gzip-file gzip-content-encoding)
    (if gzip-rx
        (make-gzip-handlers gzip-rx #:min-size (max 0 gzip-size))
        (values #f #f)))

  (s3-sync local-dir
           s3-bucket
           s3-sub
           #:shallow? shallow?
           #:upload? upload?
           #:acl s3-acl
           #:upload-metadata upload-metadata
           #:reduced-redundancy? reduced-redundancy?
           #:error raise-user-error
           #:include include-rx
           #:exclude exclude-rx
           #:make-call-with-input-file call-with-gzip-file
           #:get-content-encoding gzip-content-encoding
           #:log displayln
           #:link-mode link-mode
           #:delete? delete?
           #:dry-run? dry-run?
           #:jobs jobs))
