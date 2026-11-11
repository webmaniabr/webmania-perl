use strict;
use warnings;
use Test::More;
use Webmania;
use Compress::Raw::Zlib      qw(crc32);
use IO::Compress::RawDeflate qw(rawdeflate);

sub badfile {
    my ( $raw, $media, $name ) = @_;
    my $ok = eval { Webmania::Files::result( 200, $media, $raw, [$media] ); 1 };
    ok( !$ok && ref($@) eq 'Webmania::Error', $name ) or diag("$@");
}

sub archive {
    my ( $entries, %a )       = @_;
    my ( $local,   $central ) = ( '', '' );
    for my $e (@$entries) {
        my ( $name, $data ) = @$e;
        my $flags   = $a{descriptor} ? 8 : 0;
        my $crc     = crc32($data);
        my $payload = $data;
        my $method  = $a{deflate} ? 8 : 0;
        rawdeflate( \$data => \$payload ) or die 'deflate' if $method;
        my $comp       = length $payload;
        my $uncomp     = length $data;
        my $off        = length $local;
        my $extra      = $a{zip64} ? pack( 'vvQ<Q<', 1, 16, $uncomp, $comp ) : '';
        my $wirecomp   = $a{zip64} ? 0xffffffff : $a{descriptor} ? 0 : $comp;
        my $wireuncomp = $a{zip64} ? 0xffffffff : $a{descriptor} ? 0 : $uncomp;
        $local .= "PK\x03\x04"
          . pack( 'vvvvvVVVvv',
            20,        $flags,      $method,      0, 0, $a{descriptor} ? 0 : $crc,
            $wirecomp, $wireuncomp, length $name, length $extra )
          . $name
          . $extra
          . $payload;

        if ( $a{descriptor} ) {
            $local .= "PK\x07\x08" . pack( $a{zip64} ? 'VQ<Q<' : 'VVV', $crc, $comp, $uncomp );
        }
        my $cextra = $a{zip64} ? pack( 'vvQ<Q<Q<', 1, 24, $uncomp, $comp, $off ) : '';
        $central .= "PK\x01\x02"
          . pack(
            'vvvvvvVVVvvvvvVV',
            20, 20, $flags, $method, 0, 0, $crc,
            $a{zip64} ? 0xffffffff : $comp,
            $a{zip64} ? 0xffffffff : $uncomp,
            length $name, length $cextra,
            0, 0, 0, 0, $a{zip64} ? 0xffffffff : $off
          )
          . $name
          . $cextra;
    }
    my $end = length $local;
    my $raw = $local . $central;
    my $n   = @$entries;
    if ( $a{zip64} ) {
        my $zpos = length $raw;
        $raw .=
            "PK\x06\x06"
          . pack( 'Q<vvVVQ<Q<Q<Q<', 44, 45, 45, 0, 0, $n, $n, length $central, $end )
          . "PK\x06\x07"
          . pack( 'VQ<V', 0, $zpos, 1 );
    }
    $raw .= "PK\x05\x06"
      . pack( 'vvvvVVv',
        0, 0,
        $a{zip64} ? 65535      : $n,
        $a{zip64} ? 65535      : $n,
        $a{zip64} ? 0xffffffff : length $central,
        $a{zip64} ? 0xffffffff : $end, 0 );
    $raw;
}
my $xml = '<?xml version="1.0"?><nfeProc><NFe/></nfeProc>';
is( Webmania::Files::result( 200, 'application/xml', $xml, ['application/xml'] )->kind,
    'xml', 'well-formed XML' );
badfile( '<nfeProc>',                                      'application/xml', 'truncated XML' );
badfile( '<!DOCTYPE nfe [<!ENTITY x "y">]><nfe>&x;</nfe>', 'application/xml', 'DTD and entities blocked' );
badfile( ( '<a>' x 66 ) . ( '</a>' x 66 ),                 'application/xml', 'XML nesting bounded' );
badfile( '<html><body>pending</body></html>',              'application/xml', 'HTML disguised as XML' );
for my $mode (
    {},
    { deflate    => 1 },
    { descriptor => 1 },
    { zip64      => 1 },
    { zip64      => 1, descriptor => 1, deflate => 1 }
  )
{
    my $z = archive( [ [ 'fiscal.xml', $xml ] ], %$mode );
    is( Webmania::Files::result( 200, 'application/zip', $z, ['application/zip'] )->kind,
        'zip', 'ZIP stored/deflated/descriptor/ZIP64 positive' );
    my $bad = $z;
    substr( $bad, 14, 4, pack 'V', 0 );
    badfile( $bad,                'application/zip', 'local CRC mismatch' ) unless $mode->{descriptor};
    badfile( substr( $z, 0, -1 ), 'application/zip', 'truncated ZIP end record' );
}
my $z         = archive( [ [ 'fiscal.xml', $xml ], [ 'second.xml', $xml ] ] );
my $duplicate = archive( [ [ 'fiscal.xml', $xml ], [ 'fiscal.xml', $xml ] ] );
badfile( $duplicate, 'application/zip', 'duplicate ZIP entry names' );
my $overlap = $z;
my $first   = index( $overlap, "PK\x01\x02" );
my $second  = index( $overlap, "PK\x01\x02", $first + 4 );
substr( $overlap, $second + 42, 4, pack 'V', 0 );
badfile( $overlap, 'application/zip', 'overlapping/mismatched ZIP local reference' );
my $path = archive( [ [ '../file.xml', $xml ] ] );
badfile( $path, 'application/zip', 'ZIP path traversal' );
sub fixture { open my $f, '<:raw', 't/fixtures/catalog49/'.$_[0] or die $!; local $/; <$f> }
my $xlsx = fixture('canonical-workbook.xlsx');
is(
    Webmania::Files::result(
        200,   'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        $xlsx, ['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']
    )->kind,
    'xlsx',
    'bounded XLSX positive'
);
badfile(
    $z,
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ZIP without workbook is not XLSX'
);
badfile( "%PDF-1.4\ntruncated", 'application/pdf', 'truncated PDF' );
is(
    Webmania::Files::result( 200, 'application/pdf', fixture('canonical-protected.pdf'),
        ['application/pdf'] )->kind,
    'protected_pdf',
    'protected PDF classified'
);
badfile( "\"unfinished", 'text/csv', 'truncated CSV quotes' );
is( Webmania::Files::result( 200, 'text/csv', "name,value\n\"A, B\",1\n", ['text/csv'] )->kind,
    'csv', 'quoted CSV positive' );
done_testing;
