package TestServer;
use strict;
use warnings;
use IO::Socket::IP;
use IO::Socket::SSL;
use File::Temp   qw(tempdir);
use MIME::Base64 qw(encode_base64 decode_base64);
use Time::HiRes  qw(sleep);
use POSIX        ();

sub response {
    my ( $body, $status, $media, @headers ) = @_;
    $status //= 200;
    $media  //= 'application/json';
    my $bytes = ref($body) ? Webmania::JSON::encode_json($body) : $body;
    "HTTP/1.1 $status Synthetic\r\nContent-Type: $media\r\nContent-Length: "
      . length($bytes) . "\r\n"
      . join( '', map { "$_\r\n" } @headers ) . "\r\n"
      . $bytes;
}

sub new {
    my ( $class, $responses, %a ) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    system(
        'openssl',
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        "$dir/key.pem",
        '-out',
        "$dir/cert.pem",
        '-days',
        '1',
        '-subj',
        '/CN=' . ( $a{cn} // 'localhost' ),
        ( $a{cn_only} ? () : ( '-addext', 'subjectAltName=' . ( $a{san} // 'DNS:localhost,IP:127.0.0.1' ) ) )
    ) == 0 or die 'fixture certificate failed';
    my $listener =
      IO::Socket::IP->new( LocalHost => '127.0.0.1', LocalPort => 0, Listen => 64, ReuseAddr => 1 )
      or die 'fixture listener failed';
    my $port = $listener->sockport;
    my $pid  = fork();
    die 'fork fixture failed' unless defined $pid;
    if ( !$pid ) {
        $SIG{TERM} = sub { POSIX::_exit(0) };
        open my $log, '>:raw', "$dir/requests.jsonl" or POSIX::_exit(2);
        $log->autoflush(1);
        my $index = 0;
        while ( $index < @$responses ) {
            my $tcp = $listener->accept or last;
            my $s   = IO::Socket::SSL->start_SSL(
                $tcp,
                SSL_server    => 1,
                SSL_cert_file => "$dir/cert.pem",
                SSL_key_file  => "$dir/key.pem",
                Timeout       => 3,
                %{ $a{ssl_options} // {} }
            );
            next unless $s;
            eval {
                my $line = $s->getline;
                die 'bad request' unless defined $line && $line =~ /\A(\S+) (\S+) HTTP\/1\.1\r\n\z/;
                my ( $method, $path ) = ( $1, $2 );
                my %headers;
                while ( defined( my $l = $s->getline ) ) {
                    last if $l eq "\r\n";
                    my ( $k, $v ) = $l =~ /\A([^:]+):\s*(.*?)\r\n\z/;
                    die 'bad header' unless defined $v;
                    $headers{ lc $k } = $v;
                }
                my $body = '';
                my $left = $headers{'content-length'} // 0;
                while ($left) {
                    my $n = $s->read( my $buf, $left );
                    die 'truncated request' unless $n;
                    $body .= $buf;
                    $left -= $n;
                }
                my $record = {
                    method      => $method,
                    path        => $path,
                    headers     => \%headers,
                    body_base64 => encode_base64( $body, '' )
                };
                print $log Webmania::JSON::encode_json($record) . "\n";
                my $r = $responses->[ $index++ ];
                $r = $r->( $record, $index, $s ) if ref $r eq 'CODE';
                if ( ref $r eq 'ARRAY' ) {
                    for my $part (@$r) {
                        if   ( ref $part ) { sleep( $part->[0] ) }
                        else               { $s->print($part) }
                    }
                }
                elsif ( defined $r ) { $s->print($r) }

                1;
            };
            eval { $s->close( SSL_no_shutdown => 1 ) }
        }
        close $listener;
        POSIX::_exit(0);
    }
    close $listener;
    bless { pid => $pid, dir => $dir, base => "https://127.0.0.1:$port", ca => "$dir/cert.pem" }, $class;
}
sub base { $_[0]{base} }
sub ca   { $_[0]{ca} }

sub records {
    my $s = shift;
    return [] unless -f "$s->{dir}/requests.jsonl";
    open my $f, '<:raw', "$s->{dir}/requests.jsonl" or die;
    my @r;
    while (<$f>) {
        my $r = Webmania::JSON::decode_json($_);
        $r->{body} = decode_base64( delete $r->{body_base64} );
        push @r, $r;
    }
    \@r;
}

sub stop {
    my $s = shift;
    if ( $s->{pid} ) { kill 'TERM', $s->{pid}; waitpid( $s->{pid}, 0 ); delete $s->{pid} }
}
sub DESTROY { $_[0]->stop }

sub pool {
    my $s = shift;
    my %a = ( base_url => $s->base, ca_file => $s->ca, options => { timeout => 3 } );
    my $c = Webmania::CompanyCredentials->new(
        consumer_key        => 'synthetic-company-key',
        consumer_secret     => 'synthetic-company-secret',
        access_token        => 'synthetic-company-access',
        access_token_secret => 'synthetic-company-access-secret'
    );
    my $r = Webmania::ResellerCredentials->new(
        consumer_key        => 'synthetic-reseller-key',
        consumer_secret     => 'synthetic-reseller-secret',
        access_token        => 'synthetic-reseller-access',
        access_token_secret => 'synthetic-reseller-access-secret'
    );
    +{
        Nfe      => Webmania::NfeClient->new( credentials => $c, %a ),
        Reseller => Webmania::ResellerClient->new( credentials => $r, %a ),
        Emitter  => Webmania::EmitterClient->new( issuer_token  => 'synthetic-issuer',  %a ),
        Monitor  => Webmania::MonitorClient->new( monitor_token => 'synthetic-monitor', %a ),
        NfeFiles => Webmania::NfeFilesClient->new( credentials => $c, trusted_origins => [ $s->base ], %a ),
        EmitterFiles => Webmania::EmitterFilesClient->new(
            issuer_token    => 'synthetic-issuer-files',
            trusted_origins => [ $s->base ],
            %a
        )
    };
}
1;
