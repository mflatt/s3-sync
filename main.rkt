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
         raco/command-name
         "routing-rule.rkt")

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
   (map uri-unreserved-encode (string-split p "/"))
   "/"))

(define (merge-hash orig additional)
  ;; `additional` overrides `orig`
  (for/fold ([orig orig]) ([(k v) (in-hash additional)])
    (hash-set orig k v)))

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
                 #:shallow? [shallow? (and upload? (not delete?))]
                 #:check-metadata? [check-metadata? #f]
                 #:jobs [jobs 1]
                 #:include [include-rx #f]
                 #:exclude [exclude-rx #f]
                 #:make-call-with-input-file [make-call-with-file-stream #f]
                 #:get-content-type [get-content-type #f]
                 #:get-content-encoding [get-content-encoding #f]
                 #:acl [acl #f]
                 #:upload-metadata [upload-metadata (hash)]
                 #:upload-metadata-mapping [upload-metadata-mapping (hash)]
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
        (let* ([ht (hash)]
               [ht (if reduced-redundancy?
                       (hash-set ht 'x-amz-storage-class "REDUCED_REDUNDANCY")
                       ht)]
               [ht (if acl
                       (hash-set ht 'x-amz-acl acl) ; "public-read"
                       ht)])
          (merge-hash ht upload-metadata)))

      (define (ensure-not-path s)
        (when (path? s) (error 's3-sync "internal error: should be a string: ~s" s)))

      (define (included? s)
        (ensure-not-path s)
        (and (or (not include-rx)
                 (regexp-match? include-rx s))
             (or (not exclude-rx)
                 (not (regexp-match? exclude-rx s)))))

      (define (in-sub f [sub sub])
        (ensure-not-path sub)
        (define fs (if (path? f)
                       (path-element->string f)
                       f))
        (if sub
            (string-append sub "/" fs)
            fs))

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
      (define (get-task-id [even-for-dry-run? #f])
        (cond
         [(or (and dry-run?
                   (not even-for-dry-run?))
              (= 1 jobs))
          #f]
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
             (get/file (b+k (encode-path key))
                       f
                       #:exists 'truncate/replace)))))

      ;; Accumulates upload items that need metadat checking:
      (define check-metadata null)      
      ;; Acculuates headers and ACL info for `check-metadata?`:
      (define header-store (make-hash))

      (define (download-headers key f acl?)
        (define task-id (get-task-id #t))
        (log-info (format "Download metadata: ~a~a" (format-to key f) (task-id-str task-id)))
        (task!
         task-id
         (lambda ()
           (define p (b+k (encode-path key)))
           (define h (head p))
           (define acl (and acl? (get-acl p)))
           (hash-set! header-store key (list h acl)))))
      
      (define (extract-canned-acl acl bucket-acl props)
        (define (get-owner acl)
          (define acll
            (and acl
                 (assq 'AccessControlList (cdr acl))))
          (let* ([a (and acll (assq 'Owner (cddr acll)))]
                 [a (and a (assq 'ID (cddr a)))])
            (and a (caddr a))))
        (define (get-user key who)
          (define acll
            (and acl
                 (assq 'AccessControlList (cddr acl))))
          (and acll
               (sort
                (for/list ([i (cddr acll)]
                           #:when
                           (and (eq? 'Grant (car i))
                                (let ([a (assq 'Grantee (cddr i))])
                                  (and a
                                       (let ([a (assq key (cddr a))])
                                         (and a (equal? (caddr a) who)))))))
                  (let ([a (assq 'Permission (cddr i))])
                    (caddr a)))
                string<?)))
        (define owner-id (get-owner acl))
        (define bucket-owner-id (get-owner bucket-acl))
        (define all-users (get-user 'URI "http://acs.amazonaws.com/groups/global/AllUsers"))
        (define authenticated-users (get-user 'URI "http://acs.amazonaws.com/groups/global/AuthenticatedUsers"))
        (define ec2-users (get-user 'DisplayName "za-team"))
        (define bucket-owner (get-user 'ID bucket-owner-id))
        (cond
         [(equal? all-users '("READ")) (hash-set props 'x-amz-acl "public-read")]
         [(equal? all-users '("READ" "WRITE")) (hash-set props 'x-amz-acl "public-read-write")]
         [(equal? ec2-users '("READ")) (hash-set props 'x-amz-acl "aws-exec-read")]
         [(equal? authenticated-users '("READ")) (hash-set props 'x-amz-acl "authenticated-read")]
         [(and (not (equal? owner-id bucket-owner-id))
               (equal? bucket-owner '("READ")))
          (hash-set props 'x-amz-acl "bucket-owner-read")]
         [(and (not (equal? owner-id bucket-owner-id))
               (equal? bucket-owner '("FULL_CONTROL")))
          (hash-set props 'x-amz-acl "bucket-owner-full-control")]
         [else props]))

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

      (define (slashify f)
        (string-join (map path-element->string (explode-path f))
                      "/"))
      
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
        (apply build-path (map string->path-element (string-split p "/"))))

      (define (maybe-upload f key in-link)
        (define old (hash-ref remote-content key #f))
        (define call-with-file-stream (if in-link
                                          (lambda (f p) (p (open-input-bytes #"")))
                                          (and make-call-with-file-stream
                                               (make-call-with-file-stream key f))))
        (define new (file-md5 f (or call-with-file-stream call-with-input-file*)))
        (cond
         [(and (equal? old new)
               (not (and upload? check-metadata?)))
          (void)]
         [upload?
          (define do-upload-props-specific
            (if (hash? upload-metadata-mapping)
                (hash-ref upload-metadata-mapping key #hash())
                (upload-metadata-mapping key)))
          (define content-type (and (not in-link)
                                    (or (hash-ref do-upload-props-specific 'Content-Type #f)
                                        (hash-ref upload-props 'Content-Type #f)
                                        (and get-content-type
                                             (get-content-type key f))
                                        (path->content-type key))))
          (define content-encoding (and (not in-link)
                                        get-content-encoding
                                        (get-content-encoding key f)))
          (define do-upload-props-shared
            (cond
             [(and content-encoding
                   (not (hash-ref upload-props 'Content-Encoding #f)))
              (hash-set upload-props 'Content-Encoding content-encoding)]
             [else upload-props]))
          (define do-upload-props
            (merge-hash do-upload-props-shared do-upload-props-specific))
          (cond
           [(and check-metadata?
                 (equal? old new))
            (set! check-metadata (cons (list key f (if in-link
                                                       do-upload-props
                                                       (hash-set do-upload-props
                                                                 'Content-Type
                                                                 content-type)))
                                       check-metadata))
            (download-headers key f (hash-ref do-upload-props 'x-amz-acl #f))]
           [else
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
                    (b+k (encode-path key))
                    f
                    call-with-file-stream
                    (or content-type "application/octet-stream")
                    (cond
                     [in-link
                      (define rel-path
                        (string-append
                         "/"
                         (encode-path (in-sub (slashify in-link)))))
                      (hash-set do-upload-props 'x-amz-website-redirect-location rel-path)]
                     [else
                      do-upload-props])))
                 (when s
                   (failure "put" f s)))))])]
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
                             (in-sub (slashify src-file)))])
                (maybe-upload fn key #f)
                (set key))
              (set))]
         [(and download?
               (not (directory-exists? src-dir))
               (not (link-exists? src-dir)))
          (set)]
         [else
          (parameterize ([current-directory src-dir])
            (let loop ([f #f] [f-key #f] [in-link #f] [result (set)])
              (cond
               [(not f)
                (for/fold ([result result]) ([s (filter use-src-dir? (directory-list))])
                  (loop s (path-element->string s) #f result))]
               [(not (and (or (included? (in-sub f-key))
                              (directory-exists? f))
                          (case link-mode
                            [(follow redirects) #t]
                            [(redirect ignore) (not (link-exists? f))]
                            [(error) (check-link-exists f)])))
                result]
               [(and (not in-link)
                     (eq? link-mode 'redirects)
                     (link-exists? f))
                (loop f f-key (link->dest f) result)]
               [(directory-exists? f)
                (for/fold ([result result]) ([s (filter use-src-dir? (directory-list f))])
                  (loop (build-path f s)
                        (in-sub s f-key)
                        (and in-link (build-path in-link s))
                        result))]
               [(file-exists? f)
                (define key (in-sub f-key))
                (maybe-upload f key in-link)
                (set-add result key)]
               [else
                (error 's3-sync "path error or broken link\n  path: ~e" f)])))]))

      (sync-tasks)
      
      (when (and upload?
                 check-metadata?)
        (define bucket-acl (get-acl (~a bucket "/")))
        (for ([e (in-list check-metadata)])
          (define-values (key f upload-props) (apply values e))
          (define current (hash-ref header-store key
                                    (lambda ()
                                      (error 's3-sync
                                             "cannot find header info\n  path: ~e"
                                             key))))
          (define-values (h-str acl) (apply values current))
          (define current-props (extract-canned-acl
                                 acl
                                 bucket-acl
                                 (if h-str
                                     (heads-string->dict h-str)
                                     #hasheq())))

          (define upload-acl (hash-ref upload-props 'x-amz-acl #f))
          (define same-acl?
            (or (not upload-acl)
                (equal? upload-acl
                        (hash-ref current-props 'x-amz-acl "private"))))

          (define same-other-props?
            (for/and ([(k v) (in-hash upload-props)]
                      #:unless (eq? k 'x-amz-acl))
              (equal? v (hash-ref current-props k
                                  (case k
                                    [(x-amz-storage-class) "STANDARD"]
                                    [(x-amz-acl) "private"]
                                    [else #f])))))
          
          (unless (and same-acl? same-other-props?)
            (define task-id (get-task-id))
            (log-info (format "Upload metadata: ~a~a" (format-to key f) (task-id-str task-id)))
            (unless dry-run?
              (task!
               task-id
               (lambda ()
                 ;; If only the ACL changes, we need to use `put-acl`,
                 ;; otherwise we can use `copy`:
                 (cond
                  [same-other-props?
                   (put-acl (b+k (encode-path key)) #f (hash 'x-amz-acl upload-acl))]
                  [else
                   (copy (b+k key)
                         (b+k (encode-path key))
                         (hash-set upload-props
                                   'x-amz-metadata-directive "REPLACE"))]))))))
        (sync-tasks))

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
              (redirect-prefix-routing-rule
               #:old-prefix (in-sub f)
               #:new-prefix (in-sub (slashify rel-dest))))))
        (unless (null? link-content)
          (add-routing-rules bucket link-content #:log-info log-info #:error error))))))

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

;; ----------------------------------------

(module+ main
  (require "web-config.rkt"
           "gzip.rkt")

  (define s3-hostname "s3.amazonaws.com")
  (define use-region #f)

  (define dry-run? #f)
  (define jobs 1)
  (define shallow? #f)
  (define delete? #f)
  (define check-metadata? #f)
  (define link-mode 'error)
  (define include-rx #f)
  (define exclude-rx #f)
  (define gzip-rx #f)
  (define gzip-size -1)
  (define s3-acl #f)
  (define upload-metadata (hash))
  (define upload-metadata-mapping (hash))
  (define reduced-redundancy? #f)

  (define upload-metadata-mapping-proc
    (lambda (key)
      (hash-ref upload-metadata-mapping key #hash())))

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
     [("--check-metadata") "Check existing metadata for upload"
      (set! check-metadata? #t)]
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
     [("++upload-metadata-mapping") file "Merge item-specific metadata from <file>"
      (define ht (call-with-input-file* file read))
      (unless (and (hash? ht)
                   (for/and ([(k v) (in-hash ht)])
                     (and (string? k)
                          (hash? v)
                          (for/and ([(k v) (in-hash v)])
                            (and (symbol? k)
                                 (string? v))))))
        (raise-user-error 's3-sync
                          (~a "content of file is not a metadata mapping;\n"
                              " a metadata mapping must be a hash table of strings\n"
                              " to hash tables that map symbols to strings\n"
                              "  file: ~a" file)))
      (set! upload-metadata-mapping
            (for/fold ([ht upload-metadata-mapping]) ([(k n-ht) (in-hash ht)])
              (hash-set ht k
                        (for/fold ([o-ht (hash-ref ht k (hash))]) ([(k v) (in-hash n-ht)])
                          (hash-set n-ht k v)))))]
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
            (merge-hash web-upload-metadata upload-metadata))
      (set! upload-metadata-mapping-proc
            (let ([proc upload-metadata-mapping-proc])
              (lambda (key)
                (merge-hash (proc key)
                            (web-upload-metadata-mapping key)))))]
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

  (with-handlers ([exn:fail? (lambda _ (ensure-have-keys))])
    (credentials-from-environment!))

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
           #:shallow? (or shallow? (and upload? (not delete?)))
           #:upload? upload?
           #:check-metadata? check-metadata?
           #:acl s3-acl
           #:upload-metadata upload-metadata
           #:upload-metadata-mapping upload-metadata-mapping-proc
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
