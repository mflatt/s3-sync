#lang scribble/manual
@(require scribble/bnf
          (for-label racket/base
                     racket/contract/base
                     s3-sync
                     aws/s3
                     aws/keys))

@title{AWS S3 Synchronization}

To upload the content of @nonterm{src-dir} to @nonterm{dest-path}
within @nonterm{bucket}, use

@commandline{racket -l- s3-sync @nonterm{src-dir} s3://@nonterm{bucket}/@nonterm{dest-path}}

The following options (supply them after @exec{s3-sync} and before
@nonterm{src-dir}) are supported:

@itemlist[

 @item{@DFlag{dry-run} --- report actions that would be taken, but
       don't upload, delete, or change redirection rules}

 @item{@DFlag{delete} --- delete bucket items that have no corresponding file in @nonterm{src-dir}}

 @item{@DFlag{s3-hostname} @nonterm{hostname} --- set the S3 hostname
       to @nonterm{hostname} instead of @tt{s3.amazon.com}}

 @item{@DFlag{error-links} --- report an error if a soft link is found; this is the
       default treatment of soft links}
 @item{@DFlag{follow-links} --- follow soft links}
 @item{@DFlag{redirect-links} --- treat soft links as redirection
       rules to be installed for @nonterm{bucket} as a web site}
 @item{@DFlag{ignore-links} --- ignore soft links}

]

@section{S3 Synchronization API}

@defmodule[s3-sync]

The @racketmodname[s3-sync] library uses @racketmodname[aws/s3], so
use @racket[ensure-have-keys] and @racket[s3-host] before calling
@racket[s3-sync] functions.

@defproc[(s3-sync [src-dir path-string?]
                  [dest-bucket string?]
                  [dest-path (or/c #f string?)]
                  [#:dry-run? dry-run? any/c #f]
                  [#:delete? delete? any/c #f]
                  [#:link-mode link-mode (or/c 'error 'follow 'redirect 'ignore) 'error]
                  [#:log log-info (string . -> . void?) log-s3-sync-info]
                  [#:error raise-error (symbol string? any/c ... . -> . any) error])
          void?]{

Uploads the content of @racket[src-dir] to @racket[dest-path] within
@racket[dest-bucket], where @racket[dest-path] can be @racket[#f] to
indicate an upload to the bucket with no prefix path.

If @racket[dry-run?] is true, then actions needed for synchronization
are reported via @racket[log], but no uploads, deletions, or
redirection-rule updates are performed.

If @racket[delete?] is true, then bucket items that have no
corresponding file in @racket[src-dir] are deleted.

The @racket[link-mode] argument determines the treatment of soft links
in @racket[src-dir]:

@itemlist[

 @item{@racket['error] --- reports an error}

 @item{@racket['follow] --- follows soft links (i.e., treat it as a
       file or directory)}

 @item{@racket['redirect] --- treat it as redirection rule to be
       installed for @racket[bucket] as a web site}

 @item{@racket['ignore] --- ignore}

]

The @racket[log-info] and @racket[raise-error] arguments determine how
progress is logged and errors are reported. The default
@racket[log-info] function logs the given string at the @racket['info]
level to a logger whose name is @racket['s3-sync].}

