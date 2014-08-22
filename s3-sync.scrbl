#lang scribble/manual
@(require scribble/bnf
          (for-label racket/base
                     racket/contract/base
                     s3-sync
                     s3-sync/gzip
                     s3-sync/web
                     s3-sync/web-config
                     aws/s3
                     aws/keys))

@title{AWS S3 Synchronization}

@deftech{Synchronize} an S3 bucket and a filesystem directory using

@commandline{raco s3-sync @nonterm{src} @nonterm{dest}}

where either @nonterm{src} or @nonterm{dest} should start with
@exec{s3://} to identify a bucket and prefix, while the other is a
directory path in the local filesystem. Naturally, a @litchar{/}
within a bucket item's name corresponds to a directory separator in
the local filesystem.@margin-note{A bucket item is ignored if its name
ends in @litchar{/}. A bucket can contain an item whose name plus
@litchar{/} is a prefix for other bucket items, in which case
attempting to synchronize both from the bucket will produce an error,
since the name cannot be used for both a file and a directory.}

For example, to upload the content of @nonterm{src-dir} with a prefix
@nonterm{dest-path} within @nonterm{bucket}, use

@commandline{raco s3-sync @nonterm{src-dir} s3://@nonterm{bucket}/@nonterm{dest-path}}

To download the items with prefix @nonterm{src-path} within
@nonterm{bucket} to @nonterm{dest-dir}, use

@commandline{raco s3-sync s3://@nonterm{bucket}/@nonterm{src-path} @nonterm{dest-dir}}

The following options (supply them after @exec{s3-sync} and before
@nonterm{src}) are supported:

@itemlist[

 @item{@DFlag{dry-run} --- report actions that would be taken, but
       don't upload, download, delete, or change redirection rules.}

 @item{@DFlag{jobs} @nonterm{n} or @Flag{j} @nonterm{n} --- perform up
       to @nonterm{n} downloads or uploads in parallel.}

 @item{@DFlag{shallow} --- when downloading, constrain downloads to
       existing directories at @nonterm{dest} (i.e., no additional
       subdirectories); in both upload and download modes, extract the
       current bucket state in a directory-like way (which is useful
       if the bucket contains many more nested items than the local
       filesystem)}

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

 @item{@DFlag{gzip} @nonterm{regexp} --- on upload or for checking
       download hashes (to avoid unnecessary downloads), compress files
       whose name within the S3 bucket matches @nonterm{regexp}.}

 @item{@DFlag{gzip-min} @nonterm{bytes} --- when combined with
       @DFlag{gzip}, compress only files that are at least
       @nonterm{bytes} in size.}

 @item{@DPFlag{upload-metadata} @nonterm{name} @nonterm{value} ---
       includes @nonterm{name} with @nonterm{value} as metadata when
       uploading (without updating metadata for any file that is not
       uploaded).  This flag can be specified multiple times to add
       multiple metadata entries.}

 @item{@DFlag{s3-hostname} @nonterm{hostname} --- set the S3 hostname
       to @nonterm{hostname} instead of @tt{s3.amazon.com}.}

 @item{@DFlag{error-links} --- report an error if a soft link is found; this is the
       default treatment of soft links.}
 @item{@DFlag{follow-links} --- follow soft links.}
 @item{@DFlag{redirect-links} --- treat soft links as redirection
       rules to be installed for @nonterm{bucket} as a web site (upload only).}
 @item{@DFlag{redirects-links} --- treat soft links as individual
       redirections to be installed as metadata on a @nonterm{bucket}'s
       object, while the object itself is made empty (upload only).}
 @item{@DFlag{ignore-links} --- ignore soft links.}

 @item{@DFlag{web} --- sets defaults to @tt{public-read} access, reduced
       redundancy, compression for @filepath{.html}, @filepath{.css},
       and @filepath{.js} files that are 1K or larger, and
       @exec{Content-Cache} @exec{"max-age=0, no-cache"} metadata.}

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
                  [#:jobs jobs inexact-positive-integer? 1]
                  [#:shallow? shallow? any/c #f]
                  [#:dry-run? dry-run? any/c #f]
                  [#:delete? delete? any/c #f]
                  [#:include include-rx (or/c #f regexp?) #f]
                  [#:exclude exclude-rx (or/c #f regexp?) #f]
                  [#:make-call-with-input-file make-call-with-file-stream
                                               (or/c #f (string?
                                                         path?
                                                         . -> . 
                                                         (or/c #f
                                                               (path?
                                                                (input-port? . -> .  any)
                                                                . -> . any))))
                                               #f]
                  [#:get-content-type get-content-type
                                      (string? path? . -> . (or/c string? #f))
                                      #f]
                  [#:get-content-encoding get-content-encoding
                                          (string? path? . -> . (or/c string? #f))
                                          #f]
                  [#:acl acl (or/c #f string?) #f]
                  [#:reduced-redundancy? reduced-redundancy? any/c #f]
                  [#:upload-metadata upload-metadata (and/c (hash/c symbol? string?)
                                                            immutable?)
                                     #hash()]
                  [#:link-mode link-mode (or/c 'error 'follow 'redirect 'redirects 'ignore) 'error]
                  [#:log log-info (string . -> . void?) log-s3-sync-info]
                  [#:error raise-error (symbol? string? any/c ... . -> . any) error])
          void?]{

@tech{Synchronizes} the content of @racket[local-dir] and @racket[s3-path]
within @racket[s3-bucket], where @racket[s3-path] can be @racket[#f]
to indicate an upload to the bucket with no prefix path. If
@racket[upload?] is true, @racket[s3-bucket] is changed to have the
content of @racket[local-dir], otherwise @racket[local-dir] is changed
to have the content of @racket[s3-bucket].

If @racket[shallow?] is true, then in download mode, bucket items are
downloaded only when they correspond to directories that exist already
in @racket[local-dir]. In both download and upload modes, a true value
of @racket[shallow?] causes the state of @racket[s3-bucket] to be
queried in a directory-like way, exploring only relevant directories;
that exploration can be faster than querying the full content of
@racket[s3-bucket] if it contains many more nested items (with the
prefix @racket[s3-path]) than files within @racket[local-dir].

If @racket[dry-run?] is true, then actions needed for synchronization
are reported via @racket[log], but no uploads, downloads, deletions,
or redirection-rule updates are performed.

If @racket[jobs] is more than @racket[1], then downloads and uploads
proceed in background threads.

If @racket[delete?] is true, then destination items that have no
corresponding item at the source are deleted.

If @racket[include-rx] is not @racket[#f], then it is matched against
bucket paths (including @racket[s3-path] in the path). Only items that
match the regexp are considered for synchronization. If
@racket[exclude-rx] is not @racket[#f], then any item whose path
matches is @emph{not} considered for synchronization (even if it also
matches a provided @racket[include-rx]).

If @racket[make-call-with-file-stream] is not @racket[#f], it is
called to get a function that acts like @racket[call-with-input-file]
to get the content of a file for upload or for hashing. The arguments
to @racket[make-call-with-file-stream] are the S3 name and the local
file path. If @racket[make-call-with-file-stream] or its result is
@racket[#f], then @racket[call-with-input-file] is used. See also
@racket[make-gzip-handlers].

If @racket[get-content-type] is not @racket[#f], it is called to get
the @tt{Content-Type} field for each file on upload. The arguments to
@racket[get-content-type] are the S3 name and the local file path. If
@racket[get-content-type] or its result is @racket[#f], then a default
value is used based on the file extension (e.g., @racket["text/css"]
for a @filepath{css} file).

The @racket[get-content-encoding] argument is like
@racket[get-content-type], but for the @tt{Content-Encoding} field. If
no encoding is provided for an item, a @tt{Content-Encoding} field is
omitted on upload. Note that the @tt{Content-Encoding} field of an
item can affect the way that it is downloaded from a bucket; for
example, a bucket item whose encoding is @racket["gzip"] will be
uncompressed on download, even though the item's hash (which is used
to avoid unnecessary downloads) is based on the encoded content.

If @racket[acl] is not @racket[#f], then it use as the S3 access
control list on upload. For example, supply @racket["public-read"] to
make items public for reading. More specifically, if @racket[acl] is
not @racket[#f], then @racket['x-amz-acl] is set to @racket[acl] in
@racket[upload-metadata].

If @racket[reduced-redundancy?] is true, then items are uploaded to S3
with reduced-redundancy storage (which costs less, so it is suitable
for files that are backed up elsewhere).  More specifically, if
@racket[reduced-redundancy] is true, then
@racket['x-amz-storage-class] is set to @racket["REDUCED_REDUNDANCY"]
in @racket[upload-metadata].

The @racket[upload-metadata] hash table provides metadata to include
with any file upload (and only to files that are otherwise determined
to need uploading).

The @racket[link-mode] argument determines the treatment of soft links
in @racket[local-dir]:

@itemlist[

 @item{@racket['error] --- reports an error}

 @item{@racket['follow] --- follows soft links (i.e., treat it as a
       file or directory)}

 @item{@racket['redirect] --- treat it as a redirection rule to be
       installed for @racket[s3-bucket] as a web site on upload}

 @item{@racket['redirects] --- treat it as a redirection rule to be
       installed for @racket[s3-bucket]'s object as metadata on upload,
       while the object itself is uploaded as empty}

 @item{@racket['ignore] --- ignore}

]

The @racket[log-info] and @racket[raise-error] arguments determine how
progress is logged and errors are reported. The default
@racket[log-info] function logs the given string at the @racket['info]
level to a logger whose name is @racket['s3-sync].

@history[#:changed "1.2" @elem{Added @racket['redirects] mode.}
         #:changed "1.3" @elem{Added the @racket[upload-metadata] argument.}]}


@; ------------------------------------------------------------
@section{S3 @exec{gzip} Support}

@defmodule[s3-sync/gzip]

@defproc[(make-gzip-handlers [pattern (or/c regexp? string? bytes?)]
                             [#:min-size min-size exact-nonnegative-integer? 0])
         (values (string? path? . -> . (or/c #f
                                             (path? (input-port? . -> .  any)
                                              . -> . any)))
                 (string? path? . -> . (or/c string? #f)))]{

Returns values that are suitable as the
@racket[#:make-call-with-input-file] and
@racket[#:get-content-encoding] arguments to @racket[s3-sync] to
compress items whose name within the bucket matches @racket[pattern]
and whose local file size is at least @racket[min-size] bytes.}

@; ------------------------------------------------------------
@section{S3 Web Page Support}

@defmodule[s3-sync/web]

@history[#:added "1.3"]

@defproc[(s3-web-sync ...) void?]{

Accepts the same arguments as @racket[s3-sync], but adapts the
defaults to be suitable for web-page uploads:

@itemlist[

 @item{@racket[#:acl] --- defaults to @racket[web-acl]}
 @item{@racket[#:reduced-redundancy?] --- defaults to @racket[web-reduced-redundancy?]}
 @item{@racket[#:upload-metadata] --- defaults to @racket[web-upload-metadata]}
 @item{@racket[#:make-call-with-input-file] --- defaults to 
               a @exec{gzip} of files that match @racket[web-gzip-rx]
               and @racket[web-gzip-min-size]}
 @item{@racket[#:get-content-encoding] --- defaults to 
               a @exec{gzip} of files that match @racket[web-gzip-rx]
               and @racket[web-gzip-min-size]}

]}

@; ------------------------------------------------------------
@section{S3 Web Page Configuration}

@defmodule[s3-sync/web-config]

@history[#:added "1.3"]

@defthing[web-acl string?]{

The default access control list for web content, currently @racket["public-read"].}


@defthing[web-reduced-redundancy? boolean?]{

The default storage mode for web content, currently @racket[#t].}


@defthing[web-upload-metadata (and/c (hash/c symbol? string?)
                                     immutable?)]{

Default metadata for web content, currently @racket[(hash
'Cache-Control "max-age=0, no-cache")].}


@defthing[web-gzip-rx regexp?]{

Default regexp for paths to be @exec{gzip}ped, currently
@racket[#rx"[.](html|css|js)$"].}


@defthing[web-gzip-min-size exact-nonnegative-integer?]{

Default minimum size for files to be @exec{gzip}ped, currently
@racket[#rx"[.](html|css|js)$"].}
