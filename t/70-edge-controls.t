use strict;
use warnings;
use Test::More;
use Webmania;
use lib 't/lib';
use TestServer;
use Time::HiRes qw(time alarm sleep);
use POSIX       qw(WNOHANG);

sub bad {
    my ( $call, $kind, $label ) = @_;
    my $ok = eval { $call->(); 1 };
    my $e  = $@;
    ok( !$ok && ref($e) eq 'Webmania::Error' && $e->kind eq $kind, $label ) or diag("$e");
    $e;
}
my $cred = Webmania::CompanyCredentials->new(
    consumer_key        => 'synthetickey',
    consumer_secret     => 'syntheticsecret',
    access_token        => 'syntheticaccess',
    access_token_secret => 'syntheticaccesssecret'
);
for my $base (
    'http://127.0.0.1',       'https://user:password@host.test',
    'https://host.test/?q=x', 'https://host.test/#fragment',
    'https://[::gg]',         'https://[::1',
    'https://[:::1]'
  )
{
    bad( sub { Webmania::NfeClient->new( credentials => $cred, base_url => $base ) },
        'configuration', 'unsafe or malformed base refused' );
}

# The last malformed IPv6 literal must be rejected structurally before resolver I/O.
my $good = Webmania::NfeClient->new( credentials => $cred, base_url => 'https://[::1]:443' );
like( "$good", qr/private/, 'valid IPv6 literal accepted for configuration' );
my $client = Webmania::EmitterClient->new( issuer_token => 'synthetic-issuer' );
bad( sub { $client->get_nfse( identifier => "\x{D800}" ) }, 'validation',
    'unpaired surrogate path rejected' );
my $cycle = [];
push @$cycle, $cycle;
bad( sub { Webmania::JSON::snapshot($cycle) },         'validation', 'array cycle bounded' );
bad( sub { Webmania::JSON::decode_json('"\\uD800"') }, 'protocol',   'escaped unpaired surrogate refused' );
my $r     = Webmania::Redactor->new( [ '1', 'abc' ] );
my $input = {
    status  => 'failed',
    number  => Webmania::number('-1'),
    decimal => Webmania::number('0.1'),
    flag    => Webmania::false,
    token   => '1',
    other   => 'alphabetabc abc'
};
my $clean = $r->clean($input);
is( $clean->{number}->lexical,  '-1',  'numeric -1 differs from credential1' );
is( $clean->{decimal}->lexical, '0.1', 'numeric0.1 differs from credential1' );
ok( JSON::PP::is_bool( $clean->{flag} ) && !$clean->{flag}, 'boolean shape retained' );
is( $clean->{token}, '[redacted]',             'actual short token protected' );
is( $clean->{other}, 'alphabetabc [redacted]', 'unrelated word preserved' );
my $uuid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
my $loc  = Webmania::Redactor->new;
$loc->observe_location(
    'https://user%3Apass%40bad.example.test/file/' . $uuid . '?token=opaque%26secret#ignored' );
like( $loc->text( uc $uuid ), qr/redacted/, 'UUID capability equivalent case protected' );
unlike( $loc->text('opaque&secret'), qr/opaque|secret/, 'encoded delimiters protected' );
my $before = Webmania::Transport::now();
my $cancel = Webmania::Cancel->new;
{
    local $SIG{ALRM} = sub { $cancel->cancel };
    alarm(.04);
    no warnings 'redefine';
    local *Webmania::Transport::getaddrinfo = sub { sleep(5); return ('fixture') };
    bad(
        sub {
            Webmania::Transport::_resolve(
                'stall.test',
                443,
                {
                    options  => Webmania::Transport::options( { timeout => 1, cancel => $cancel } ),
                    deadline => Webmania::Transport::now() + 1
                }
            );
        },
        'cancelled',
        'owned DNS cancellable'
    );
    alarm(0)
}
cmp_ok( Webmania::Transport::now() - $before, '<', .3, 'owned DNS cancellation promptly reaps child' );
is( waitpid( -1, WNOHANG ), -1, 'no resolver remains after cancellation' );

# File modes and trusted origins fail before dispatch, even with stored credentials.
bad(
    sub {
        Webmania::NfeFilesClient->new( credentials => $cred, trusted_origins => ['https://untrusted.test'] );
    },
    'configuration',
    'file trusted origin required'
);
my $files =
  Webmania::NfeFilesClient->new( credentials => $cred, trusted_origins => ['https://nfe.webmania.com.br'] );
bad(
    sub { $files->download_xml( identifier => $uuid, auth => Webmania::FileAuth->new( mode => 'issuer' ) ) },
    'capability',
    'unsupported file auth cannot fall back'
);

# Bounded diagnostics fail closed if literal collection or input budgets overflow.
my $limited = Webmania::Redactor->new( [ map { "secret-$_-value" } 1 .. 1100 ] );
is( $limited->text('any diagnostic'),             '[redacted]', 'literal budget fails closed' );
is( Webmania::Redactor->new->text( 'x' x 70000 ), '[redacted]', 'diagnostic text budget bounded' );
done_testing;
