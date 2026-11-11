use strict;
use warnings;
use Test::More;
use Webmania;
use lib 't/lib';
use TestServer;
my $uuid   = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
my @values = (
    Webmania::number('1'), Webmania::number('1.0'), Webmania::number('1e0'), Webmania::number('1E+0'),
    '1',                   Webmania::number('0'),   Webmania::number('0.0'), Webmania::number('0e0'),
    '0'
);
my $s = TestServer->new( [ map { TestServer::response( '{"error":"synthetic"}', 503 ) } @values ] );
my $c = $s->pool->{Monitor};

for my $i ( 0 .. $#values ) {
    my $v  = $values[$i];
    my $ok = eval { $c->get_document( fd => $uuid, query => { atualizar_status => $v } ); 1 };
    my $e  = $@;
    ok(
        !$ok && ref($e) eq 'Webmania::Error' && $e->kind eq 'http',
        'accepted refresh representation sends once and fails HTTP'
    );
    if ( $i < 5 ) {
        is( $e->outcome, 'unknown', 'semantic one is an effectful refresh' );
        my $recovery = $e->recovery;
        is( $recovery ? $recovery->value->{fd} : undef, $uuid,
            'semantic refresh preserves safe fd recovery' );
    }
    else {
        ok(
            !defined $e->outcome && !defined $e->recovery,
            'semantic zero is passive without mutation uncertainty'
        );
    }
    is( scalar @{ $s->records }, $i + 1, 'no refresh retry' );
}
$s->stop;
my $a = Math::BigFloat->accuracy;
Math::BigFloat->accuracy(1);
my $t = TestServer->new( [ TestServer::response( '{"error":"synthetic"}', 503 ) ] );
eval {
    $t->pool->{Monitor}
      ->get_document( fd => $uuid, query => { atualizar_status => Webmania::number('1.0') } );
};
is( $@->outcome, 'unknown', 'refresh semantics independent of global Math accuracy' );
Math::BigFloat->accuracy($a);
$t->stop;
done_testing;
