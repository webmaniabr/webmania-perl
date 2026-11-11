use strict;
use warnings;
use Test::More;
use Webmania;
use lib 't/lib';
use TestServer;
use Time::HiRes qw(time);
my @companies = map {
    {
        uuid         => sprintf( '00000000-0000-4000-8000-%012x', $_ ),
        razao_social => 'Synthetic ' . $_,
        cnpj         => '12345678000199'
    }
} 1 .. 80;
my @pages = map {
    my $page = $_;
    +{
        data  => [],
        meta  => { current_page => $page, last_page => 2, per_page => 50, total => 80 },
        links => {}
    }
} ( 1, 2 );

# Explicit ranges avoid ternary/range precedence in fixture construction.
$pages[0]{data} = [ @companies[ 0 .. 49 ] ];
$pages[1]{data} = [ @companies[ 50 .. 79 ] ];
my $s = TestServer->new( [ map { TestServer::response($_) } @pages ] );
my $stream =
  $s->pool->{Monitor}->each_company( query => { per_page => 50 }, max_items => 75, max_pages => 3 );
my @items;
$stream->each( sub { push @items, $_[0] } );
is( scalar @items, 75, 'bounded pages yield exactly75' );
is_deeply( $stream->continuation, { page => 2, index => 25, per_page => 50 }, 'continuation page2/index25' );
my $records = $s->records;
is( scalar @$records, 2, 'no redundant page3' );
like( $_->{path}, qr/(?:\?|&)per_page=50(?:&|$)/, 'page size retained' ) for @$records;
my %uuid = map { ( ref($_) eq 'HASH' ? $_->{uuid} : $_->uuid ) => 1 } @items;
is( scalar keys %uuid, 75, 'no duplicate buffered items' );
isa_ok( $items[0], 'Webmania::Model', 'pagination preserves typed items' );
$s->stop;
my $uuid  = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
my $url   = "https://files.example.test/relat\x{f3}rio/$uuid?token=opaque-report-secret";
my $first = { uuid => $uuid, status => 'processando', url => $url };
my $w     = TestServer->new(
    [
        TestServer::response($first),
        TestServer::response(
            '{"error":"' . uc($uuid) . ' opaque-report-secret"}', 500,
            'application/json',                                   'X-Correlation-Id: ' . uc($uuid)
        )
    ]
);
my $n     = $w->pool->{Nfe};
my $begin = time;
my $ok    = eval {
    $n->wait_report(
        body =>
          { uuid => $uuid, modelo => 'nfe', relatorio => 'danfe', numero_inicio => '1', numero_final => '5' },
        max_attempts => 2,
        interval     => 5,
        deadline     => 8
    );
    1;
};
my $e = $@;
ok( !$ok && ref($e) eq 'Webmania::Error' && $e->kind eq 'http',
    'second report poll HTTP failure structured' );
cmp_ok( time - $begin, '>=', 5, 'minimum report poll cadence honored' );
ok( !defined $e->recovery, 'previous report capability cannot become recovery' );
unlike( $e->correlation_id, qr/aaaaaaaa/i, 'previous workflow UUID redacts case-equivalent correlation' );
unlike(
    Webmania::JSON::encode_json( $e->details ),
    qr/aaaaaaaa|opaque-report-secret/i,
    'previous report URL token remains protected'
);
my $wr = $w->records;
is( scalar @$wr,    2,              'bounded helper polls exactly twice' );
is( $wr->[0]{body}, $wr->[1]{body}, 'poll snapshot bytes stable' );
$w->stop;
my $done =
  TestServer->new( [ TestServer::response( { uuid => $uuid, status => 'concluido', url => $url } ) ] );
my $result = $done->pool->{Nfe}->wait_report(
    body         => { modelo => 'nfe', relatorio => 'danfe', numero_inicio => '1', numero_final => '5' },
    max_attempts => 2,
    interval     => 5,
    deadline     => 8
);
is( $result->url, $url, 'non-ASCII completed report URL remains usable' );
unlike( "$result", qr/opaque-report-secret|aaaaaaaa/, 'report model default display protected' );
is( scalar @{ $done->records }, 1, 'completed report does not repoll or download' );
$done->stop;
done_testing;
