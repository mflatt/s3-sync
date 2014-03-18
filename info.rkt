#lang info

(define collection "s3-sync")

(define deps '("aws"
               "http"
               ("base" #:version "6.0.0.4")))

(define build-deps '("scribble-lib"
                     "racket-doc"
                     "rackunit-lib"))

(define scribblings '(("s3-sync.scrbl" () (tool))))
