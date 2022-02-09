#lang scribble/manual
@(require scribble/bnf
          (for-label racket/base
                     racket/contract/base
                     s3-sync
                     s3-sync/gzip
                     s3-sync/web
                     s3-sync/web-config
                     s3-sync/routing-rule
                     aws/s3
                     aws/keys))

@title{AWS S3 Synchronization}

@deftech{Synchronize} an S3 bucket and a filesystem directory using

@commandline{raco s3-sync @nonterm{src} @nonterm{dest}}

where either @nonterm{src} or @nonterm{dest} should start with
@exec{s3://} to identify a bucket and item name or prefix, while the
other is a path in the local filesystem to a file or
directory. Naturally, a @litchar{/} within a bucket item's name
corresponds to a directory separator in the local filesystem, and a
trailing @litchar{/} syntactically indicates a prefix (as opposed to a
complete item name).@margin-note*{A bucket item is ignored if its name
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

If @nonterm{src} refers to a directory or prefix (either syntactically
or as determined by consulting the filesystem or bucket),
@nonterm{dest} cannot refer to a file or bucket item. If
@nonterm{dest} refers to directory or prefix while @nonterm{src}
refers to a file or item, the @nonterm{src} file or item name is
implicitly added to the @nonterm{dest} directory or prefix.

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
       filesystem); when uploading, shallow mode is enabled by default
       unless @DFlag{delete} is specified}

 @item{@DFlag{delete} --- delete destination items that have no
       corresponding source item.}

 @item{@DFlag{acl} @nonterm{acl} --- when uploading, use @nonterm{acl}
       for the access control list; for example, use
       @exec{public-read} to make items public.}

 @item{@DFlag{reduced} --- when uploading, specificy
       reduced-redundancy storage.}

 @item{@DFlag{check-metadata} -- when uploading, check whether an
       existing item has the metadata that would be uploaded
       (including access control), and adjust the metadata if not.}

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
       uploaded). Metadata specified this way overrides metadata
       determined in other ways, except via
       @DPFlag{upload-metadata-mapping}. This flag can be specified
       multiple times to add multiple metadata entries.}

 @item{@DPFlag{upload-metadata-mapping} @nonterm{file} ---
       @racket[read]s @nonterm{file} to obtain a hash table that maps
       bucket-item names to a hash table of metadata, where a metadata
       hash table maps symbols to strings. Metadata supplied this way
       overrides metadata determined in other ways. This flag can be
       specified multiple times, and the mappings are merged so that
       later files override mappings supplied by earlier files.}

 @item{@DFlag{s3-hostname} @nonterm{hostname} --- set the S3 hostname
       to @nonterm{hostname} instead of @tt{s3.amazon.com}.}

 @item{@DFlag{region} @nonterm{region} --- set the S3 region to
       @nonterm{region} (e.g., @exec{us-east-1}) instead of issuing a
       query to locate the bucket's region.}

 @item{@DFlag{error-links} --- report an error if a soft link is found; this is the
       default treatment of soft links.}
 @item{@DFlag{follow-links} --- follow soft links.}
 @item{@DFlag{redirect-links} --- treat soft links as redirection
       rules to be installed for @nonterm{bucket} as a web site (upload only).}
 @item{@DFlag{redirects-links} --- treat soft links as individual
       redirections to be installed as metadata on a @nonterm{bucket}'s
       item, while the item itself is made empty (upload only).}
 @item{@DFlag{ignore-links} --- ignore soft links.}

 @item{@DFlag{web} --- sets defaults to @tt{public-read} access, reduced
       redundancy, compression for @filepath{.html}, @filepath{.css},
       @filepath{.js}, and @filepath{.svg} files that are 1K or larger,
       @exec{Content-Cache} @exec{"max-age=0, no-cache"} metadata for most files,
       and @exec{Content-Cache} @exec{"max-age=31536000, public"} metadata
       for files with the following suffixes: @filepath{.css}, @filepath{.js},
       @filepath{.png}, @filepath{.jpg}, @filepath{.jpeg}, @filepath{.gif},
       @filepath{.svg}, @filepath{.ico}, or @filepath{.woff}.}

]

@history[#:changed "1.12" @elem{For uploading, always use shallow mode unless @DFlag{delete} is specified.}]

@section{S3 Synchronization API}

@defmodule[s3-sync]

The @racketmodname[s3-sync] library uses @racketmodname[aws/s3], so
use @racket[ensure-have-keys], @racket[s3-host], and @racket[s3-region]
before calling @racket[s3-sync].

@defproc[(s3-sync [local-path path-string?]
                  [s3-bucket string?]
                  [s3-path (or/c #f string?)]
                  [#:upload? upload? any/c #t]
                  [#:jobs jobs inexact-positive-integer? 1]
                  [#:shallow? shallow? any/c (and upload? (not delete?))]
                  [#:check-metadata? check-metadata? any/c #f]
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
                  [#:upload-metadata-mapping upload-metadata-mapping
                                             (or/c
                                              (string? . -> . (and/c (hash/c symbol? string?)
                                                                     immutable?))
                                              (and/c (hash/c string?
                                                             (and/c (hash/c symbol? string?)
                                                                    immutable?))
                                                     immutable?))
                                             #hash()]
                  [#:link-mode link-mode (or/c 'error 'follow 'redirect 'redirects 'ignore) 'error]
                  [#:log log-info (string . -> . void?) log-s3-sync-info]
                  [#:error raise-error (symbol? string? any/c ... . -> . any) error])
          void?]{

@tech{Synchronizes} the content of @racket[local-path] and
@racket[s3-path] within @racket[s3-bucket], where @racket[s3-path] can
be @racket[#f] to indicate an upload to the bucket with no prefix
path. If @racket[upload?] is true, @racket[s3-bucket] at
@racket[s3-path] is changed to have the content of
@racket[local-path], otherwise @racket[local-path] is changed to have
the content of @racket[s3-bucket] at @racket[s3-path].

Typically, @racket[local-path] refers to a directory and
@racket[s3-path] refers to a prefix for bucket item names.
If @racket[local-path] refers to a file and @racket[upload?] is true,
then a single file is synchronized to @racket[s3-bucket] at
@racket[s3-path]. In that case, if @racket[s3-path] ends with a
@litchar{/} or it is already used as a prefix for bucket items, then
the file name of @racket[local-path] is added to @racket[s3-path] to
form the uploaded item's name; otherwise, @racket[s3-path] names the
uploaded item. If @racket[upload?] is @racket[#f] and @racket[s3-path]
is an item name (and not a prefix on other item names), then a single
bucket item is downloaded to @racket[local-path]; if
@racket[local-path] refers to a directory, then the portion of
@racket[s3-path] after the last @litchar{/} is used as the downloaded
file name.

If @racket[shallow?] is true, then in download mode, bucket items are
downloaded only when they correspond to directories that exist already
in @racket[local-path] (which is useful when @racket[local-path]
refers to a directory). In both download and upload modes, a true
value of @racket[shallow?] causes the state of @racket[s3-bucket] to
be queried in a directory-like way, exploring only relevant
directories; that exploration can be faster than querying the full
content of @racket[s3-bucket] if it contains many more nested items
(with the prefix @racket[s3-path]) than files within
@racket[local-path].

If @racket[check-metadata?] is true, then in upload mode, bucket items
are checked to ensure that the current metadata matches the metadata
that would be uploaded, and the bucket item's metadata is adjust if
not.

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
@racket[upload-metadata] (if it is not set already).

If @racket[reduced-redundancy?] is true, then items are uploaded to S3
with reduced-redundancy storage (which costs less, so it is suitable
for files that are backed up elsewhere).  More specifically, if
@racket[reduced-redundancy] is true, then
@racket['x-amz-storage-class] is set to @racket["REDUCED_REDUNDANCY"]
in @racket[upload-metadata] (if it is not set already).

The @racket[upload-metadata] hash table provides metadata to include
with any file upload (and only to files that are otherwise determined
to need uploading). The @racket[upload-metadata-mapping] provides a
mapping from bucket item names to metadata that adds and overrides
metadata for the specific item.

The @racket[link-mode] argument determines the treatment of soft links
in @racket[local-path]:

@itemlist[

 @item{@racket['error] --- reports an error}

 @item{@racket['follow] --- follows soft links (i.e., treat it as a
       file or directory)}

 @item{@racket['redirect] --- treat it as a redirection rule to be
       installed for @racket[s3-bucket] as a web site on upload; the target of the
       link does not have to exist locally}

 @item{@racket['redirects] --- treat it as a redirection rule to be
       installed for @racket[s3-bucket]'s item as metadata on upload,
       while the item itself is uploaded as empty; the target of the
       link does not have to exist locally}

 @item{@racket['ignore] --- ignore}

]

The @racket[log-info] and @racket[raise-error] arguments determine how
progress is logged and errors are reported. The default
@racket[log-info] function logs the given string at the @racket['info]
level to a logger whose name is @racket['s3-sync].

@history[#:changed "1.2" @elem{Added @racket['redirects] mode.}
         #:changed "1.3" @elem{Added the @racket[upload-metadata] argument.}
         #:changed "1.4" @elem{Added support for a single file as @racket[local-path]
                               and a bucket item name as @racket[s3-path].}
         #:changed "1.5" @elem{Added the @racket[check-metadata?] argument.}
         #:changed "1.6" @elem{Added the @racket[upload-metadata-mapping] argument.}
         #:changed "1.7" @elem{Changed @racket[upload-metadata-mapping] to allow a procedure.}
         #:changed "1.12" @elem{Changed default @racket[shallow?] to @racket[(and upload? (not delete?))].}
         #:changed "1.13" @elem{Changed @racket['redirects] for @racket[link-mode] to allow a locally non-existent target.}]}


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
 @item{@racket[#:upload-metadata-mapping] --- defaults to @racket[web-upload-metadata-mapping]}
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


@defproc[(web-upload-metadata-mapping [item string?])
         (and/c (hash/c symbol? string?)
                immutable?)]{

Item-specific metadata for web content, currently produces @racket[(hash
'Cache-Control "max-age=31536000, public")] for a @racket[item]
that ends in @filepath{.css}, @filepath{.js}, @filepath{.png}, @filepath{.jpg},
@filepath{.jpeg}, @filepath{.gif}, @filepath{.svg}, @filepath{.ico},
or @filepath{.woff}.

@history[#:added "1.7"
         #:changed "1.8" @elem{Added @filepath{.woff}.}]}


@defthing[web-gzip-rx regexp?]{

Default regexp for paths to be @exec{gzip}ped, currently
@racket[#rx"[.](html|css|js|svg)$"].}


@defthing[web-gzip-min-size exact-nonnegative-integer?]{

Default minimum size for files to be @exec{gzip}ped, currently
@racket[#rx"[.](html|css|js)$"].}

@; ------------------------------------------------------------
@section{S3 Routing Rules}

@defmodule[s3-sync/routing-rule]

@history[#:added "1.9"]

@defproc[(add-routing-rules [bucket string?]
                            [rules (listof routing-rule?)]
                            [#:preserve-existing? preserve-existing? any/c #t]
                            [#:log-info log-info-proc (lambda (s) (log-info s))]
                            [#:error error-proc error])
         void?]{

Configures the web-site routing rules at @racket[bucket] to include
each of the routing rules in @racket[rules]. Unless
@racket[preserve-existing?] is false, existing routing rules are
preserved except as overridden by @racket[rules].}

@defproc[(redirect-prefix-routing-rule [#:old-prefix prefix string?]
                                       [#:new-prefix new-prefix (or/c string? #f) #f]
                                       [#:new-host new-host (or/c string? #f) #f]
                                       [#:new-protocol new-protocol (or/c 'https 'http #f) #f]
                                       [#:redirect-code redirect-code (or/c string? #f) #f])
         routing-rule?]{

Creates a routing rule that redirects an access with a prefix matching
@racket[prefix] so that the prefix is replaced by @racket[new-prefix],
the access is redirected to @racket[new-host], or both. If
@racket[new-protocol] is provided, the redirect uses that protocol. At
least one of @racket[new-prefix] or @racket[new-host] must be
non-@racket[#f].

@history[#:changed "1.10" @elem{Added the @racket[#:redirect-code] argument.}
         #:changed "1.11" @elem{Added the @racket[#:new-protocol] argument.}]}

@defproc[(routing-rule? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a routing rule as created by
@racket[redirect-prefix-routing-rule], @racket[#f] otherwise.}
