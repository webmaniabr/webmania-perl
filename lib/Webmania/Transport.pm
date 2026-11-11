package Webmania::Transport;
use strict;
use warnings;
use IO::Socket::IP;
use IO::Socket::SSL 2.099 ();
use IO::Select;
use Socket       qw(SOCK_STREAM SOL_SOCKET SO_ERROR getaddrinfo AI_ADDRCONFIG);
use Fcntl        qw(F_GETFL F_SETFL O_NONBLOCK);
use POSIX        qw(WNOHANG);
use MIME::Base64 qw(encode_base64 decode_base64);
use Time::HiRes  qw(clock_gettime CLOCK_MONOTONIC);
use Errno        qw(EINPROGRESS EWOULDBLOCK EAGAIN EINTR);
use Scalar::Util qw(blessed);
use overload '""' => sub { '[private service transport]' }, fallback => 1;
sub now { clock_gettime(CLOCK_MONOTONIC) }

sub checked_url {
    my ( $url, $origin_only ) = @_;
    Webmania::Error::throw( 'configuration',
        'Expected a bounded HTTPS base URL without credentials, query or fragment.' )
      unless defined $url
      && !ref $url
      && length($url) <= 4096
      && $url =~
m@\Ahttps://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?::([0-9]{1,5}))?((?:/[A-Za-z0-9_./~-]*)?)\z@;
    my ( $host, $port, $path ) = ( $1, $2 // 443, $3 // '' );
    if ( $host =~ /^\[/ ) {
        my $address = $host;
        $address =~ s/^\[|\]$//g;
        Webmania::Error::throw( 'configuration', 'Invalid IPv6 literal.' )
          unless Socket::inet_pton( Socket::AF_INET6(), $address );
    }
    Webmania::Error::throw( 'configuration', 'Unsafe base URL.' )
      if $port < 1
      || $port > 65535
      || $path =~ m@(?:^|/)\.{1,2}(?:/|$)@
      || $origin_only && length($path) && $path ne '/';
    my $origin = 'https://' . lc($host) . ( $port == 443 ? '' : ":$port" );
    $host =~ s/^\[|\]$//g;
    $path =~ s@/$@@;
    return {
        host      => $host,
        port      => $port,
        path      => $path,
        origin    => $origin,
        authority => ( $host =~ /:/ ? "[$host]" : $host ) . ( $port == 443 ? '' : ":$port" )
    };
}

sub new {
    my ( $c, %a ) = @_;
    bless { base => checked_url( $a{base_url} ), ca_file => $a{ca_file}, closed => 0 }, $c;
}
sub close { $_[0]{closed} = 1 }

sub options {
    my ($input) = @_;
    my %o = (
        timeout            => 30,
        max_response_bytes => 8 * 1024 * 1024,
        max_header_bytes   => 65536,
        %{ $input // {} }
    );
    my %known = map { $_ => 1 } qw(timeout max_response_bytes max_header_bytes cancel);
    Webmania::Error::throw( 'configuration', 'Unknown call option.' ) if grep { !$known{$_} } keys %o;
    Webmania::Error::throw( 'configuration', 'Timeout must be finite and in (0, 3600].' )
      unless defined $o{timeout}
      && !ref $o{timeout}
      && $o{timeout} =~ /\A(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z/
      && $o{timeout} > 0
      && $o{timeout} <= 3600;
    for my $k (qw(max_response_bytes max_header_bytes)) {
        Webmania::Error::throw( 'configuration', 'Response budgets must be positive bounded integers.' )
          unless defined $o{$k}
          && !ref $o{$k}
          && $o{$k} =~ /\A[0-9]+\z/
          && $o{$k} > 0
          && $o{$k} <= 128 * 1024 * 1024;
    }
    Webmania::Error::throw( 'configuration', 'Expected a Webmania::Cancel object.' )
      if $o{cancel} && !( blessed( $o{cancel} ) && $o{cancel}->isa('Webmania::Cancel') );
    \%o;
}

sub _check {
    my ($c) = @_;
    Webmania::Error::throw( 'cancelled', 'Request cancelled.' )
      if $c->{options}{cancel} && $c->{options}{cancel}->cancelled;
    Webmania::Error::throw( 'timeout', 'Request deadline expired.' ) if now() >= $c->{deadline};
}

sub _wait {
    my ( $sock, $write, $c ) = @_;
    while (1) {
        _check($c);
        my $sel   = IO::Select->new($sock);
        my @ready = $write ? $sel->can_write(.02) : $sel->can_read(.02);
        return if @ready;
    }
}

# A fork copies interpreter memory. Its worker must not retain application or
# other request descriptors while native name resolution is blocked. On this
# qualified Linux runtime, enumerate the child's table and allow only owned IPC.
sub _resolver_descriptors {
    my ($writer) = @_;
    my $keep = fileno($writer);
    POSIX::_exit(1) unless defined $keep;
    opendir( my $directory, '/proc/self/fd' ) or POSIX::_exit(1);
    my @inherited = grep { /\A[0-9]+\z/ } readdir($directory);
    closedir($directory);
    for my $fd (@inherited) { POSIX::close( 0 + $fd ) unless $fd == $keep; }
}

# DNS runs in a short-lived child so native resolver latency is bounded by the
# same total deadline and cancellation. Only its bounded address result is
# written to IPC; fork itself still copies the caller interpreter memory.
sub _resolve {
    my ( $host, $port, $c ) = @_;
    pipe( my $r, my $w ) or Webmania::Error::throw( 'network', 'Unable to initialize name resolution.' );
    my $pid = fork();
    Webmania::Error::throw( 'network', 'Unable to initialize name resolution.' ) unless defined $pid;
    if ( !$pid ) {
        $SIG{TERM} = 'DEFAULT';
        $SIG{INT}  = 'DEFAULT';
        my $resolved = eval {
            CORE::close($r);
            _resolver_descriptors($w);
            my ( $err, @addr ) =
              getaddrinfo( $host, "$port", { socktype => SOCK_STREAM, flags => AI_ADDRCONFIG } );
            my $out = '';
            if ( !$err ) {
                for my $a ( @addr[ 0 .. ( $#addr > 7 ? 7 : $#addr ) ] ) {
                    $out .=
                      join( ',', @$a{qw(family socktype protocol)}, encode_base64( $a->{addr}, '' ) ) . "\n";
                }
            }
            die 'resolver IPC budget' if length($out) > 16384;
            my $written = syswrite( $w, $out );
            die 'resolver IPC write' unless defined($written) && $written == length($out);
            1;
        };

        # Never unwind into the copied caller stack. The writer closes at exit,
        # so EOF means the worker has exited and waitpid can reap it promptly.
        POSIX::_exit( $resolved ? 0 : 1 );
    }
    CORE::close($w);
    fcntl( $r, F_SETFL, fcntl( $r, F_GETFL, 0 ) | O_NONBLOCK );
    my $out = '';
    my $ok  = eval {
        while (1) {
            _wait( $r, 0, $c );
            my $n = sysread( $r, my $buf, 16384 );
            if ( !defined $n ) {
                next if $! == EINTR || $! == EAGAIN;
                Webmania::Error::throw( 'network', 'Name resolution failed.' );
            }
            last unless $n;
            $out .= $buf;
            Webmania::Error::throw( 'network', 'Name resolution exceeded its budget.' )
              if length $out > 16384;
        }
        1;
    };
    my $e = $@;
    CORE::close($r);
    if ( !$ok ) { kill 'KILL', $pid }
    while ( waitpid( $pid, 0 ) < 0 && $! == EINTR ) { }
    die $e unless $ok;
    my @a;
    for ( split /\n/, $out ) {
        my ( $f, $t, $p, $addr ) = split /,/, $_, 4;
        push @a, [ $f, $t, $p, decode_base64($addr) ] if defined $addr;
    }
    Webmania::Error::throw( 'network', 'Name resolution failed.' ) unless @a;
    \@a;
}

sub _connect {
    my ( $self, $c ) = @_;
    my $b    = $self->{base};
    my $addr = _resolve( $b->{host}, $b->{port}, $c );
    my $sock;
    for my $a (@$addr) {
        _check($c);
        socket( my $s, $a->[0], $a->[1], $a->[2] ) or next;
        bless $s, 'IO::Socket::IP';
        $s->blocking(0);
        my $ok = connect( $s, $a->[3] );
        if ( !$ok && $! == EINPROGRESS ) {
            _wait( $s, 1, $c );
            my $err = getsockopt( $s, SOL_SOCKET, SO_ERROR );
            $ok = defined $err && unpack( 'i', $err ) == 0;
        }
        if ($ok) { $sock = $s; last }
        CORE::close($s);
    }
    Webmania::Error::throw( 'network', 'Unable to connect to the configured service.' ) unless $sock;
    $c->{socket} = $sock;
    my %ssl = (
        SSL_verify_mode     => IO::Socket::SSL::SSL_VERIFY_PEER(),
        SSL_verifycn_name   => $b->{host},
        SSL_verifycn_scheme =>
          { check_cn => 0, wildcards_in_alt => 'full_label', wildcards_in_cn => 0, ip_in_cn => 0 },
        SSL_hostname       => $b->{host},
        SSL_startHandshake => 0,
        SSL_cipher_list    => 'HIGH:!aNULL:!eNULL:!EXPORT:!LOW:!MD5:!RC4:!3DES:!PSK:!SRP',
        SSL_version        => '!SSLv2:!SSLv3:!TLSv1:!TLSv1_1'
    );
    $ssl{SSL_ca_file} = $self->{ca_file} if defined $self->{ca_file};
    my $ssl = IO::Socket::SSL->start_SSL( $sock, %ssl );
    Webmania::Error::throw( 'tls', 'TLS verification or initialization failed.' ) unless $ssl;
    while ( !$sock->connect_SSL ) {
        _check($c);
        my $e = $IO::Socket::SSL::SSL_ERROR;
        if    ( $e == IO::Socket::SSL::SSL_WANT_READ() )  { _wait( $sock, 0, $c ) }
        elsif ( $e == IO::Socket::SSL::SSL_WANT_WRITE() ) { _wait( $sock, 1, $c ) }
        else { Webmania::Error::throw( 'tls', 'TLS verification or handshake failed.' ) }
    }
    $sock;
}

sub _read {
    my ($c) = @_;
    my $s = $c->{socket};
    while (1) {
        _check($c);
        my $n = $s->sysread( my $buf, 16384 );
        return $buf if defined $n;
        my $e = $IO::Socket::SSL::SSL_ERROR;
        if ( $e == IO::Socket::SSL::SSL_WANT_READ() || $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR ) {
            _wait( $s, 0, $c );
        }
        elsif ( $e == IO::Socket::SSL::SSL_WANT_WRITE() ) { _wait( $s, 1, $c ) }
        else { Webmania::Error::throw( 'network', 'Response read failed.' ) }
    }
}

# Chunk-size lines (with extensions) are bounded one by one, never against the header budget.
my $MAX_CHUNK_LINE = 4096;

sub _line {
    my ( $c, $chunk_line ) = @_;
    while ( index( $c->{buffer}, "\n" ) < 0 ) {
        Webmania::Error::throw( 'protocol', 'Chunk size line exceeds its limit.' )
          if $chunk_line && length( $c->{buffer} ) > $MAX_CHUNK_LINE;
        Webmania::Error::throw( 'headers_limit', 'HTTP framing exceeds its header budget.' )
          if !$chunk_line && $c->{header_bytes} + length( $c->{buffer} ) > $c->{options}{max_header_bytes};
        my $x = _read($c);
        Webmania::Error::throw( 'protocol', 'Truncated HTTP framing.' ) unless length $x;
        $c->{buffer} .= $x;
        $c->{headers_started} = 1 unless $c->{headers_complete};
    }
    my $at   = index( $c->{buffer}, "\n" );
    my $line = substr( $c->{buffer}, 0, $at + 1, '' );
    if ($chunk_line) {
        Webmania::Error::throw( 'protocol', 'Chunk size line exceeds its limit.' ) if length $line > $MAX_CHUNK_LINE;
    }
    else {
        $c->{header_bytes} += length $line;
        Webmania::Error::throw( 'headers_limit', 'HTTP framing exceeds its header budget.' )
          if $c->{header_bytes} > $c->{options}{max_header_bytes};
    }
    Webmania::Error::throw( 'protocol', 'Malformed HTTP line ending.' ) unless $line =~ s/\r\n\z//;
    return $line;
}

sub _headers {
    my ( $c, $trailers ) = @_;
    my %h;
    while (1) {
        my $l = _line($c);
        last unless length $l;
        Webmania::Error::throw( 'protocol', 'Malformed HTTP response header.' )
          unless $l =~ /\A([!#\$%&'*+.^_`|~0-9A-Za-z-]+):([\x09\x20-\x7e\x80-\xff]*)\z/;
        my ( $k, $v ) = ( lc $1, $2 );
        $v =~ s/^[ \t]+|[ \t]+$//g;
        if ( $k eq 'location' ) { $c->{redactor}->observe_location($v); $c->{guard}->observe_location($v) }
        push @{ $h{$k} }, $v;
        $c->{headers} = { %{ $c->{headers} }, %h } unless $trailers;
        Webmania::Error::throw( 'headers_limit', 'Too many HTTP response headers.' )
          if ++$c->{header_count} > 200;

        if (   $trailers
            && $k =~
/\A(?:content-length|transfer-encoding|content-type|content-encoding|host|authorization|proxy-authorization|cookie|set-cookie|trailer)\z/
          )
        {
            Webmania::Error::throw( 'protocol', 'Forbidden HTTP trailer.' );
        }
    }
    \%h;
}

sub _take {
    my ( $c, $n ) = @_;
    while ( length( $c->{buffer} ) < $n ) {
        my $x = _read($c);
        Webmania::Error::throw( 'protocol', 'Truncated response body.' ) unless length $x;
        $c->{buffer} .= $x;
    }
    substr( $c->{buffer}, 0, $n, '' );
}

sub exchange {
    my ( $self, $verb, $path, $body, $headers, $c ) = @_;
    Webmania::Error::throw( 'closed', 'Client is closed.' ) if $self->{closed};
    $c->{deadline}     = now() + $c->{options}{timeout};
    $c->{buffer}       = '';
    $c->{header_bytes} = 0;
    $c->{header_count} = 0;
    my $res;
    my $ok = eval {
        _check($c);
        my $s = $self->_connect($c);
        my %h = ( %$headers, Host => $self->{base}{authority}, Connection => 'close' );
        $h{'Content-Length'} = length($body) if defined $body;
        my $req =
            "$verb $path HTTP/1.1\r\n"
          . join( '', map { "$_: $h{$_}\r\n" } sort keys %h ) . "\r\n"
          . ( defined $body ? $body : '' );
        my $at = 0;
        while ( $at < length $req ) {
            _check($c);
            my $n = $s->syswrite( $req, length($req) - $at, $at );
            if ( defined $n && $n > 0 ) { $c->{sent} = 1; $at += $n; next }
            my $e = $IO::Socket::SSL::SSL_ERROR;
            if    ( $e == IO::Socket::SSL::SSL_WANT_READ() ) { _wait( $s, 0, $c ) }
            elsif ( $e == IO::Socket::SSL::SSL_WANT_WRITE() || $! == EAGAIN || $! == EINTR ) {
                _wait( $s, 1, $c );
            }
            else { Webmania::Error::throw( 'network', 'Request write failed.' ) }
        }
        my ( $status, $h );
        my $infos = 0;
        while (1) {
            my $l = _line($c);
            Webmania::Error::throw( 'protocol', 'Malformed HTTP status.' )
              unless $l =~ /\AHTTP\/1\.[01] ([1-5][0-9]{2})(?: [\x20-\x7e]*)?\z/;
            $status = 0 + $1;
            $h      = _headers( $c, 0 );
            if ( $status < 200 ) {
                Webmania::Error::throw( 'protocol', 'Unsupported informational HTTP response.' )
                  unless ( $status == 100 || $status == 102 || $status == 103 )
                  && ++$infos <= 8
                  && !exists $h->{'content-length'}
                  && !exists $h->{'transfer-encoding'};
                next;
            }
            last;
        }
        $c->{status}           = $status;
        $c->{headers}          = $h;
        $c->{headers_complete} = 1;
        for my $k (
            qw(content-length transfer-encoding content-type content-encoding content-disposition location))
        {
            Webmania::Error::throw( 'protocol', 'Ambiguous singleton HTTP header.' )
              if @{ $h->{$k} // [] } > 1;
        }
        my $length = $h->{'content-length'}    && $h->{'content-length'}[0];
        my $te     = $h->{'transfer-encoding'} && $h->{'transfer-encoding'}[0];
        # Once chunked framing is advertised, later Location trailers may still
        # protect earlier diagnostic metadata. Clear only after the complete frame.
        $c->{trailers_incomplete} = 1 if defined $te;
        Webmania::Error::throw( 'protocol', 'Ambiguous HTTP body framing.' )
          if defined $length && defined $te;
        Webmania::Error::throw( 'protocol', 'Invalid Content-Length.' )
          if defined $length && ( $length !~ /\A[0-9]+\z/ || length $length > 12 );
        Webmania::Error::throw( 'protocol', 'Unsupported Transfer-Encoding.' )
          if defined $te && lc($te) ne 'chunked';
        Webmania::Error::throw( 'protocol', 'Encoded response bodies are unsupported.' )
          if $h->{'content-encoding'} && lc( $h->{'content-encoding'}[0] ) ne 'identity';
        my $max = $c->{options}{max_response_bytes};
        my $raw = '';

        if ( $status == 204 || $status == 304 ) {
            Webmania::Error::throw( 'protocol', 'Invalid body framing for a bodyless status.' )
              if defined $te || $status == 204 && defined $length && $length != 0;
            Webmania::Error::throw( 'protocol', 'Unexpected body bytes.' ) if length $c->{buffer};
        }
        elsif ( defined $te ) {
            my $chunks = 0;
            while (1) {
                my $l = _line( $c, 1 );
                Webmania::Error::throw( 'protocol', 'Malformed chunk size.' )
                  unless $l =~
/\A([0-9A-Fa-f]{1,12})(?:;[!#\$%&'*+.^_`|~0-9A-Za-z-]+(?:=(?:[!#\$%&'*+.^_`|~0-9A-Za-z-]+|"[\x20-\x21\x23-\x5b\x5d-\x7e]*"))?)*\z/;
                my $n = hex $1;
                last unless $n;
                Webmania::Error::throw( 'body_limit', 'Response body exceeds its byte budget.' )
                  if $n > $max - length $raw || ++$chunks > 100000;
                $raw .= _take( $c, $n );
                Webmania::Error::throw( 'protocol', 'Malformed chunk terminator.' )
                  unless _take( $c, 2 ) eq "\r\n";
            }
            $c->{trailers_incomplete} = 1;
            $c->{header_bytes} = 0;    # trailers have their own header budget
            my $t = _headers( $c, 1 );
            Webmania::Error::throw( 'protocol', 'Unexpected bytes after final chunk.' )
              if length $c->{buffer};
            $c->{trailers_incomplete} = 0;
        }
        elsif ( defined $length ) {
            Webmania::Error::throw( 'body_limit', 'Response body exceeds its byte budget.' )
              if $length > $max;
            $raw = _take( $c, 0 + $length );
            Webmania::Error::throw( 'protocol', 'Unexpected bytes after declared body.' )
              if length $c->{buffer};
        }
        else {
            $raw = $c->{buffer};
            $c->{buffer} = '';
            while (1) {
                Webmania::Error::throw( 'body_limit', 'Response body exceeds its byte budget.' )
                  if length $raw > $max;
                my $x = _read($c);
                last unless length $x;
                $raw .= $x;
            }
            Webmania::Error::throw( 'body_limit', 'Response body exceeds its byte budget.' )
              if length $raw > $max;
        }
        $res = [ $status, $h, $raw ];
        1;
    };
    my $e = $@;
    if ( my $s = $c->{socket} ) {
        eval { $s->close( SSL_no_shutdown => 1 ) }
    }
    die $e unless $ok;
    return $res;
}
1;
