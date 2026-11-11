use strict;
use warnings;
use Test::More;
use Webmania;
use lib 't/lib';
use TestServer;
for my $lexical ( '1', '0', 'true', 'false', '', 'AbCd' ) {
    my $r = Webmania::Redactor->new( [], { private => $lexical } );
    is( $r->clean($lexical), '[redacted]', 'serialized opaque string protected regardless spelling/length' );
    my $b = $r->clean(Webmania::false);
    ok( JSON::PP::is_bool($b) && !$b, 'actual false remains structural with opaque string context' );
}
for my $case (
    [
        '1',
        '1 1.0 1e0 1E+0 +1.00 0.1 -1 10 x1 1x 1.',
        '[redacted] [redacted] [redacted] [redacted] [redacted] 0.1 -1 10 x1 1x [redacted].'
    ],
    [
        '42',
        '42 42.0 4.2e1 -42 0.42 142 421 x42 42x 42.',
        '[redacted] [redacted] [redacted] -42 0.42 142 421 x42 42x [redacted].'
    ],
    [
        '1.25',
        '1.25 1.2500 125e-2 -1.25 0.125 11.25 x1.25 1.25x',
        '[redacted] [redacted] [redacted] -1.25 0.125 11.25 x1.25 1.25x'
    ],
    [ '0', '0 -0 0.0 0e0 0.1 -1 10 x0 0x', '[redacted] [redacted] [redacted] [redacted] 0.1 -1 10 x0 0x' ]
  )
{
    my ( $number, $input, $expected ) = @$case;
    my $r = Webmania::Redactor->new( [], { private => Webmania::number($number) } );
    is( $r->text($input), $expected,
        'typed private number canonical equivalence with signed/fraction/word controls' );
    is( $r->clean( Webmania::number($number) ), '[redacted]',
        'short exact private numeric scalar protected' );
    ok( JSON::PP::is_bool( $r->clean(Webmania::false) ), 'numeric provenance does not consume booleans' );
}
my $opaque = Webmania::Redactor->new( [ '1', 'AbCd' ] );
is(
    $opaque->text('1 1.0 1e0 0.1 -1 10 AbCd abcd'),
    '[redacted] 1.0 1e0 0.1 -1 10 [redacted] abcd',
    'opaque credentials keep literal case/spelling semantics'
);
my $a = Math::BigFloat->accuracy;
Math::BigFloat->accuracy(1);
my $r = Webmania::Redactor->new( [], { number => Webmania::number('1.25') } );
is( $r->text('1.2500 1.2 1.3'), '[redacted] 1.2 1.3', 'numeric redaction ignores global Math accuracy' );
Math::BigFloat->accuracy($a);
my $old_precision = Math::BigFloat->precision;
Math::BigFloat->precision(0);
my $precision_redactor = Webmania::Redactor->new( [], { private => Webmania::number('1.25') } );
is(
    $precision_redactor->text('125e-2 1.2 -1.25'),
    '[redacted] 1.2 -1.25',
    'numeric redaction ignores global Math precision'
);
Math::BigFloat->precision($old_precision);
my $typed_equivalence = Webmania::Redactor->new( [], { private => Webmania::number('1') } );

for my $lex ( '1', '1.0', '1e0', '1E+0' ) {
    is( $typed_equivalence->clean( Webmania::number($lex) ),
        '[redacted]', 'typed numeric echo canonical-equivalent scalar protected' );
}
for my $lex ( '0.1', '-1' ) {
    my $value = $typed_equivalence->clean( Webmania::number($lex) );
    ok( ref($value) eq 'Webmania::Number', 'distinct typed numeric echo keeps numeric type' );
    is( ref($value) ? $value->lexical : $value, $lex, 'distinct typed numeric echo remains unchanged' );
}
my $empty = Webmania::Redactor->new( [], { private => '' } );
is( $empty->text(''), '[redacted]', 'actual empty private string protected as a complete value' );
my $opaque_long_number = Webmania::Redactor->new( [], { private => '123456789' } );
is( $opaque_long_number->text('file_123456789.xml'),
    'file_[redacted].xml', 'long opaque numeric-looking strings retain literal privacy' );
my $typed_long_number = Webmania::Redactor->new( [], { private => Webmania::number('123456789') } );
is( $typed_long_number->text('file_123456789.xml'),
    'file_123456789.xml', 'actual numeric provenance retains unrelated word boundaries' );
my $body = {
    uuid      => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    motivo    => 'Synthetic cancellation reason',
    extension => {
        s1   => '1',
        s0   => '0',
        st   => 'true',
        sf   => 'false',
        n    => Webmania::number('42'),
        d    => Webmania::number('1.25'),
        z    => Webmania::number('0'),
        flag => Webmania::false
    }
};
my $response = {
    code   => Webmania::number('42.00'),
    status => Webmania::number('125e-2'),
    error  =>
'strone=[1]; strzero=[0]; strtrue=[true]; strfalse=[false]; numeric=[42.00]; decimal=[125e-2]; zero=[0e0]',
    success => Webmania::false,
    message => '-42 0.42 142 42x -1.25 0.125'
};
my $s  = TestServer->new( [ TestServer::response( $response, 503 ) ] );
my $c  = $s->pool->{Nfe};
my $ok = eval { $c->cancel_document( body => $body ); 1 };
my $e  = $@;
ok(
    !$ok && ref($e) eq 'Webmania::Error' && $e->kind eq 'http',
    'native mutation 503 produces structured failure'
);

for my $echo ( '1', '0', 'true', 'false', '42.00', '125e-2', '0e0' ) {
    unlike( $e->details->{error}, qr/\[\Q$echo\E\]/, 'native typed private scalar protected in diagnostics' );
}
is( $e->details->{code},   '[redacted]', 'native numeric JSON scalar42.00 semantically protected' );
is( $e->details->{status}, '[redacted]', 'native numeric JSON scalar125e-2 semantically protected' );
ok( JSON::PP::is_bool( $e->details->{success} ) && !$e->details->{success},
    'native false remains structural' );
is( $e->details->{message},  $response->{message}, 'native distinct values/words preserved' );
is( scalar @{ $s->records }, 1,                    'privacy failure transfers once' );
$s->stop;
done_testing;
