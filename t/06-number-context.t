use strict;
use warnings;
use Test::More;
use Webmania;
my $a = Math::BigFloat->accuracy;
my $p = Math::BigFloat->precision;
Math::BigFloat->accuracy(2);
my $n = Webmania::number('9007199254740993.12345');
is( $n->decimal->bstr, '9007199254740993.12345', 'Number exact conversion overrides caller global accuracy' );
is( Webmania::number('1.001')->compare('1.002'), -1, 'Number comparison exact under global accuracy' );
ok( !Webmania::number('1.001')->is_integer, 'integer semantics do not inherit rounding' );
ok(
    !Webmania::Schema::valid(
        'api1_fiscal', { type => 'number', minimum => Webmania::number('1.002') },
        Webmania::number('1.001')
    ),
    'schema numeric boundary ignores caller rounding'
);
ok(
    !Webmania::Schema::valid(
        'api1_fiscal', { type => 'string', 'x-sdk-numeric-minimum' => '1.002' }, '1.001'
    ),
    'schema numeric-string boundary ignores caller rounding'
);
is( Math::BigFloat->accuracy, 2, 'SDK leaves caller global accuracy unchanged' );
Math::BigFloat->accuracy(undef);
Math::BigFloat->precision(0);
is( Webmania::number('1.001')->decimal->bstr,
    '1.001', 'Number exact conversion overrides caller global precision' );
is( Math::BigFloat->precision, 0, 'SDK leaves caller global precision unchanged' );
Math::BigFloat->precision(undef);
Math::BigFloat->accuracy($a);
Math::BigFloat->precision($p);
done_testing;
