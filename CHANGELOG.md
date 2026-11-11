# Changes

## 0.1.0_03

- README rewritten for integrators: requirements, installation, credentials from environment variables, homologation examples that issue, consult and cancel an NF-e and an NFS-e, and the method list per product. The technical details that were in the README moved unchanged to `docs/INTEGRATION.md`, `docs/TESTING.md`, `docs/operations.md` and `examples/homologacao/README.md`. Documentation only.
- README: the SDK is presented as available from the public GitHub repository and installed from a clone (`git clone https://github.com/webmaniabr/webmania-perl.git`); it is still not published to a package registry. Documentation only: code and contract are unchanged.
- The homologation example requires a writable `WEBMANIA_LIVE_LEDGER` in the `nfe`, `nfse` and `all` scopes (exit 77 with reason `ledger` before any request), so an unknown outcome is always recorded; a ledger record that cannot be written fails the run instead of being skipped.
- Regenerated from the updated public contract: tax-class list totals (`tributos_federais`, `tributos_estaduais`) accept the empty string the API returns for unset values; tax-class `situacao_tributaria` is 2 digits for IPI, PIS and COFINS and 2 to 3 digits for ICMS; NFS-e `impostos.reducao` and `impostos.cp` accept a string or a number.
- The homologation example treats `reprovado` (the API 1.0 status of a refused NF-e) as terminal.
- The homologation example requires `WEBMANIA_LIVE_ALLOWED_HOSTS` (exit 77 before any credential or request when it is missing or empty) and fails the run when the consult after a cancellation does not show `cancelado`.
- The homologation example accepts only the JSON integer 2 as the top-level `ambiente` of a payload; the text `"2"` is now refused (exit 77) before any request.
- Generated from the current public contract (14 modules, 103 operations, 102 enabled), pinned by `contract_digest` and per-module SHA-256 instead of a commit; generated files are compared as UTF-8 bytes. Issuance models follow the operation-derived `<OperationId>Payload` names.
- Chunked responses bound each chunk-size line to 4096 bytes on its own; only trailers use a (fresh) header budget, so downloads with many chunks no longer fail with `headers_limit`.
- `Model->get` returns independent copies of lists and objects; changes go through `set`/`remove` and validation.
- `download_report` accepts CSV and XLSX labeled `text/xml`, identified by bytes; XML, HTML and JSON bodies are refused. CSV is checked as records without requiring UTF-8 (Latin-1 exports are kept unchanged).
- New `ReportFilesClient->download_report_v2` (`fiscalDownloadReportV2`) with explicit access mode; declared report formats must match their bytes.
- `nfeDownloadIbsCbsEventXml` reports "not available in this SDK release" without sending a request; `examples/validate_models.pl` loads the SDK from the checkout.
- Report and file downloads check the deadline and cancellation while CSV is scanned and before a report is returned.
- New neutral homologation example (`examples/homologacao`), which records an unknown cancellation outcome in the ledger, and tests for report formats, chunk-size lines, model copies and the example.

## 0.1.0_02 — 2026-10-31

Protect metadata until chunked trailers finish; observe lexical Location capability assignments; preserve uncertainty for the quota-consuming report GET; recognize bounded physical classic-xref PDFs and coherent SpreadsheetML/OPC identities. This is author qualification pending a new independent review; the earlier alpha1 seal and four catalog limitations remain historical evidence.

## 0.1.0_01 — 2026-10-30

Initial new Perl implementation: six scoped clients, deterministic pinned contract generator, named operations and models, exact JSON/schema/projection runtime, native verified HTTPS, bounded file classification, redacted errors, cancellation/deadlines, pagination and polling. Author-controlled Linux Docker qualification only; independent/live/native/certification gates remain open.

### Review fixes

Removes scalar privacy heuristics in favor of serialized string/number provenance and exact numeric-equivalent redaction; closes unrelated inherited resolver-worker descriptors; and uses exact semantic integer effects for Monitor refresh uncertainty/recovery. New native timing/reentrant/resource and type-provenance regressions accompany these fixes. No new service or platform scope is added.
