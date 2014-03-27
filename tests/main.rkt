#lang racket
(require s3-sync
         s3-sync/gzip
         aws/keys
         aws/s3
         rackunit)

;; To run this test, create "~/.aws-tests-data" and
;; specify a test bucket name with
;;   test/bucket = <bucket-name>

(define data-file (build-path (find-system-path 'home-dir)
                              ".aws-tests-data"))
(define bucket
  (and (file-exists? data-file)
       (call-with-input-file*
        data-file
        (lambda (i)
          (define m (regexp-match #px"(?m:^test/bucket\\s+=\\s+([^\\s]*)\\s*$)" i))
          (and m (bytes->string/utf-8 (cadr m)))))))

(unless bucket
  (error 'test-s3-sync "could not find `test/bucket' entry in: ~a" data-file))

(define bucket/ (~a bucket "/"))
(define dir (make-temporary-file "s3-sync-~a" 'directory))

(define (create-file f content)
  (call-with-output-file*
   #:exists 'truncate
   (build-path dir f)
   (lambda (o) (display content o))))

(define (remove-file f)
  (delete-file (build-path dir f)))

(define (file-content f)
  (file->string (build-path dir f)))

(define (file-list)
  (sort (parameterize ([current-directory dir])
          (for/list ([f (in-directory)]
                     #:when (file-exists? f))
            (string-join (map path-element->string (explode-path f)) "/")))
        string<?))

(ensure-have-keys)
(s3-host "s3.amazonaws.com")

(define step displayln)

(define (go jobs)
  (printf "=== Testing with ~a parallel job~a ==\n"
          jobs
          (if (= jobs 1) "" "s"))

  (step "Initialize test bucket to empty")
  (s3-sync dir bucket #f #:delete? #t #:jobs jobs)
  (check-equal? (ls bucket/) '())

  (create-file "x_test" "Wish I was ocean size")
  (create-file "y_test" "They cannot move you")
  (create-file "z_test" "No one tries")

  (define plan-count 0)
  (define (count-planned s)
    (when (regexp-match? #rx"[a-z]_test" s)
      (set! plan-count (add1 plan-count))))

  (step "Dry run of upload")
  (s3-sync dir bucket #f #:dry-run? #t #:log count-planned #:jobs jobs)
  (check-equal? plan-count 3)
  (check-equal? (ls bucket/) '())

  (step "Upload three files")
  (s3-sync dir bucket #f #:jobs jobs)
  (check-equal? (ls bucket/) '("x_test" "y_test" "z_test"))

  (step "Check upload needs no files")
  (set! plan-count 0)
  (s3-sync dir bucket #f #:log count-planned #:jobs jobs)
  (check-equal? plan-count 0)

  (step "Check download needs no files")
  (s3-sync dir bucket #f #:upload? #f #:delete? #t #:log count-planned #:jobs jobs)
  (check-equal? plan-count 0)

  (step "Upload changed files")
  (create-file "x_test" "No one pulls you")
  (create-file "y_test" "Out from your hole")
  (set! plan-count 0)
  (s3-sync dir bucket #f #:log count-planned #:jobs jobs)
  (check-equal? plan-count 2)

  (step "Download removed files")
  (remove-file "x_test")
  (remove-file "z_test")
  (set! plan-count 0)
  (s3-sync dir bucket #f #:upload? #f #:log count-planned #:jobs jobs)
  (check-equal? plan-count 2)
  (check-equal? (file-content "x_test") "No one pulls you")
  (check-equal? (file-content "y_test") "Out from your hole")
  (check-equal? (file-content "z_test") "No one tries")

  (step "Upload to specified prefix")
  (make-directory (build-path dir "sub"))
  (create-file "sub/a_test" "Some people tell me")
  (create-file "sub/b_test" "Home is in the sky")
  (set! plan-count 0)
  (s3-sync (build-path dir "sub") bucket "nested" #:log count-planned #:jobs jobs)
  (check-equal? plan-count 2)
  (check-equal? (ls bucket/) '("nested/a_test" "nested/b_test" "x_test" "y_test" "z_test"))

  (step "Download from newly nested path")
  (set! plan-count 0)
  (s3-sync dir bucket "nested" #:upload? #f #:log count-planned #:jobs jobs)
  (check-equal? plan-count 2)
  (check-equal? (file-list)
                '("a_test" "b_test" "sub/a_test" "sub/b_test" "x_test" "y_test" "z_test"))
  (remove-file "a_test")
  (remove-file "b_test")

  (step "Download, not getting newly nested path")
  (set! plan-count 0)
  (s3-sync dir bucket #f #:shallow? #t #:upload? #f #:log count-planned #:jobs jobs)
  (check-equal? plan-count 0)
  (check-equal? (file-list)
                '("sub/a_test" "sub/b_test" "x_test" "y_test" "z_test"))

  (step "Download to get newly nested path")
  (s3-sync dir bucket #f #:upload? #f #:log count-planned #:jobs jobs)
  (check-equal? plan-count 2)
  (check-equal? (file-list)
                '("nested/a_test" "nested/b_test" "sub/a_test" "sub/b_test" "x_test" "y_test" "z_test"))

  (step "Try that again")
  (remove-file "nested/a_test")
  (remove-file "nested/b_test")
  (check-equal? (file-list)
                '("sub/a_test" "sub/b_test" "x_test" "y_test" "z_test"))
  ;; "nested" directory still exists...
  (set! plan-count 0)
  (s3-sync dir bucket #f #:shallow? #t #:upload? #f #:log count-planned #:jobs jobs)
  (check-equal? plan-count 2)
  (check-equal? (file-list)
                '("nested/a_test" "nested/b_test" "sub/a_test" "sub/b_test" "x_test" "y_test" "z_test"))

  (step "Upload to add subpath")
  (check-equal? (ls bucket/)
                '("nested/a_test" "nested/b_test" "x_test" "y_test" "z_test"))
  (set! plan-count 0)
  (s3-sync dir bucket #f #:shallow? #t #:log count-planned #:jobs jobs)
  (check-equal? plan-count 2)
  (check-equal? (ls bucket/)
                '("nested/a_test" "nested/b_test" "sub/a_test" "sub/b_test" "x_test" "y_test" "z_test"))

  (step "Nothing new to upload")
  (set! plan-count 0)
  (s3-sync dir bucket #f #:shallow? #t #:log count-planned #:jobs jobs)
  (check-equal? plan-count 0)

  (step "Gzip some files on upload")
  (define-values (gzip-b-in gzip-b-enc) (make-gzip-handlers #rx"b_test"))
  (set! plan-count 0)
  (s3-sync dir bucket #f #:log count-planned
           #:make-call-with-input-file gzip-b-in
           #:get-content-encoding gzip-b-enc
           #:jobs jobs)
  (check-equal? plan-count 2)
  (set! plan-count 0)
  (s3-sync dir bucket #f #:log count-planned
           #:make-call-with-input-file gzip-b-in
           #:get-content-encoding gzip-b-enc
           #:jobs jobs)
  (check-equal? plan-count 0)

  (step "Download gzipped file")
  (remove-file "sub/b_test")
  (set! plan-count 0)
  (s3-sync dir bucket #f #:upload? #f #:log count-planned
           #:make-call-with-input-file gzip-b-in
           #:get-content-encoding gzip-b-enc
           #:jobs jobs)
  (check-equal? plan-count 1)
  (check-equal? (file-content "sub/b_test") "Home is in the sky")

  (step "Empty local directory")
  (for ([f (in-list (directory-list dir #:build? #t))])
    (delete-directory/files f)))

(go 1)
(go 10)

(step "Clean up local directory")
(delete-directory/files dir)
(step "Test bucket is left as-is")
