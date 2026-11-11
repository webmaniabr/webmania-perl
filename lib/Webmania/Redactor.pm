package Webmania::Redactor;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Encode       qw(encode decode FB_CROAK);
use Webmania::JSON;
use overload '""' => sub { '[private redaction context]' }, fallback => 1;
my $UUID = qr/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
my %PUBLIC;

sub new {
    my ( $c, $secrets, $value ) = @_;
    my $s = bless { literal => {}, numbers => {}, uuids => {}, remaining => 1024 * 1024, bytes => 0 }, $c;
    $s->add($_) for @{ $secrets // [] };
    $s->collect($value);
    $s;
}

sub _remember {
    my ( $self, $kind, $value ) = @_;
    return if exists $self->{$kind}{$value};
    if ( keys( %{ $self->{literal} } ) + keys( %{ $self->{numbers} } ) >= 1024
        || $self->{bytes} + length($value) > 65536 )
    {
        $self->{limited} = 1;
        return;
    }
    $self->{$kind}{$value} = 1;
    $self->{bytes} += length($value);
}

sub add {
    my ( $self, $value ) = @_;
    return unless defined $value && !ref $value;
    if ( !length $value ) { $self->{private_empty_string} = 1; return; }
    for my $literal ( $value, substr( JSON::PP->new->allow_nonref->encode($value), 1, -1 ) ) {
        $self->_remember( 'literal', $literal );
    }
}

sub _numeric_key {
    my ($value) = @_;
    my $lexical = "$value";
    $lexical =~ s/^\+//;
    my $number = eval { Webmania::Number->new($lexical) };
    return unless defined $number;
    return $number->decimal->bstr;
}

sub add_number {
    my ( $self, $value ) = @_;
    my $key = _numeric_key($value);
    if ( !defined $key ) { $self->{limited} = 1; return; }
    $self->_remember( 'numbers', $key );
}

sub uuid { my ( $s, $v ) = @_; $s->{uuids}{ lc $v } = 1 if defined $v && !ref $v && $v =~ /\A$UUID\z/ }

sub collect {
    my ( $s, $v, $depth ) = @_;
    $depth //= 0;
    return if $depth > 64;
    my $k = Webmania::JSON::kind($v);
    if ( $k eq 'object' ) {
        $v = $v->{values} if blessed $v;
        for my $key ( keys %$v ) { $s->add($key) unless $PUBLIC{$key}; $s->collect( $v->{$key}, $depth + 1 ) }
    }
    elsif ( $k eq 'array' ) { $s->collect( $_, $depth + 1 ) for @$v }

    # Serialization already established scalar type. A digit/boolean spelling is
    # still an opaque private string; numbers have exact semantic equivalence.
    elsif ( $k eq 'string' ) { $s->add($v) }
    elsif ( $k eq 'number' ) { $s->add_number($v) }
}

sub init_public {
    my $walk;
    $walk = sub {
        my $v = shift;
        if ( ref $v eq 'HASH' ) {
            $PUBLIC{$_} = 1 for keys %{ $v->{properties} // {} };
            $walk->($_) for values %$v;
        }
        elsif ( ref $v eq 'ARRAY' ) { $walk->($_) for @$v }
    };
    $walk->($_) for values %Webmania::Schema::DOC;
    undef $walk;
    $PUBLIC{body}  = 1;
    $PUBLIC{query} = 1;
}

sub text {
    my ( $s, $raw ) = @_;
    my $v = defined($raw) ? "$raw" : '';
    return '[redacted]' if !length($v) && $s->{private_empty_string};
    $s->{remaining} -= length $v;
    return '[redacted]' if $s->{limited} || length($v) > 65536 || $s->{remaining} < 0;
    my @ranges;
    while ( $v =~ /$UUID/g ) { push @ranges, [ $-[0], $+[0] ] if $s->{uuids}{ lc $& } }
    if ( keys %{ $s->{numbers} } ) {
        while ( $v =~
/(?<![[:alnum:]_.+-])([+-]?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)(?![[:alnum:]_]|\.[0-9])/g
          )
        {
            my ( $first, $last, $token ) = ( $-[1], $+[1], $1 );
            my $key = _numeric_key($token);
            return '[redacted]' unless defined $key;    # bounded numeric work, fail closed
            push @ranges, [ $first, $last ] if exists $s->{numbers}{$key};
            return '[redacted]' if @ranges > 8192;
        }
    }
    for my $lit ( keys %{ $s->{literal} } ) {
        my $start = 0;
        while ( ( my $at = index( $v, $lit, $start ) ) >= 0 ) {
            $start = $at + 1;
            my $end = $at + length $lit;

            # Opaque strings never gain numeric equivalence. Short numeric
            # literals retain token boundaries; longer opaque values match as
            # literal strings even inside filenames or diagnostic wrappers.
            my $numeric = length($lit) < 8
              && $lit =~ /\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/;
            next
              if $numeric
              && ( $at > 0 && substr( $v, $at - 1, 1 ) =~ /[[:alnum:]_.+-]/
                || $end < length($v)
                && ( substr( $v, $end, 1 ) =~ /[[:alnum:]_]/ || substr( $v, $end, 2 ) =~ /\A\.[0-9]/ ) );
            next
              if !$numeric
              && length($lit) < 8
              && ( $at > 0 && substr( $v, $at - 1, 1 ) =~ /[[:alnum:]_]/
                || $end < length($v) && substr( $v, $end, 1 ) =~ /[[:alnum:]_]/ );
            push @ranges, [ $at, $end ];
            return '[redacted]' if @ranges > 8192;
        }
    }
    my @merged;
    for my $r ( sort { $a->[0] <=> $b->[0] || $b->[1] <=> $a->[1] } @ranges ) {
        if ( @merged && $r->[0] <= $merged[-1][1] ) { $merged[-1][1] = $r->[1] if $r->[1] > $merged[-1][1] }
        else                                        { push @merged, [@$r] }
    }
    my ( $out, $pos ) = ( '', 0 );
    for (@merged) { $out .= substr( $v, $pos, $_->[0] - $pos ) . '[redacted]'; $pos = $_->[1] }
    $out .= substr( $v, $pos );
    substr( $out, 0, 2048 );
}

sub clean {
    my ( $s, $v, $d ) = @_;
    $d //= 0;
    return '[limited]' if $d > 64;
    my $k = Webmania::JSON::kind($v);
    return { map { $s->text($_) => $s->clean( $v->{$_}, $d + 1 ) } keys %$v } if $k eq 'object';
    return [ map { $s->clean( $_, $d + 1 ) } @$v ]                            if $k eq 'array';
    return $v           if $k eq 'boolean';    # structure, never an opaque string/number
    return '[redacted]' if $k eq 'string' && !length($v) && $s->{private_empty_string};

    if ( $k eq 'number' ) {
        my $text  = qq($v);
        my $clean = $s->text($text);
        return $clean eq $text ? $v : $clean;
    }
    return $s->text($v) if defined $v;
    undef;
}
sub protected { my ( $s, $v ) = @_; $s->{limited} || $s->{literal}{$v} || $s->{uuids}{ lc $v } }

sub _percent_decode {
    my ($value) = @_;
    $value =~ s/%([0-9a-f]{2})/chr(hex($1))/gie;
    return $value;
}

sub _decoded_location_literal {
    my ($raw) = @_;
    return if $raw =~ /[\x{D800}-\x{DFFF}]/;
    my $bytes = utf8::is_utf8($raw) ? encode('UTF-8', $raw) : $raw;
    $bytes = _percent_decode($bytes);
    my $decoded = eval { decode('UTF-8', $bytes, FB_CROAK) };
    return $@ ? undef : $decoded;
}
sub _observe_literal {
    my ($self,$literal) = @_;
    $self->add($literal);
    my $decoded = _decoded_location_literal($literal);
    $self->add($decoded) if defined $decoded;
}
# Privacy observation is deliberately lexical. It never normalizes dispatch or
# makes a Location trusted. Invalid UTF-8 stays raw; no replacement characters.
sub _location_form {
    my ( $self, $raw ) = @_;
    $self->add($raw);
    my ( $path, $rest ) = split /[?#]/, $raw, 2;
    $path =~ s@\A[A-Za-z][A-Za-z0-9+.-]*://@//@;
    if ( $path =~ m@\A//@ ) {
        my ( $authority, $tail ) = split m@/@, substr( $path, 2 ), 2;
        $path = '/' . ( $tail // '' );
        $self->_observe_literal($authority);
        my @parts = split /@/, $authority;
        pop @parts;
        for my $userinfo (@parts) { $self->add($_) for split /:/, $userinfo; }
    }
    while ( $path =~ /($UUID)/g ) { $self->uuid($1); $self->add($1); }
    # Matrix values, query/fragment tokens and assignment values are opaque.
    # Raw and valid decoded forms are both observed, including delimiters that
    # only become visible after percent decoding. This affects privacy only.
    for my $part ( split /[;?&#]/, $raw ) {
        my ( $key, $value ) = split /=/, $part, 2;
        $self->_observe_literal($value) if defined $value;
    }
    for my $part ( split /[&;?#]/, $rest // '' ) {
        my ( $key, $value ) = split /=/, $part, 2;
        $self->_observe_literal( defined $value ? $value : $key );
    }
}
sub observe_location {
    my ( $self, $raw ) = @_;
    $self->_location_form($raw);
    my $decoded = _decoded_location_literal($raw);
    $self->_location_form($decoded) if defined $decoded;
}

sub location {
    my ($raw) = @_;
    Webmania::Error::throw( 'protocol', 'Invalid redirect Location.' )
      unless defined $raw
      && length($raw) <= 8192
      && length($raw)
      && $raw !~ /[\s\x00-\x20\x7f\\#]/
      && $raw !~ /%(?![a-f0-9]{2})/i;
    if ( $raw =~ m@\Ahttps://([^/?#]+)@ ) {
        eval { Webmania::Transport::checked_url( 'https://' . $1, 1 ); 1 }
          or Webmania::Error::throw( 'protocol', 'Invalid redirect Location authority.' );
    }
    elsif ( $raw !~ m@\A/(?!/)@ ) {
        Webmania::Error::throw( 'protocol', 'Expected an HTTPS or rooted relative Location.' );
    }
    return Webmania::Protected->new($raw);
}

1;
