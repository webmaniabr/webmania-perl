package Webmania::Number;
use strict;
use warnings;
use Math::BigFloat;
use overload
  '""' => sub { $_[0]{lexical} },
  '0+' =>
  sub { Webmania::Error::throw( 'validation', 'Use exact comparison or lexical access for a JSON number.' ) },
  fallback => 1;

sub new {
    my ( $c, $s ) = @_;
    Webmania::Error::throw( 'validation', 'Expected a bounded exact JSON number.' )
      if !defined($s)
      || ref($s)
      || length($s) > 512
      || $s !~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/
      || ( $s =~ /[eE]([+-]?[0-9]+)/ && abs($1) > 4096 );
    bless { lexical => "$s" }, $c;
}
sub lexical { $_[0]{lexical} }
sub decimal { Math::BigFloat->new( $_[0]{lexical}, undef, undef ) }

sub compare {
    $_[0]->decimal->bcmp( ref( $_[1] )
          && $_[1]->isa(__PACKAGE__) ? $_[1]->decimal : Math::BigFloat->new( "$_[1]", undef, undef ) );
}
sub is_integer { $_[0]->decimal->is_int }
sub TO_JSON    { $_[0]{lexical} }

package Webmania::JSON;
use strict;
use warnings;
use JSON::PP     ();
use Scalar::Util qw(blessed refaddr);
use Encode       qw(encode decode FB_CROAK);
use B            ();
my $STR = JSON::PP->new->allow_nonref->canonical;
my $DEC = JSON::PP->new->allow_nonref->utf8;
sub number { Webmania::Number->new( $_[0] ) }

sub is_number {
    my ($v) = @_;
    return 1 if blessed($v) && $v->isa('Webmania::Number');
    return 0 if ref($v) || !defined($v);
    my $f = B::svref_2object( \$v )->FLAGS;
    return ( $f & B::SVp_IOK() ) && !( $f & B::SVp_POK() );
}

sub kind {
    my ($v) = @_;
    return 'null' unless defined $v;
    return 'boolean' if JSON::PP::is_bool($v);
    return 'number'  if is_number($v);
    return 'object'  if ref($v) eq 'HASH' || blessed($v) && $v->isa('Webmania::Model');
    return 'array'   if ref($v) eq 'ARRAY';
    return 'invalid'
      if !ref($v)
      && ( B::svref_2object( \$v )->FLAGS & B::SVp_NOK() )
      && !( B::svref_2object( \$v )->FLAGS & B::SVp_POK() );
    return 'string' unless ref $v;
    return 'invalid';
}

sub decimal {
    my ($v) = @_;
    blessed($v) && $v->isa('Webmania::Number') ? $v->decimal : Math::BigFloat->new( "$v", undef, undef );
}
sub integer { is_number( $_[0] ) && decimal( $_[0] )->is_int }

sub eq_json {
    encode_json( $_[0] ) eq encode_json( $_[1] )
      || kind( $_[0] ) eq 'number'
      && kind( $_[1] ) eq 'number'
      && decimal( $_[0] )->bcmp( decimal( $_[1] ) ) == 0;
}

sub encode_json {
    my ($v) = @_;
    my ( %active, $nodes );
    my $remaining = 8 * 1024 * 1024;
    my $account   = sub {
        my ($token) = @_;
        $remaining -= length encode( 'UTF-8', $token, FB_CROAK | Encode::LEAVE_SRC );
        Webmania::Error::throw( 'validation', 'JSON exceeds its byte budget.' ) if $remaining < 0;
        return $token;
    };
    my $string = sub {
        my ($text) = @_;

        # Bound a token before JSON::PP allocates its escaped representation.
        Webmania::Error::throw( 'validation', 'JSON exceeds its byte budget.' )
          if length($text) > 8 * 1024 * 1024;
        Webmania::Error::throw( 'validation', 'Invalid Unicode scalar.' )
          if $text =~ /[^\x{0}-\x{d7ff}\x{e000}-\x{10ffff}]/;
        return $account->( $STR->encode($text) );
    };
    my $walk;
    $walk = sub {
        my ( $x, $depth ) = @_;
        Webmania::Error::throw( 'validation', 'JSON exceeds its depth or node budget.' )
          if $depth > 64 || ++$nodes > 100000;
        my $k = kind($x);
        return $account->('null') if $k eq 'null';
        return $account->( $x          ? 'true'      : 'false' ) if $k eq 'boolean';
        return $account->( blessed($x) ? $x->lexical : "$x" )    if $k eq 'number';
        if ( $k eq 'string' ) {
            return $string->($x);
        }
        Webmania::Error::throw( 'validation', 'Expected JSON values; use Webmania::number for decimals.' )
          if $k eq 'invalid';
        my $id = refaddr($x);
        Webmania::Error::throw( 'validation', 'JSON cycles are not allowed.' ) if $active{$id};
        local $active{$id} = 1;
        my $out;
        if ( $k eq 'array' ) {
            Webmania::Error::throw( 'validation', 'JSON exceeds its node budget.' )
              if @$x > 100000 - $nodes;
            $account->( '[' . ( ',' x ( @$x ? @$x - 1 : 0 ) ) . ']' );
            $out = '[' . join( ',', map { $walk->( $_, $depth + 1 ) } @$x ) . ']';
        }
        else {
            my $h     = blessed($x) ? $x->{values} : $x;
            my $count = keys %$h;
            Webmania::Error::throw( 'validation', 'JSON exceeds its node budget.' )
              if $count > 100000 - $nodes;
            $account->( '{' . ( ':' x $count ) . ( ',' x ( $count ? $count - 1 : 0 ) ) . '}' );
            $out = '{'
              . join( ',', map { $string->($_) . ':' . $walk->( $h->{$_}, $depth + 1 ) } sort keys %$h )
              . '}';
        }
        return $out;
    };
    my ( $s, $error );
    eval { $s = encode( 'UTF-8', $walk->( $v, 0 ), FB_CROAK ); 1 } or $error = $@;
    undef $walk;
    die $error                                                              if $error;
    Webmania::Error::throw( 'validation', 'JSON exceeds its byte budget.' ) if length $s > 8 * 1024 * 1024;
    return $s;
}

sub decode_json {
    my ( $bytes, $limits ) = @_;
    my $max_nodes = $limits && $limits->{nodes} || 100000;
    Webmania::Error::throw( 'protocol', 'JSON exceeds its byte budget.' ) if length($bytes) > 8 * 1024 * 1024;
    my $valid = eval { decode( 'UTF-8', $bytes, FB_CROAK | Encode::LEAVE_SRC ) };
    my $s     = $bytes;
    Webmania::Error::throw( 'protocol', 'Expected valid UTF-8 JSON.' ) if $@;
    my ( $i, $nodes ) = ( 0, 0 );
    my $fail =
      sub { Webmania::Error::throw( 'protocol', 'Expected finite bounded JSON with unique object keys.' ) };
    my $ws  = sub { $i++ while substr( $s, $i, 1 ) =~ /[ \t\r\n]/ && $i < length $s };
    my $str = sub {
        my $start   = $i++;
        my $escaped = 0;
        while ( $i < length $s ) {
            my $c = substr( $s, $i++, 1 );
            if ($escaped)     { $escaped = 0; next }
            if ( $c eq '\\' ) { $escaped = 1; next }
            if ( $c eq '"' ) {
                my $v = eval { $DEC->decode( substr( $s, $start, $i - $start ) ) };
                $fail->() if $@ || $v =~ /[\x{d800}-\x{dfff}]/;
                return $v;
            }
            $fail->() if ord $c < 32;
        }
        $fail->();
    };
    my $read;
    $read = sub {
        my ($depth) = @_;
        $fail->() if $depth > 64 || ++$nodes > $max_nodes;
        $ws->();
        my $c = substr( $s, $i, 1 );
        return $str->() if $c eq '"';
        if ( $c eq '{' || $c eq '[' ) {
            my $isobj = $c eq '{';
            my $res   = $isobj ? {}  : [];
            my $close = $isobj ? '}' : ']';
            $i++;
            $ws->();
            if ( substr( $s, $i, 1 ) eq $close ) { $i++; return $res }
            while (1) {
                if ($isobj) {
                    $fail->() unless substr( $s, $i, 1 ) eq '"';
                    my $key = $str->();
                    $fail->() if exists $res->{$key};
                    $ws->();
                    $fail->() unless substr( $s, $i++, 1 ) eq ':';
                    $res->{$key} = $read->( $depth + 1 );
                }
                else { push @$res, $read->( $depth + 1 ) }
                $ws->();
                my $sep = substr( $s, $i++, 1 );
                last if $sep eq $close;
                $fail->() unless $sep eq ',';
                $ws->();
            }
            return $res;
        }
        for my $pair ( [ 'true', JSON::PP::true ], [ 'false', JSON::PP::false ], [ 'null', undef ] ) {
            if ( substr( $s, $i, length $pair->[0] ) eq $pair->[0] ) {
                $i += length $pair->[0];
                return $pair->[1];
            }
        }
        pos($s) = $i;
        if ( $s =~ /\G(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/gc ) {
            my $n = $1;
            $i = pos($s);
            my $v = eval { Webmania::Number->new($n) };
            $fail->() if $@;
            return $v;
        }
        $fail->();
    };
    my ( $v, $error );
    eval { $v = $read->(0); $ws->(); $fail->() unless $i == length $s; 1 } or $error = $@;
    undef $read;
    die $error if $error;
    return $v;
}
sub snapshot { decode_json( encode_json( $_[0] ) ) }
1;
