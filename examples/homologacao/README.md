# Exemplo de homologação

[examples/homologacao](.) traz um exemplo neutro que emite, consulta e cancela uma NF-e e uma NFS-e em homologação (`ambiente` 2), além de quatro leituras. Ele só faz requisições com `WEBMANIA_LIVE=1`; sem isso imprime `{"result":"blocked"}` e sai com 77. Credenciais e URLs vêm apenas de variáveis de ambiente (`WEBMANIA_CONSUMER_KEY`, `WEBMANIA_CONSUMER_SECRET`, `WEBMANIA_ACCESS_TOKEN`, `WEBMANIA_ACCESS_TOKEN_SECRET`, `WEBMANIA_ISSUER_TOKEN`, `WEBMANIA_API1_BASE_URL`, `WEBMANIA_FILES_BASE_URL`, `WEBMANIA_API2_BASE_URL`, `WEBMANIA_LIVE_SCOPE` = `readonly`, `nfe`, `nfse` ou `all`, `WEBMANIA_LIVE_NFE_PAYLOAD`, `WEBMANIA_LIVE_NFSE_PAYLOAD`, `WEBMANIA_LIVE_LEDGER`, obrigatória nos escopos `nfe`, `nfse` e `all` e gravável antes de qualquer requisição (sem ela o exemplo sai com 77 sem fazer requisições), e `WEBMANIA_LIVE_ALLOWED_HOSTS`, obrigatória: hosts separados por vírgula que incluem o host de cada URL base; sem ela o exemplo sai com 77 antes de ler credenciais ou fazer requisições). Os payloads precisam ter `ambiente` igual ao inteiro JSON 2 no nível superior.

```sh
WEBMANIA_LIVE=1 WEBMANIA_LIVE_SCOPE=readonly sh examples/homologacao/run.sh
```

A saída tem uma linha JSON por passo (`step`, `operation`, `ok`, `http_status`, `outcome`, `kind`, `ref`), com `ref` igual aos 12 primeiros caracteres do SHA-256 do identificador e arquivos descritos por tamanho, SHA-256 e formato; nunca credenciais, identificadores ou bytes. Uma mutação nunca é repetida: `outcome=unknown` encerra com 1 e registra o documento no ledger para conferência; depois de uma emissão aprovada, o cancelamento é tentado mesmo que um passo intermediário falhe, e a consulta seguinte só conta como sucesso com status `cancelado`.
