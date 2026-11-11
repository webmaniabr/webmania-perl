# Synthetic fiscal examples

`perl examples/validate_models.pl` validates the eight example payloads without making requests. These reused synthetic pinned-contract examples are references, not valid fiscal documents or independent acceptance evidence.

With an authorized test account, choose the corresponding client method: `NfeClient->issue_nfe` for nfe, `NfeClient->issue_nfce` for nfce, and `EmitterClient->issue_nfse`, `issue_cte` (cte and cte_os), `issue_mdfe`, `issue_nfcom` or `issue_dce` for the other models. Each accepts `body => $value`. Configure scoped credentials as shown in the main README and reconcile uncertain outcomes before another attempt. No live issuance example is executed by the qualification scripts.

Monitor read/paging/import examples and safe error access are shown in the main README. Review `docs/operations.md` for events, files, reports and supporting company operations.
