#lang racket
(require s3-sync
         s3-sync/gzip
         s3-sync/web
         aws/keys
         aws/s3
         net/head
         net/uri-codec
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
  (printf "skipping s3-sync tests; could not find `test/bucket' entry in: ~a\n" data-file))

(when bucket
  (define bucket/ (~a bucket "/"))
  (define dir (make-temporary-file "s3-sync-~a" 'directory))

  (define (create-file f content)
    (call-with-output-file*
     #:exists 'truncate
     (build-path dir f)
     (lambda (o) (display content o))))

  (define (create-link dest f)
    (make-file-or-directory-link dest (build-path dir f)))

  (define (create-dir f)
    (make-directory* (build-path dir f)))

  (define (remove-file f)
    (delete-file (build-path dir f)))

  (define (remove-all f)
    (delete-directory/files (build-path dir f)))

  (define (file-content f)
    (file->string (build-path dir f)))

  (define (file-list)
    (sort (parameterize ([current-directory dir])
            (for/list ([f (in-directory)]
                       #:when (file-exists? f))
              (string-join (map path-element->string (explode-path f)) "/")))
          string<?))

  (define (get-link p)
    (define h (head (~a bucket/ p)))
    (extract-field "x-amz-website-redirect-location" h))

  (define (encode-path p)
    (string-join
     (map uri-unreserved-encode (regexp-split #rx"/" p))
     "/"))

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
    (create-file "z@test.css" "No one tries")

    (define plan-count 0)
    (define (count-planned s)
      (when (regexp-match? #rx"(?:Down|Up)load.*:.*[a-z][_@]test(:?[.]css)?" s)
        (log-error ">> ~a" s)
        (set! plan-count (add1 plan-count))))

    (step "Dry run of upload")
    (s3-sync dir bucket #f #:dry-run? #t #:log count-planned #:jobs jobs)
    (check-equal? plan-count 3)
    (check-equal? (ls bucket/) '())

    (step "Upload three files")
    (s3-sync dir bucket #f #:jobs jobs)
    (check-equal? (ls bucket/) '("x_test" "y_test" "z@test.css"))

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
    (s3-sync dir bucket #f #:log count-planned #:jobs jobs
             #:upload-metadata (hash 'Cache-Control "max-age=0, no-cache"))
    (check-equal? plan-count 2)
    
    (check-regexp-match #rx"Cache-Control: max-age=0" (head (~a bucket/ "x_test")))
    (check-false (regexp-match? #rx"Cache-Control: max-age=0" (head (~a bucket/ (encode-path "z@test.css")))))

    (step "Update metadata")
    (set! plan-count 0)
    (s3-sync dir bucket #f #:log count-planned #:jobs jobs
             #:upload-metadata (hash 'x-amz-meta-zub "7"))
    (check-equal? plan-count 0)
    (s3-sync dir bucket #f #:log count-planned #:jobs jobs
             #:check-metadata? #t
             #:upload-metadata (hash 'x-amz-meta-zub "7"))
    (check-equal? plan-count 6) ; checks plus uploads
    (set! plan-count 0)
    (s3-sync dir bucket #f #:log count-planned #:jobs jobs
             #:check-metadata? #t
             #:upload-metadata (hash 'x-amz-meta-zub "7"))
    (check-equal? plan-count 3) ; just checks

    (check-regexp-match #rx"x-amz-meta-zub: 7" (head (~a bucket/ "x_test")))
    (check-regexp-match #rx"x-amz-meta-zub: 7" (head (~a bucket/ (encode-path "z@test.css"))))
    (check-regexp-match #rx"Content-Type: text/css" (head (~a bucket/ (encode-path "z@test.css"))))

    (step "Merge metadata")
    (set! plan-count 0)
    (s3-sync dir bucket #f #:log count-planned #:jobs jobs
             #:check-metadata? #t
             #:upload-metadata (hash 'x-amz-meta-zub "7")
             #:upload-metadata-mapping (hash "y_test" (hash 'x-amz-meta-zub "8")
                                             "z@test.css" (hash 'x-amz-meta-biq "9")))
    (check-equal? plan-count 5) ; checks plus 2 uploads

    (check-regexp-match #rx"x-amz-meta-zub: 7" (head (~a bucket/ "x_test")))
    (check-regexp-match #rx"x-amz-meta-zub: 8" (head (~a bucket/ "y_test")))
    (check-regexp-match #rx"x-amz-meta-zub: 7" (head (~a bucket/ (encode-path "z@test.css"))))
    (check-regexp-match #rx"x-amz-meta-biq: 9" (head (~a bucket/ (encode-path "z@test.css"))))
    (check-false (regexp-match? #rx"x-maz-meta-biq" (head (~a bucket/ "x_test"))))
    (check-false (regexp-match? #rx"x-maz-meta-biq" (head (~a bucket/ "y_test"))))

    (step "Download and rename individual file")
    (set! plan-count 0)
    (s3-sync (build-path dir "like_x_test") bucket "x_test"
             #:upload? #f #:log count-planned #:jobs jobs)
    (check-equal? plan-count 1)
    (check-equal? (file-content "x_test") (file-content "like_x_test"))
    (remove-file "like_x_test")
    
    (step "Upload and rename individual file")
    (set! plan-count 0)
    (s3-sync (build-path dir "y_test") bucket "like_y_test"
             #:log count-planned #:jobs jobs)
    (check-equal? plan-count 1)
    (check-equal? (ls bucket/) '("like_y_test" "x_test" "y_test" "z@test.css"))

    (step "Download individual file to directory")
    (set! plan-count 0)
    (s3-sync dir bucket "like_y_test"
             #:upload? #f #:log count-planned #:jobs jobs)
    (check-equal? plan-count 1)
    (check-equal? (file-content "y_test") (file-content "like_y_test"))

    (step "Download removed files")
    (remove-file "x_test")
    (remove-file "z@test.css")
    (set! plan-count 0)
    (s3-sync dir bucket #f #:upload? #f #:log count-planned #:jobs jobs)
    (check-equal? plan-count 2)
    (check-equal? (file-content "x_test") "No one pulls you")
    (check-equal? (file-content "y_test") "Out from your hole")
    (check-equal? (file-content "z@test.css") "No one tries")
    (check-equal? (file-content "like_y_test") (file-content "y_test"))

    (unless (eq? (system-type) 'windows)
      (step "Error on links")
      (create-link "z@test.css" "also_z_test")
      (check-equal? 'as-expected
                    (with-handlers ([exn:fail? (lambda (exn)
                                                 (if (regexp-match? #rx"encountered soft link"
                                                                    (exn-message exn))
                                                     'as-expected
                                                     exn))])
                      (s3-sync dir bucket #f #:jobs jobs)))
      
      (step "Follow link")
      (s3-sync dir bucket #f #:jobs jobs #:link-mode 'follow)
      (check-equal? (ls bucket/) '("also_z_test" "like_y_test" "x_test" "y_test" "z@test.css"))
      (remove-file "also_z_test")
      (set! plan-count 0)
      (s3-sync dir bucket #f #:upload? #f #:log count-planned #:jobs jobs)
      (check-equal? plan-count 1)
      (check-equal? (file-content "also_z_test") (file-content "z@test.css"))

      (step "Redirect link")
      (remove-file "also_z_test")
      (create-link "z@test.css" "also_z_test")
      (s3-sync dir bucket #f #:jobs jobs #:link-mode 'redirects)
      (check-equal? (get-link "also_z_test") (encode-path "/z@test.css"))
      (remove-file "also_z_test")
      (set! plan-count 0)
      (s3-sync dir bucket #f #:upload? #f #:log count-planned #:jobs jobs)
      (check-equal? plan-count 1)
      (check-equal? (file-content "also_z_test") "")
      (remove-file "also_z_test")
      (remove-file "like_y_test")

      (s3-sync dir bucket #f #:jobs jobs #:delete? #t)
      (check-equal? (ls bucket/) '("x_test" "y_test" "z@test.css"))

      (step "Redirect directory link")
      (create-dir "sub")
      (create-link "../z@test.css" "sub/also_z_test")
      (s3-sync dir bucket #f #:jobs jobs #:link-mode 'redirects)
      (check-equal? (get-link "sub/also_z_test") (encode-path "/z@test.css"))
      (remove-all "sub")
      
      (s3-sync dir bucket #f #:jobs jobs #:delete? #t)
      (check-equal? (ls bucket/) '("x_test" "y_test" "z@test.css")))

    (step "Upload to specified prefix")
    (make-directory (build-path dir "sub"))
    (create-file "sub/a_test" "Some people tell me")
    (create-file "sub/b_test" "Home is in the sky")
    (set! plan-count 0)
    (s3-sync (build-path dir "sub") bucket "nested" #:log count-planned #:jobs jobs)
    (check-equal? plan-count 2)
    (check-equal? (ls bucket/) '("nested/a_test" "nested/b_test"
                                 "x_test" "y_test" "z@test.css"))

    (step "Upload file to specified prefix")
    (set! plan-count 0)
    (s3-sync (build-path dir "x_test") bucket "nested" #:log count-planned #:jobs jobs)
    (check-equal? plan-count 1)
    (check-equal? (ls bucket/) '("nested/a_test" "nested/b_test" "nested/x_test"
                                 "x_test" "y_test" "z@test.css"))

    (step "Cannot upload directory to file name")
    (check-exn (lambda (exn)
                 (and (exn:fail? exn)
                      (regexp-match #rx"mismatch between remote and local"
                                    (exn-message exn))))
               (lambda ()
                 (s3-sync dir bucket "x_test" #:jobs jobs)))
    (check-exn (lambda (exn)
                 (and (exn:fail? exn)
                      (regexp-match #rx"local path not found"
                                    (exn-message exn))))
               (lambda ()
                 (s3-sync (path->directory-path (build-path dir "x_test"))
                          bucket "x_test" #:jobs jobs)))

    (step "Cannot download directory to file name")
    (check-exn (lambda (exn)
                 (and (exn:fail? exn)
                      (regexp-match #rx"mismatch between remote and local"
                                    (exn-message exn))))
               (lambda ()
                 (s3-sync (build-path dir "x_test") bucket "nested" #:upload? #f #:jobs jobs)))
    (check-exn (lambda (exn)
                 (and (exn:fail? exn)
                      (regexp-match #rx"was a directory, found a file"
                                    (exn-message exn))))
               (lambda ()
                 (s3-sync (build-path dir "x_test") bucket "x_test/" #:upload? #f #:jobs jobs)))
    
    (step "Download from newly nested path")
    (set! plan-count 0)
    (s3-sync dir bucket "nested" #:upload? #f #:log count-planned #:jobs jobs)
    (check-equal? plan-count 2)
    (check-equal? (file-list)
                  '("a_test" "b_test"
                    "sub/a_test" "sub/b_test"
                    "x_test" "y_test" "z@test.css"))
    (remove-file "a_test")
    (remove-file "b_test")

    (step "Download, not getting newly nested path")
    (set! plan-count 0)
    (s3-sync dir bucket #f #:shallow? #t #:upload? #f #:log count-planned #:jobs jobs)
    (check-equal? plan-count 0)
    (check-equal? (file-list)
                  '("sub/a_test" "sub/b_test"
                    "x_test" "y_test" "z@test.css"))

    (step "Download to get newly nested path")
    (s3-sync dir bucket #f #:upload? #f #:log count-planned #:jobs jobs)
    (check-equal? plan-count 3)
    (check-equal? (file-list)
                  '("nested/a_test" "nested/b_test" "nested/x_test"
                    "sub/a_test" "sub/b_test"
                    "x_test" "y_test" "z@test.css"))

    (step "Try that again")
    (remove-file "nested/a_test")
    (remove-file "nested/b_test")
    (check-equal? (file-list)
                  '("nested/x_test"
                    "sub/a_test" "sub/b_test"
                    "x_test" "y_test" "z@test.css"))
    ;; "nested" directory still exists...
    (set! plan-count 0)
    (s3-sync dir bucket #f #:shallow? #t #:upload? #f #:log count-planned #:jobs jobs)
    (check-equal? plan-count 2)
    (check-equal? (file-list)
                  '("nested/a_test" "nested/b_test" "nested/x_test"
                    "sub/a_test" "sub/b_test"
                    "x_test" "y_test" "z@test.css"))

    (step "Upload to add subpath")
    (check-equal? (ls bucket/)
                  '("nested/a_test" "nested/b_test" "nested/x_test"
                    "x_test" "y_test" "z@test.css"))
    (set! plan-count 0)
    (s3-sync dir bucket #f #:shallow? #t #:log count-planned #:jobs jobs)
    (check-equal? plan-count 2)
    (check-equal? (ls bucket/)
                  '("nested/a_test" "nested/b_test" "nested/x_test"
                    "sub/a_test" "sub/b_test"
                    "x_test" "y_test" "z@test.css"))

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
      (delete-directory/files f))

    (step "Upload file with same name as \"directory\"")
    (create-file "nested" "All action")
    (s3-sync dir bucket #f #:upload? #t #:jobs jobs)
    (check-equal? (ls bucket/)
                  '("nested"
                    "nested/a_test" "nested/b_test" "nested/x_test" 
                    "sub/a_test" "sub/b_test"
                    "x_test" "y_test" "z@test.css"))
    (check-exn (lambda (exn)
                 (and (exn:fail? exn)
                      (regexp-match #rx"both a file and a directory"
                                    (exn-message exn))))
               (lambda ()
                 (s3-sync dir bucket #f #:upload? #f #:jobs jobs)))
    (check-equal? (file-list) '("nested"))

    (step "Download only immediate files (so no directory conflict)")
    (create-file "nested" "No talking")
    (s3-sync dir bucket #f #:upload? #f #:exclude #rx"/" #:jobs jobs)
    (check-equal? (file-list) '("nested" "x_test" "y_test" "z@test.css"))
    (check-equal? (file-content "nested") "All action")

    (step "Empty local directory")
    (for ([f (in-list (directory-list dir #:build? #t))])
      (delete-directory/files f)))

  (go 1)
  (go 10)

  (define (web-go)
    (printf "=== Testing web upload ==\n")

    (step "Initialize test bucket to empty")
    (s3-sync dir bucket #f #:delete? #t)
    (check-equal? (ls bucket/) '())

    (create-file "x_test" "Wish I was ocean size")
    (create-file "y_test" "They cannot move you")
    (create-file "z@test.css" "No one tries")

    (step "Dry run of upload")
    (s3-web-sync dir bucket #f #:dry-run? #t)
    (check-equal? (ls bucket/) '())

    (step "Upload three files")
    (s3-web-sync dir bucket #f)
    (check-equal? (ls bucket/) '("x_test" "y_test" "z@test.css"))

    (check-regexp-match #rx"Cache-Control: max-age=0" (head (~a bucket/ "x_test")))
    (check-regexp-match #rx"Cache-Control: max-age=31536000" (head (~a bucket/ (encode-path "z@test.css"))))

    (step "Empty local directory")
    (for ([f (in-list (directory-list dir #:build? #t))])
      (delete-directory/files f)))

  (web-go)

  (step "Clean up local directory")
  (delete-directory/files dir)
  (step "Test bucket is left as-is"))
