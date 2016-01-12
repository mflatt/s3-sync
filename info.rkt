#lang info

(define collection "s3-sync")

(define deps '(("aws" #:version "1.8")
               ("http" #:version "0.2")
               ("base" #:version "6.0.0.4")))

(define build-deps '("scribble-lib"
                     "racket-doc"
                     "rackunit-lib"))

(define scribblings '(("s3-sync.scrbl" () (tool))))

(define version "1.5")

(define raco-commands
  (list (list "s3-sync"
              '(submod s3-sync main)
              "sychronize an S3 bucket and filesystem directory"
              #f)))
