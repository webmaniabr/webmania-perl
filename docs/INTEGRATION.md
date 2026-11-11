# Detalhes técnicos de integração

Este documento reúne os detalhes técnicos do SDK para Perl que complementam o [README](../README.md): autenticação, URL base, limites de transporte, arquivos, relatórios e o tratamento do resultado fiscal. O texto é o mesmo que estava no README até esta versão.

## Escopo e disponibilidade

Integração de **Emissor Fiscal e Monitor Fiscal** em aplicações de servidor. O Emissor abrange NF-e/NFC-e na API1 e NFS-e, CT-e/CT-e OS, MDF-e, NFCom e DC-e na API2, com arquivos, eventos e as três operações gerenciais B2B públicas da API1. O Monitor mantém apenas as famílias de documentos e capacidades do seu contrato documentado.

Disponível no repositório público [github.com/webmaniabr/webmania-perl](https://github.com/webmaniabr/webmania-perl), com instalação a partir do clone (veja a seção Instalação). Ainda não há publicação em registro de pacotes; os nomes e versões abaixo identificam os pacotes gerados a partir desta fonte. Regras do provedor, aceitação fiscal real e plataformas adicionais permanecem com limitações explícitas.

## Visão geral para desenvolvedores

| Item | Detalhe |
|---|---|
| Status | Disponível no GitHub: versão `0.1.0_03` (distribuição `Webmania`), instalada a partir do clone do repositório; ainda sem publicação no CPAN ou em outro registro de pacotes |
| Runtime | Perl 5.36.0 (perfil medido em Linux aarch64), com Net::SSLeay, IO::Socket::SSL e XML::Parser fixados em [dependencies.lock.json](../dependencies.lock.json) |
| Clientes | `Webmania::NfeClient` (NF-e/NFC-e API 1.0), `Webmania::NfeFilesClient`, `Webmania::ResellerClient` (gerencial B2B API 1.0), `Webmania::EmitterClient` (emissor API 2.0), `Webmania::EmitterFilesClient`, `Webmania::MonitorClient` (Monitor Fiscal) |
| Cobertura | Operações descritas em [docs/operations.md](operations.md); payloads sintéticos em [examples](../examples) |
| Erros | `Webmania::Error`, com `kind`, `status` e `outcome` |
| Contrato | OpenAPI de [webmania-openapi](https://github.com/webmaniabr/webmania-openapi) fixado em [contracts.lock.json](../contracts.lock.json) pelo `contract_digest` e pelo SHA-256 de cada módulo |

### Autenticação

- **NF-e/NFC-e (API 1.0)** — `Webmania::CompanyCredentials` (`consumer_key`, `consumer_secret`, `access_token`, `access_token_secret`) é enviada nos cabeçalhos `X-Consumer-Key`, `X-Consumer-Secret`, `X-Access-Token` e `X-Access-Token-Secret`. `ResellerClient` usa credenciais de revenda próprias.
- **API 2.0** — `EmitterClient->new(issuer_token => ...)` e `MonitorClient->new(monitor_token => ...)` enviam `Authorization: Bearer <token>`. O token do emissor e o do Monitor são credenciais distintas.

O exemplo abaixo lê as credenciais de `%ENV` (`WEBMANIA_CONSUMER_KEY`, `WEBMANIA_CONSUMER_SECRET`, `WEBMANIA_ACCESS_TOKEN`, `WEBMANIA_ACCESS_TOKEN_SECRET`).

## Requisitos

Pacote **0.1.0_03**. Perl 5.36.0 em Linux aarch64/Debian bookworm, OpenSSL 3.0.22. É um runtime mantido pela distribuição, sem promessa de suporte a outras versões, threads ou plataformas. Veja docs/runtime-support.md.

## Instalação

Prepare Net::SSLeay 1.96, IO::Socket::SSL 2.099 e XML::Parser 2.47 em prefixo isolado, conforme dependencies.lock.json. Builds dessas dependências precisam de OpenSSL e Expat de desenvolvimento. Depois, instale a partir do clone do repositório público:

```sh
git clone https://github.com/webmaniabr/webmania-perl.git
cd webmania-perl
perl Makefile.PL INSTALL_BASE="$PWD/local"
make
make install
export PERL5LIB="$PWD/local/lib/perl5${PERL5LIB:+:$PERL5LIB}"
```

O clone contém os modelos e contratos; o consumidor não executa gerador nem precisa de Python. A distribuição Webmania ainda não está publicada no CPAN.

## Primeira consulta

Configure somente a credencial do serviço escolhido, por instância, a partir de ambiente privado ou cofre de segredos. O exemplo não emite nem cancela documentos. Execute consultas apenas com conta e ambiente autorizados; uma origem de fixture controlada deve ser configurada explicitamente pela API do cliente.

```perl
use strict;
use warnings;
use Webmania;

my $credentials = Webmania::CompanyCredentials->new(
    consumer_key => $ENV{WEBMANIA_CONSUMER_KEY},
    consumer_secret => $ENV{WEBMANIA_CONSUMER_SECRET},
    access_token => $ENV{WEBMANIA_ACCESS_TOKEN},
    access_token_secret => $ENV{WEBMANIA_ACCESS_TOKEN_SECRET},
);
my %options;
$options{base_url} = $ENV{WEBMANIA_BASE_URL} if defined $ENV{WEBMANIA_BASE_URL};
$options{ca_file} = $ENV{WEBMANIA_CA_FILE} if defined $ENV{WEBMANIA_CA_FILE};
my $nfe = Webmania::NfeClient->new(credentials => $credentials, %options);
my $exit_code = 0;
eval {
    my $certificate = $nfe->get_certificate_validity;
    my $expiration = $certificate->expiration; # exact Webmania::Number
    print $expiration->lexical, "\n";
    1;
} or do {
    my $error = $@;
    if (ref($error) && $error->isa('Webmania::Error')) {
        print STDERR $error->kind, " (", ($error->status // 0), ")\n";
        $exit_code = ($error->outcome // '') eq 'unknown' ? 3 : 2;
    } else {
        print STDERR "Falha local de configuracao ou validacao.\n";
        $exit_code = 1;
    }
};
$nfe->close;
exit $exit_code;
```

Salve o exemplo como `app.pl` e execute `perl app.pl` com o `PERL5LIB` instalado. `WEBMANIA_BASE_URL` e `WEBMANIA_CA_FILE` são opcionais para uma origem HTTPS documentada e seu arquivo de confiança ou fixture controlada. As quatro variáveis de credencial pertencem à empresa API1; não troque a origem com credenciais reais sem autorização.

A construção do cliente não comprova habilitação da conta. Respostas de sucesso e conversões explícitas para JSON podem conter dados fiscais, credenciais novas ou URLs privadas. Exponha apenas os campos necessários à aplicação.

## Integração e limites

Company and reseller credentials are distinct classes. `EmitterClient` accepts `issuer_token`, `MonitorClient` accepts `monitor_token`, and `ResellerClient` requires `ResellerCredentials`. Each instance keeps its own base URL, credentials and options. HTTPS is mandatory, including custom base URLs; userinfo, query, fragment and ambiguous paths in base URLs are refused. TLS 1.2+ verifies trust, dates and SAN hostname/IP; CN-only certificates are refused. Environment proxies are not consulted.

Pagination preserves page size, validates metadata, checks buffered items against cancellation/deadline, and exposes an explicit continuation when a local item limit stops a page. Polling requires bounded attempts, total deadline and at least five seconds between requests. `NfeClient->wait_report(body => ..., ...)` keeps sensitive report capability context inside one workflow. Polling only repeats its explicitly chosen status/report operation; ordinary operations never retry automatically.

Generated model packages live under `Webmania::Models::<ContractNamespace>::<SchemaName>`, for example `Webmania::Models::Api2MonitorDocuments::MonitorImportStatus`. Constructors and setters validate their schema. Nested responses project to generated classes; unions select a matching schema branch and preserve open fields. Use `get`, `set`, `has`, `remove` and `as_hash` for exact JSON names, case-distinct names such as `ID`/`id`, or fields colliding with model methods. Named field accessors use the original spelling. `has` distinguishes absent from present `undef`; `undef` represents JSON null, and `Webmania::true()` / `Webmania::false()` represent JSON booleans.

Use `Webmania::number('9007199254740993.123456789')` for exact decimals, exponents and large integers. Numbers retain their JSON lexical spelling; use `lexical`, `compare` and `is_integer`. Automatic native floating point conversion is refused. Plain Perl integer scalars are accepted; numeric-looking strings remain strings. Parsed response numbers are always `Webmania::Number`, including small integral values. JSON has a 64-level depth limit, 100,000 nodes and 8 MiB byte limit; numbers have at most 512 lexical characters and exponent magnitude 4096. Duplicate keys, cycles, nonfinite numbers and unpaired surrogates are refused.

Calls are synchronous. A `Cancel` object can be signaled from the caller's existing event/signal integration; a pre-cancelled call sends nothing. Total timeout includes owned name resolution, connection, handshake, headers and body. The forked resolver child closes inherited descriptors other than its owned IPC before resolving; unrelated caller/request sockets are not retained. Fork still copies interpreter memory; this is not an exec-isolation boundary. Resolver work is killed and reaped before the call returns. The SDK does not install application signal handlers or alarms. Calls do not follow redirects or retry. An effectful request that was sent and then failed ambiguously reports `outcome=unknown`; safe ordinary selectors may be available through protected recovery access. An observed capability or incomplete headers/trailers can suppress recovery and correlation.

File clients require explicit `trusted_origins` and an explicit `FileAuth` per operation. Modes are `company`, `issuer`, `document_token` (with `token`), `anonymous` or `capability`; incompatible modes fail before I/O, with no fallback. Public report capabilities carry no company/Bearer headers. A documented 302 yields `FileRedirect` with protected Location metadata and no transfer; other redirects raise an error. File success requires a documented status/media type and bounded structural inspection. XML forbids DTD/entities and excessive nesting; ZIP/ZIP64 compares local/central records, checks non-overlap, descriptors, CRC and expanded size; XLSX checks an unencrypted OPC/SpreadsheetML graph, namespaces, part types, internal relationships and numeric unsigned worksheet identities; each ZIP member is inflated once within the aggregate128MiB and per-part64MiB budgets. PDF recognizes a bounded physical classic-xref Catalog/Pages/Resources graph with opaque streams and strings; Standard V1/R2 protection is classified without decryption. Unsupported PDF features such as xref/object streams are refused. These are structural recognizers, without rendering, extraction, full PDF validation or OOXML/XSD certification. File inspection cooperatively checks cancellation and the call deadline between bounded parsing steps; synchronous parser work has no hard realtime guarantee. File bytes are preserved exactly. [Recognition profile and limits](file-recognition.md) describe the supported subset.

## Ambiente, URL base e relatórios

Cada cliente aceita `base_url` explícito (HTTPS, com prefixo de caminho opcional; HTTP somente em loopback de testes), sem usuário, query, fragmento ou segmentos `.`/`..`; o padrão é a origem pública do serviço. Os clientes de arquivo exigem `trusted_origins`. O exemplo de homologação lê `WEBMANIA_API1_BASE_URL` (padrão `https://webmania.com.br/api`, `NfeClient`), `WEBMANIA_FILES_BASE_URL` (padrão `https://nfe.webmania.com.br`, `NfeFilesClient`) e `WEBMANIA_API2_BASE_URL` (padrão `https://api.webmania.com.br`, `EmitterClient`, `EmitterFilesClient`, `ReportFilesClient` e `MonitorClient`); a SDK não lê ambiente por conta própria.

`NfeFilesClient->download_report` atende relatórios legados: CSV e XLSX rotulados `text/xml` são identificados pelos bytes (assinatura ZIP = XLSX; qualquer outro corpo = CSV devolvido byte a byte, inclusive Latin-1) e `media_type` informa o formato detectado; XML, HTML ou JSON nesse download é recusado e nenhuma outra operação ganha essa tolerância. Relatórios atuais usam `ReportFilesClient->download_report_v2(uuid => ..., auth => Webmania::FileAuth->new(mode => 'anonymous'))` (ou `company`, com `credentials`) na origem configurada; um JSON com `error`, mesmo em HTTP 200, é falha. Respostas chunked limitam cada linha de tamanho a 4096 bytes, sem consumir o orçamento de cabeçalhos; `get` de modelos devolve cópias independentes de listas e objetos.

## Credenciais e resultado fiscal

Credenciais da empresa API1, revenda API1, Bearer do emissor API2 e Bearer Monitor pertencem a escopos diferentes. Arquivos exigem a modalidade de acesso documentada. Uma falha não autoriza trocar automaticamente o modo ou a credencial. Mantenha segredos no servidor.

O catálogo contém 102 operações habilitadas. `nfeDownloadIbsCbsEventXml` não está disponível nesta versão do SDK: a chamada falha com `capability` e nenhuma requisição é enviada. Condições fiscais, municipais, de cadastro e de provedor continuam sujeitas ao contrato e ao serviço. Validação local, cálculo ou prévia não comprovam autorização fiscal.

Não há retry automático de operação nem seguimento automático de redirects. Depois de possível envio de uma operação com efeito, uma falha pode indicar resultado desconhecido. Preserve o seletor original com segurança, consulte a tentativa anterior e decida explicitamente como prosseguir. Uma referência protegida exige acesso deliberado e pode estar ausente; não é uma chave de idempotência.

## Arquivos e processamento

Verifique tipo de resultado, status e representação antes de consumir bytes. JSON pendente, HTML e redirect não comprovam PDF pronto. Proteção de PDF/ZIP é distinta da autorização de download; não há descriptografia automática nem confirmação de autenticidade fiscal. O reconhecimento de formatos cobre somente o perfil documentado desta implementação. Uma Location revelada continua privada e exige decisão explícita de origem e autenticação para outra transferência.

Paginação e espera são optativas e limitadas quando disponíveis. Um estado futuro ou desconhecido não significa conclusão. Não repita emissão, cancelamento ou importação inicial como se fossem consultas de processamento.

## Documentação para assistentes e contratos

Índices em Markdown para assistentes: [documentação Webmania](https://webmania.com.br/docs/llms.txt) e [API 2.0](https://api.webmania.com.br/llms.txt). Contratos OpenAPI: [API 2.0](https://api.webmania.com.br/docs/openapi) e [NF-e](https://webmania.com.br/docs/rest-api-nfe/?format=openapi).

No catálogo de SDKs, `perl` aparece como disponível no repositório público, com instalação pelo clone; plataforma Perl 5.36. Estar listado nesses índices não amplia a cobertura documentada deste SDK.
