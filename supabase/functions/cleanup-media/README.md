# cleanup-media

Scheduler-only worker that claims expired, rejected, or abandoned media cleanup items and deletes their exact private Storage objects. The database is the authority for bucket/path targets; the worker rejects unexpected buckets, traversal-like paths, browser calls, oversized batches, and invalid credentials.

Set a 32+ character `MEDIA_CLEANUP_WORKER_SECRET`, deploy with gateway JWT verification disabled, and invoke by POST with `Authorization: Bearer …` and JSON `{ "limit": 50 }`. This function does not scan or approve media. The external malware scanner/re-encoder/transcoder remains a separate required service and must call only the service-role scan contract after writing a safe derivative.
