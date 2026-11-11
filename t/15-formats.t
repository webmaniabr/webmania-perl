use strict;
use warnings;
use Test::More;
use Webmania;
my @uri_valid = (
    'https://example.test/path?name=value#part', 'mailto:user@example.test',
    'urn:example:animal:ferret:nose',            'file:///tmp/fiscal.xml',
    'https://[2001:db8::1]:443/file',            'https://[v1.abc:def]/x',
    'scheme:',                                   'https://user:pass@example.test/path%20one'
);
my @uri_invalid = (
    'https://[broken/path',                           'https://[:::1]/path',
    'https://example.test:abc/path',                  'https://user@@example.test/path',
    'https://example.test/%zz',                       'https://example.test/path with space',
    'https://example.test/relat' . chr(0xf3) . 'rio', 'https://example.test/path#one#two'
);
for (@uri_valid) {
    ok( Webmania::Schema::valid( 'api1_fiscal', { type => 'string', format => 'uri' }, $_ ),
        'RFC3986 URI positive' );
}
for (@uri_invalid) {
    ok( !Webmania::Schema::valid( 'api1_fiscal', { type => 'string', format => 'uri' }, $_ ),
        'RFC3986 URI negative' );
}
my @email_valid = (
    'user@example.test',           'user@localhost',
    '"quoted local"@example.test', 'a+b@example.test',
    'user@[127.0.0.1]',            'user@[IPv6:2001:db8::1]'
);
my @email_invalid = (
    'a..b@example.test',  '.a@example.test',  'a.@example.test',  'user@-host.test',
    # assembled: a consecutive-dot domain
    'user@example.' . '.test', 'user@[999.0.0.1]', 'user@[IPv6::::1]', 'user name@example.test',
);
for (@email_valid) {
    ok( Webmania::Schema::valid( 'api1_fiscal', { type => 'string', format => 'email' }, $_ ),
        'RFC5321 email positive' );
}
for (@email_invalid) {
    ok( !Webmania::Schema::valid( 'api1_fiscal', { type => 'string', format => 'email' }, $_ ),
        'RFC5321 email negative' );
}
done_testing;
