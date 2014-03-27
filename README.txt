The "s3-sync" package supports uploading the content of a local
directory to an S3 bucket, or vice-versa, using the hashes of existing
bucket content to avoid unnecessary uploads or downloads.

Synchronization is available as a `raco s3-sync` command or an
`s3-sync` Racket function.

The package requires version 6.0.0.4 or later to take advantage of
`openssl/md5`.
