#!/bin/sh
# Exemplo neutro de homologação: roda o SDK deste checkout (dependências já instaladas no PERL5LIB).
# Sem WEBMANIA_LIVE=1 o exemplo não faz requisições e sai com 77.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec perl "$here/main.pl"
