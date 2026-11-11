# Migration to the new Perl generation

This is a new distribution and repository, not an in-place update of a legacy package. Keep the old integration and its receipts intact while validating a new client in an isolated prefix.

Replace process-global credentials and generic HTTP calls with the matching scoped client. Company credentials and reseller credentials use separate constructors; issuer and Monitor tokens belong to their dedicated clients. File access requires trusted origins and a per-call mode. A custom environment must use HTTPS and a certificate trusted by its CA file/store with a matching SAN.

Choose named methods from operations.md. Build request bodies from hashes or generated model constructors. Preserve JSON field spelling and case. Read typed responses through named accessors or get/as_hash; parsed numbers now use exact Webmania::Number objects. Use number('...') for decimal inputs and explicit true/false for booleans. Missing fields and JSON null are distinct through has/get.

Replace automatic retry loops around issuance with error/outcome inspection and an authorized reconciliation read. An unknown outcome is not permission to reissue. Handle FileRedirect as protected metadata; the SDK does not fetch it automatically. Save successful FileResponse bytes only after choosing an application destination. Review diagnostics before logging and avoid direct Perl hash dumps.

Run installed-package tests and the eight synthetic model examples first. Authorized fiscal acceptance and actual-account first use remain separate program gates; synthetic local results do not certify them.
