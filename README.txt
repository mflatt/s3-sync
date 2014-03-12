The "s3-sync" package supports uploading the content of a local
directory to an S3 bucket, using the hashes of existing bucket content
to avoid unnecessary uploads.

Download is not yet support, but planned.

The package requires version 6.0.0.4 or later to take advantage of
`openssl/md5`.
