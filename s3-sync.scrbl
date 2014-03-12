#lang scribble/manual
@(require scribble/bnf
          (for-label racket/base
                     racket/contract/base
                     s3-sync
                     aws/s3
                     aws/keys))

@title{AWS S3 Synchronization}

Syncronize an S3 bucket and a filesystem directory using

@commandline{racket -l- s3-sync @nonterm{src} @nonterm{dest}}

where either @nonterm{src} or @nonterm{dest} should start with
@exec{s3://} to identify a bucket and prefix, while the other is a
directory path in the local filesystem.

For example, to upload the content of @nonterm{src-dir} with a prefix
@nonterm{dest-path} within @nonterm{bucket}, use

@commandline{racket -l- s3-sync @nonterm{src-dir} s3://@nonterm{bucket}/@nonterm{dest-path}}

To download the items with prefix @nonterm{src-path} within
@nonterm{bucket} to @nonterm{dest-dir}, use

@commandline{racket -l- s3-sync s3://@nonterm{bucket}/@nonterm{src-path} @nonterm{dest-dir}}

The following options (supply them after @exec{s3-sync} and before
@nonterm{src}) are supported:

@itemlist[

 @item{@DFlag{dry-run} --- report actions that would be taken, but
       don't upload, download, delete, or change redirection rules.}

 @item{@DFlag{delete} --- delete destination items that have no
       corresponding source item.}

 @item{@DFlag{acl} @nonterm{acl} --- when uploading, use @nonterm{acl}
       for the access control list; for example, use
       @exec{public-read} to make items public.}

 @item{@DFlag{reduced} --- when uploading, specificy
       reduced-redundancy storage.}

 @item{@DFlag{include} @nonterm{regexp} --- consider only items whose
       name within the S3 bucket matches @nonterm{regexp}, where
       @nonterm{regexp} uses ``Perl-compatible'' syntax.}

 @item{@DFlag{exclude} @nonterm{regexp} --- do not consider items
       whose name within the S3 bucket matches @nonterm{regexp} (even
       if they match an inclusion pattern).}

 @item{@DFlag{s3-hostname} @nonterm{hostname} --- set the S3 hostname
       to @nonterm{hostname} instead of @tt{s3.amazon.com}.}

 @item{@DFlag{error-links} --- report an error if a soft link is found; this is the
       default treatment of soft links.}
 @item{@DFlag{follow-links} --- follow soft links.}
 @item{@DFlag{redirect-links} --- treat soft links as redirection
       rules to be installed for @nonterm{bucket} as a web site.}
 @item{@DFlag{ignore-links} --- ignore soft links.}

]

@section{S3 Synchronization API}

@defmodule[s3-sync]

The @racketmodname[s3-sync] library uses @racketmodname[aws/s3], so
use @racket[ensure-have-keys] and @racket[s3-host] before calling
@racket[s3-sync].

@defproc[(s3-sync [local-dir path-string?]
                  [s3-bucket string?]
                  [s3-path (or/c #f string?)]
                  [#:upload? upload? any/c #t]
                  [#:dry-run? dry-run? any/c #f]
                  [#:delete? delete? any/c #f]
                  [#:include include-rx (or/c #f regexp?) #f]
                  [#:exclude exclude-rx (or/c #f regexp?) #f]
                  [#:acl acl (or/c #f string?) #f]
                  [#:reduced-redundancy? reduced-redundancy? any/c #f]
                  [#:link-mode link-mode (or/c 'error 'follow 'redirect 'ignore) 'error]
                  [#:log log-info (string . -> . void?) log-s3-sync-info]
                  [#:error raise-error (symbol string? any/c ... . -> . any) error])
          void?]{

Syncronizes the content of @racket[local-dir] and @racket[s3-path]
within @racket[s3-bucket], where @racket[s3-path] can be @racket[#f]
to indicate an upload to the bucket with no prefix path. If
@racket[upload?] is true, @racket[s3-bucket] is changed to have the
content of @racket[local-dir], otherwise @racket[local-dir] is changed
to have the content of @racket[s3-bucket].

If @racket[dry-run?] is true, then actions needed for synchronization
are reported via @racket[log], but no uploads, downloads, deletions,
or redirection-rule updates are performed.

If @racket[delete?] is true, then destination items that have no
corresponding item at the source are deleted.

If @racket[include-rx] is not @racket[#f], then it is matched against
bucket paths (including @racket[s3-path] in the path). Only items that
match the regexp are considered for synchronization. If
@racket[exclude-rx] is not @racket[#f], then any item whose path
matches is @emph{not} considered for synchronization (even if it also
matches a provided @racket[include-rx]).

If @racket[acl] is not @racket[#f], then it is as the S3 access
control list on upload. For example, supply @racket["public-read"] to
make items public for reading.

If @racket[reduced-redundancy?] is true, then items are uploaded to S3
with reduced-redundancy storage (which costs less, so it is suitable
for files that are backed up elsewhere).

The @racket[link-mode] argument determines the treatment of soft links
in @racket[local-dir]:

@itemlist[

 @item{@racket['error] --- reports an error}

 @item{@racket['follow] --- follows soft links (i.e., treat it as a
       file or directory)}

 @item{@racket['redirect] --- treat it as redirection rule to be
       installed for @racket[bucket] as a web site on upload}

 @item{@racket['ignore] --- ignore}

]

The @racket[log-info] and @racket[raise-error] arguments determine how
progress is logged and errors are reported. The default
@racket[log-info] function logs the given string at the @racket['info]
level to a logger whose name is @racket['s3-sync].}
