use strict;
use warnings;
use Test::More;
use Webmania;
use lib 't/lib';
use TestServer;
my $uuid    = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
my $invalid = {
    uuid        => $uuid,
    status      => 'invalido',
    processado  => 0,
    importados  => [],
    descartados => [],
    erro        => 'Invalid archive'
};
my $page = {
    data  => [ { uuid => $uuid, cnpj => '12345678000199', razao_social => 'Synthetic' } ],
    meta  => { current_page => 1, last_page => 2, per_page => 10, total => 2 },
    links => {}
};
my $s = TestServer->new(
    [
        TestServer::response($invalid),
        TestServer::response($page),
        TestServer::response( { %$page, meta => { %{ $page->{meta} }, current_page => 2 } } )
    ]
);
my $m = $s->pool->{Monitor};
my $r = $m->wait_import( uuid => $uuid, max_attempts => 2, interval => 5, deadline => 10 );
is( $r->status,              'invalido',        'declared invalid import is terminal success' );
is( $r->erro,                'Invalid archive', 'declared erro retained' );
is( scalar @{ $s->records }, 1,                 'invalid import did not poll again' );
my $stream = $m->each_company( query => { page => 1, per_page => 10 }, max_items => 1, max_pages => 2 );
my $item   = $stream->next;
ok( defined $item, 'pagination yielded item' );
is_deeply(
    $stream->continuation,
    { page => 1, index => 1, per_page => 10 },
    'partial stream continuation exact'
);
ok( !defined $stream->next, 'item bound stops before another page' );
is( scalar @{ $s->records }, 2, 'item bound prevents new request' );
my $stream2 = $m->each_company( query => { page => 2, per_page => 10 } );
ok( defined $stream2->next,          'explicit page honored' );
ok( !defined $stream2->next,         'final page terminates' );
ok( !defined $stream2->continuation, 'complete stream clears continuation' );
like( $s->records->[-1]{path}, qr/(?:\?|&)page=2(?:&|$)/, 'actual sent page is explicit' );
$s->stop;

for my $query ( { page => 0 }, { page => '' }, { page => Webmania::number('1.5') }, { per_page => 0 } ) {
    my $ok = eval { $m->each_company( query => $query ); 1 };
    ok( !$ok && ref($@) eq 'Webmania::Error', 'invalid explicit pagination rejected before I/O' );
}
my $bad = TestServer->new(
    [ TestServer::response( { %$page, meta => { %{ $page->{meta} }, current_page => 2 } } ) ] );
my $b  = $bad->pool->{Monitor}->each_company;
my $ok = eval { $b->next; 1 };
ok( !$ok && ref($@) eq 'Webmania::Error' && $@->kind eq 'pagination', 'wrong page metadata rejected' );
$bad->stop;

# Required request fields, case-distinct additional keys, missing/null/false and
# lexical integer spelling survive new model and installed response projections.
my $v = Webmania::Models::Api1Fiscal::FiscalCompanyUpdateRequest->new(
    ID     => 'upper',
    id     => 'lower',
    cnae   => undef,
    future => { flag => Webmania::false, zero => 0, exact => Webmania::number('1e3') }
);
my $h = $v->as_hash;
is( $h->{ID}, 'upper', 'uppercase extension retained' );
is( $h->{id}, 'lower', 'lowercase extension retained' );
ok( $v->has('cnae') && !defined $v->cnae,                           'present null retained' );
ok( !$v->has('absent'),                                             'absent retained' );
ok( JSON::PP::is_bool( $h->{future}{flag} ) && !$h->{future}{flag}, 'false retained' );
is( $h->{future}{exact}->lexical, '1e3', 'semantic integer lexical spelling retained' );
done_testing;
