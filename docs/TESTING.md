# Testes e desenvolvimento

Como compilar e testar o SDK para Perl a partir da fonte. O contrato fixado e a versão estão descritos em [INTEGRATION.md](INTEGRATION.md).

```sh
perl Makefile.PL
make test        # executa t/*.t com fixtures sintéticas, sem chamadas fiscais reais
perl examples/validate_models.pl   # valida os payloads de exemplo sem requisições
```
