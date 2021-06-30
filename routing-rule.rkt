#lang racket/base
(require aws/s3
         racket/format
         http/head
         http/request
         xml)

(provide add-routing-rules
         redirect-prefix-routing-rule
         routing-rule?)

(struct routing-rule (ht))
  
(define (redirect-prefix-routing-rule #:old-prefix prefix
                                      #:new-prefix [new-prefix #f]
                                      #:new-host [new-host #f]
                                      #:new-protocol [new-protocol #f]
                                      #:redirect-code [redirect-code #f])
  (unless (or new-prefix new-host)
    (error 'redirect-prefix-routing-rule
           "new prefix or new host required"))
  (unless (memq new-protocol '(#f http https))
    (error 'redirect-prefix-routing-rule "bad protocol: ~e" new-protocol))
  (routing-rule (hash 'old-prefix prefix
                      'new-prefix new-prefix
                      'new-host new-host
                      'redirect-code redirect-code
                      'protocol new-protocol)))

;; add-routing-rules : string (listof routing-rule) ...
(define (add-routing-rules bucket links
                           #:preserve-existing? [preserve-existing? #t]
                           #:log-info [log-info (lambda (s) (log-info s))]
                           #:error [error error])
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
  
  (define (add-rule routing prefix replacement replacement-host redirect-code protocol)
    (struct-copy element routing
                 [content
                  (append
                   (for/list ([r (in-list (element-content routing))]
                              #:unless (and (element? r)
                                            (eq? 'RoutingRule (element-name r))
                                            (or (not preserve-existing?)
                                                (let ([c (find-sub 'Condition r)])
                                                  (or (not c)
                                                      (let ([p (find-sub 'KeyPrefixEquals c)])
                                                        (or (not p)
                                                            (equal? (content-string p) prefix))))))))
                     r)
                   (list
                    (elem 'RoutingRule
                          (elem 'Condition 
                                (elem 'KeyPrefixEquals
                                      (pcdata #f #f prefix)))
                          (apply elem 'Redirect
                                 (append
                                  (if replacement
                                      (list
                                       (elem 'ReplaceKeyPrefixWith
                                             (pcdata #f #f replacement)))
                                      null)
                                  (if replacement-host
                                      (list
                                       (elem 'HostName
                                             (pcdata #f #f replacement-host)))
                                      null)
                                  (if redirect-code
                                      (list
                                       (elem 'HttpRedirectCode
                                             (pcdata #f #f redirect-code)))
                                      null)
                                  (if protocol
                                      (list
                                       (elem 'Protocol
                                             (pcdata #f #f (symbol->string protocol))))
                                      null))))))]))
  
  (define o (open-output-bytes))
  (write-xml
   (struct-copy document config-doc
                [element (replace config 'RoutingRules 
                                  (for/fold ([routing routing]) ([link (in-list links)])
                                    (define ht (routing-rule-ht link))
                                    (add-rule routing
                                              (hash-ref ht 'old-prefix)
                                              (hash-ref ht 'new-prefix #f)
                                              (hash-ref ht 'new-host #f)
                                              (hash-ref ht 'redirect-code #f)
                                              (hash-ref ht 'protocol #f))))])
   o)

  (log-info "Updating redirection rules")

  (define resp
    (put/bytes (~a bucket "/?website") (get-output-bytes o) "application/octet-stream"))
  (unless (member (extract-http-code resp) '(200))
    (error 's3-sync "redirection-rules update failed")))
