package Webmania::FileResponse;
use strict;
use warnings;
use overload '""' => sub { 'Webmania::FileResponse kind=' . $_[0]{kind} . ' [private bytes]' }, fallback => 1;
sub new        { my ( $c, %v ) = @_; bless \%v, $c }
sub bytes      { $_[0]{bytes} }
sub status     { $_[0]{status} }
sub media_type { $_[0]{media_type} }
sub kind       { $_[0]{kind} }
sub TO_JSON    { '[private file]' }

package Webmania::FileRedirect;
use overload '""' => sub { 'Webmania::FileRedirect [protected Location; no transfer]' }, fallback => 1;
sub new      { bless { location => $_[1] }, $_[0] }
sub location { $_[0]{location} }
sub TO_JSON  { '[protected redirect]' }

package Webmania::Files;
use strict;
use warnings;
use XML::Parser 2.47;
use IO::Uncompress::RawInflate qw($RawInflateError);
use Compress::Raw::Zlib        qw(crc32);
use Encode                     qw(decode FB_CROAK);
use Webmania::PDF;
use Webmania::XLSX;
sub _check { Webmania::Transport::_check($_[0]) if $_[0] }
sub bad { Webmania::Error::throw( 'protocol', $_[0] ) }

sub xml {
    my ($raw, $guard) = @_;
    _check($guard);
    my ( $depth, $nodes, $root ) = ( 0, 0, '' );
    my $p = XML::Parser->new(
        Handlers => {
            Doctype   => sub { die 'DTD' },
            Entity    => sub { die 'entity' },
            ExternEnt => sub { die 'external' },
            Start     => sub {
                my ( $p, $name, %attributes ) = @_;
                _check($guard);
                die 'attributes' if keys(%attributes)>4096;
                $root = $name unless length $root;
                die 'budget' if ++$depth > 64 || ++$nodes > 100000;
            },
            End => sub { $depth-- }
        }
    );
    eval { my $expat = $p->parse_start; for(my $i=0;$i<length($raw);$i+=16384) { _check($guard); $expat->parse_more(substr($raw,$i,16384)); } $expat->parse_done; };
    my $error=$@;
    die $error if ref($error) && eval { $error->isa('Webmania::Error') };
    bad('Expected bounded well-formed fiscal XML without DTD or entities.')
      if $error || !length $root || $root =~ /(?:^|:)(?:html|error)\z/i;
    1;
}

sub _zip64_extra {
    my ( $extra, @needed ) = @_;
    my $payload;
    while ( length $extra ) {
        bad('Truncated ZIP extra field.') if length($extra) < 4;
        my ( $tag, $length ) = unpack( 'vv', substr( $extra, 0, 4, '' ) );
        bad('Truncated ZIP extra data.') if $length > length($extra);
        my $data = substr( $extra, 0, $length, '' );
        if ( $tag == 1 ) {
            bad('Duplicate ZIP64 extra field.') if defined $payload;
            $payload = $data;
        }
    }
    my @values;
    for my $width (@needed) {
        bad('Missing or truncated ZIP64 extra field.') unless defined($payload) && length($payload) >= $width;
        push @values, unpack( $width == 8 ? 'Q<' : 'V', substr( $payload, 0, $width, '' ) );
    }
    return @values;
}

sub zip {
    my ( $raw, $xlsx, $guard ) = @_;
    _check($guard);
    bad('Expected a complete ZIP archive.')
      unless substr( $raw, 0, 4 ) eq "PK\x03\x04" || substr( $raw, 0, 4 ) eq "PK\x05\x06";
    my $e = rindex( $raw, "PK\x05\x06" );
    bad('ZIP end record is missing.') if $e < 0 || length($raw) - $e < 22;
    my ( $disk, $cdisk, $entries, $total, $size, $offset, $comment ) =
      unpack( 'vvvvVVv', substr( $raw, $e + 4, 18 ) );
    bad('Invalid ZIP comment length.') unless $e + 22 + $comment == length($raw);
    my $directory_end = $e;
    my $zip64         = $entries == 65535 || $total == 65535 || $size == 0xffffffff || $offset == 0xffffffff;

    if ( $zip64 || $e >= 20 && substr( $raw, $e - 20, 4 ) eq "PK\x06\x07" ) {
        bad('Missing ZIP64 locator.') unless $e >= 20 && substr( $raw, $e - 20, 4 ) eq "PK\x06\x07";
        my ( $ldisk, $zpos, $disks ) = unpack( 'VQ<V', substr( $raw, $e - 16, 16 ) );
        bad('Unsafe ZIP64 locator.') if $ldisk || $disks != 1 || $zpos > $e - 76;
        bad('Missing ZIP64 end record.') unless substr( $raw, $zpos, 4 ) eq "PK\x06\x06";
        my $zsize = unpack( 'Q<', substr( $raw, $zpos + 4, 8 ) );
        bad('Unsafe ZIP64 end-record length.')
          if $zsize < 44 || $zsize > 4096 || $zpos + 12 + $zsize != $e - 20;
        my ( $made, $need, $zdisk, $zcdisk, $zentries, $ztotal, $zsizecd, $zoffset ) =
          unpack( 'vvVVQ<Q<Q<Q<', substr( $raw, $zpos + 12, 44 ) );
        bad('Multi-disk ZIP64 is unsupported.') if $zdisk || $zcdisk || $zentries != $ztotal;
        bad('ZIP32 and ZIP64 records disagree.')
          if $entries != 65535     && $entries != $zentries
          || $total != 65535       && $total != $ztotal
          || $size != 0xffffffff   && $size != $zsizecd
          || $offset != 0xffffffff && $offset != $zoffset;
        ( $entries, $total, $size, $offset ) = ( $zentries, $ztotal, $zsizecd, $zoffset );
        $directory_end = $zpos;
    }
    bad('Unsupported or unsafe ZIP metadata.')
      if $disk
      || $cdisk
      || $entries != $total
      || $entries > 10000
      || $offset > length($raw)
      || $size > length($raw)
      || $offset + $size != $directory_end;
    my ( $pos, $expanded, $protected ) = ( $offset, 0, 0 );
    my ( %names, %parts, @ranges );
    for ( 1 .. $entries ) {
        _check($guard);
        bad('Truncated ZIP central directory.')
          if $pos + 46 > $directory_end || substr( $raw, $pos, 4 ) ne "PK\x01\x02";
        my (
            $made,   $need, $flags, $method, $time, $date, $crc, $comp,
            $uncomp, $nl,   $xl,    $cl,     $dn,   $ia,   $ea,  $local
        ) = unpack( 'vvvvvvVVVvvvvvVV', substr( $raw, $pos + 4, 42 ) );
        bad('Unsafe ZIP entry.')
          if $pos + 46 + $nl + $xl + $cl > $directory_end
          || ( $method != 0 && $method != 8 )
          || $flags & ~0x080f;
        my ( $uc64, $c64, $off64, $dn64 ) =
          ( $uncomp == 0xffffffff, $comp == 0xffffffff, $local == 0xffffffff, $dn == 65535 );
        my @width    = ( ( $uc64 ? 8 : () ), ( $c64 ? 8 : () ), ( $off64 ? 8 : () ), ( $dn64 ? 4 : () ) );
        my @extended = _zip64_extra( substr( $raw, $pos + 46 + $nl, $xl ), @width );
        $uncomp = shift @extended if $uc64;
        $comp   = shift @extended if $c64;
        $local  = shift @extended if $off64;
        $dn     = shift @extended if $dn64;
        bad('Multi-disk ZIP entries are unsupported.') if $dn;
        my $name = substr( $raw, $pos + 46, $nl );
        bad('Unsafe ZIP path or duplicate name.')
          if !length($name) || $name =~ /[\x00\\]/ || $name =~ m@\A/|(?:\A|/)\.\.(?:/|\z)@ || $names{$name}++;
        bad('XLSX part exceeds its byte budget.') if $xlsx && $uncomp > 64 * 1024 * 1024;
        $expanded += $uncomp;
        bad('ZIP expansion exceeds its budget.') if $expanded > 128 * 1024 * 1024 || $comp > length($raw);
        bad('Invalid ZIP local record.')
          if $local + 30 > $offset || substr( $raw, $local, 4 ) ne "PK\x03\x04";
        my ( $ln, $lf, $lm, $lt, $ld, $lc, $lcomp, $luncomp, $lnl, $lxl ) =
          unpack( 'vvvvvVVVvv', substr( $raw, $local + 4, 26 ) );
        bad('ZIP local and central records disagree.')
          if $lf != $flags || $lm != $method || $lnl != $nl || substr( $raw, $local + 30, $lnl ) ne $name;
        my @localwidth = ( ( $luncomp == 0xffffffff ? 8 : () ), ( $lcomp == 0xffffffff ? 8 : () ) );
        my @local64    = _zip64_extra( substr( $raw, $local + 30 + $lnl, $lxl ), @localwidth );
        $luncomp = shift @local64 if $luncomp == 0xffffffff;
        $lcomp   = shift @local64 if $lcomp == 0xffffffff;
        my $start = $local + 30 + $lnl + $lxl;
        my $end   = $start + $comp;
        bad('ZIP entry exceeds its bounded data area.') if $end > $offset || $start > $offset;

        if ( !( $flags & 8 ) ) {
            bad('ZIP local lengths or CRC disagree.')
              if $lc != $crc || $lcomp != $comp || $luncomp != $uncomp;
        }
        else {
            bad('ZIP streaming local metadata disagrees.')
              if $lc && $lc != $crc || $lcomp && $lcomp != $comp || $luncomp && $luncomp != $uncomp;
            my $d = $end;
            $d += 4 if substr( $raw, $d, 4 ) eq "PK\x07\x08";
            my $bytes = $uc64 || $c64 ? 20 : 12;
            bad('Invalid ZIP data descriptor.') if $d + $bytes > $offset;
            my @descriptor = unpack( $bytes == 20 ? 'VQ<Q<' : 'VVV', substr( $raw, $d, $bytes ) );
            bad('ZIP data descriptor disagrees.')
              unless $descriptor[0] == $crc && $descriptor[1] == $comp && $descriptor[2] == $uncomp;
            $end = $d + $bytes;
        }
        push @ranges, [ $local, $end ];
        if ( $flags & 1 ) { $protected = 1; }
        else {
            my $compressed = substr( $raw, $start, $comp );
            my $out        = '';
            if ( $method == 0 ) { $out = $compressed; }
            else {
                my $z = IO::Uncompress::RawInflate->new( \$compressed, Strict => 1, Transparent => 0 )
                  or bad('Invalid deflated ZIP entry.');
                while (1) {
                    _check($guard);
                    my $n = $z->read( my $buf, 16384 );
                    bad('Invalid deflated ZIP entry.') if $n < 0;
                    last                               if $n == 0;
                    $out .= $buf;
                    bad('ZIP entry expansion exceeds its declared length.') if length($out) > $uncomp;
                }
                bad('Trailing compressed bytes in ZIP entry.') if length( $z->trailingData );
            }
            bad('ZIP entry length or CRC is invalid.') unless length($out) == $uncomp && crc32($out) == $crc;
            $parts{$name} = $out if $xlsx && $name !~ m@/\z@;
        }
        $pos += 46 + $nl + $xl + $cl;
    }
    bad('Unexpected ZIP central-directory bytes.') unless $pos == $directory_end;
    my $previous = 0;
    for my $r ( sort { $a->[0] <=> $b->[0] } @ranges ) {
        bad('Overlapping ZIP entry records.') if $r->[0] < $previous;
        $previous = $r->[1];
    }
    bad('Expected an unencrypted XLSX workbook.')
      if $xlsx && ( $protected || !$names{'[Content_Types].xml'} || !$names{'xl/workbook.xml'} );
    _check($guard);
    return $xlsx ? Webmania::XLSX::inspect(\%parts, $guard) : $protected ? 'protected_zip' : 'zip';
}

# Records are checked on the bytes, never decoded: legacy exports may be Latin-1 as well as UTF-8.
sub csv {
    my ( $raw, $guard ) = @_;
    my $text = $raw;
    $text =~ s/\A\xEF\xBB\xBF//;
    bad('Expected a CSV report.')
      if $text =~ /\x00/ || $text =~ /\A\s*[<{\[]/ || !length $text || substr( $text, 0, 2 ) eq 'PK' || substr( $text, 0, 5 ) eq '%PDF-';
    my ( $quoted, $closed, $start, $rows ) = ( 0, 0, 1, 0 );
    # The scan is bounded by blocks so a deadline or cancellation stops it.
    for ( my $i = 0; $i < length($text); $i += 16384 ) {
        _check($guard);
        for my $c ( split //, substr( $text, $i, 16384 ) ) {
            if ($quoted) {
                if ( $c eq '"' ) { $quoted = 0; $closed = 1 }
                next;
            }
            if ($closed) {
                if ( $c eq '"' ) { $quoted = 1; $closed = 0; next }
                bad('Malformed CSV quoting.') unless $c =~ /[,;\r\n]/;
                $closed = 0;
            }
            if    ( $c eq '"' ) { bad('Malformed CSV quoting.') unless $start; $quoted = 1; $start = 0 }
            elsif ( $c eq ',' || $c eq ';' ) { $start = 1 }
            elsif ( $c eq "\n" ) { $rows++; $start = 1; bad('CSV row limit reached.') if $rows > 100000 }
            elsif ( $c ne "\r" ) { $start = 0 }
        }
    }
    bad('Truncated quoted CSV field.') if $quoted;
    1;
}

# Report files: the declared type and the bytes must agree. Only the legacy report route accepts
# text/xml: a ZIP local-file signature is XLSX and any other body is CSV returned byte-exact; XML,
# HTML and JSON bodies are refused. media_type carries the detected format in that case.
sub report {
    my ( $status, $media, $raw, $allowed, $guard, $legacy ) = @_;
    _check($guard);
    bad('Unexpected file media type.') unless grep { $_ eq $media } @$allowed;
    bad('Empty report file.') unless length $raw;
    my $xlsx = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    if ( $legacy && $media eq 'text/xml' ) {
        my $detected = substr( $raw, 0, 4 ) eq "PK\x03\x04" ? $xlsx : 'text/csv';
        return result( $status, $detected, $raw, [$detected], $guard );
    }
    if ( $media eq 'text/html' ) {
        # A declared HTML rendering of the report itself: kept as bytes, never executed.
        bad('Malformed report file.') if substr( $raw, 0, 2 ) eq 'PK' || $raw =~ /\x00/;
        _check($guard);
        return Webmania::FileResponse->new( status => $status, media_type => $media, bytes => $raw, kind => 'html' );
    }
    if ( $media eq 'application/xml' || $media eq 'text/xml' ) {
        bad('Malformed report file.') if substr( $raw, 0, 2 ) eq 'PK';
        xml( $raw, $guard );
        _check($guard);
        return Webmania::FileResponse->new( status => $status, media_type => $media, bytes => $raw, kind => 'xml' );
    }
    if ( $media eq 'text/csv' ) {
        csv( $raw, $guard );
        _check($guard);
        return Webmania::FileResponse->new( status => $status, media_type => $media, bytes => $raw, kind => 'csv' );
    }
    if ( $media eq 'application/octet-stream' ) {
        zip( $raw, 0, $guard ) if substr( $raw, 0, 2 ) eq 'PK';
        _check($guard);
        return Webmania::FileResponse->new( status => $status, media_type => $media, bytes => $raw, kind => 'binary' );
    }
    result( $status, $media, $raw, $allowed, $guard );
}

sub result {
    my ( $status, $media, $raw, $allowed, $guard ) = @_;
    _check($guard);
    bad('Unexpected file media type.') unless grep { $_ eq $media } @$allowed;
    my $kind;
    if ( $media eq 'application/octet-stream' ) {
        my $actual =
            substr( $raw, 0, 2 ) eq 'PK'    ? 'application/zip'
          : substr( $raw, 0, 5 ) eq '%PDF-' ? 'application/pdf'
          :                                   '';
        bad('Unknown binary report format.') unless $actual;
        $kind = result( $status, $actual, $raw, [$actual], $guard )->kind;
    }
    elsif ( $media eq 'application/pdf' ) {
        my $ok = eval { $kind = Webmania::PDF::inspect($raw, $guard); 1 };
        unless ($ok) {
            my $error=$@;
            die $error if ref($error) && eval { $error->isa('Webmania::Error') };
            bad('Expected a supported coherent classic-xref PDF file.');
        }
    }
    elsif ( $media eq 'application/xml' || $media eq 'text/xml' ) { xml($raw, $guard); $kind = 'xml' }
    elsif ($media eq 'application/zip'
        || $media eq 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' )
    {
        $kind = zip( $raw, index( $media, 'spreadsheetml' ) >= 0, $guard );
    }
    elsif ( $media eq 'text/csv' || $media eq 'application/csv' ) { csv( $raw, $guard ); $kind = 'csv' }
    else { bad('Unsupported fiscal file representation.') }
    _check($guard);
    Webmania::FileResponse->new( status => $status, media_type => $media, bytes => $raw, kind => $kind );
}
1;
