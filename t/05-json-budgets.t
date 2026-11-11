use strict;
use warnings;
use Test::More;
use Webmania;

sub oversized {
    my ( $v, $label ) = @_;
    my $ok = eval { Webmania::JSON::encode_json($v); 1 };
    ok( !$ok && ref($@) eq 'Webmania::Error' && $@->kind eq 'validation', $label ) or diag("$@");
}
oversized( [ ( 'x' x 1000 ) x 10000 ],    'aggregate JSON token bytes stop before joining all siblings' );
oversized( 'x' x ( 8 * 1024 * 1024 + 1 ), 'single oversized string rejected before escaping' );
oversized( chr(0) x 1500000,              'escaped token byte cost bounded' );
oversized( chr(0x1f600) x 2200000,        'UTF8 byte cost counted independently of character length' );
my $small = { a => [ 0, 1, Webmania::false, undef ], text => chr(0x1f600) };
is(
    Webmania::JSON::encode_json( Webmania::JSON::snapshot($small) ),
    Webmania::JSON::encode_json($small),
    'byte accounting does not change accepted serialization'
);
oversized( [ (undef) x 100001 ], 'container node count rejected before delimiter allocation' );
my %many = map { $_ => undef } 1 .. 100001;
oversized( \%many, 'object node count rejected before delimiter allocation' );
done_testing;
