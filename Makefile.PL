use strict;
use warnings;
use ExtUtils::MakeMaker;
use File::Find;
my %pm;
find(
    sub {
        return unless -f $_;
        my $p = $File::Find::name;
        ( $p =~ s@^lib/@@ );
        $pm{$File::Find::name} = '$(INST_LIB)/' . $p;
    },
    'lib'
);
WriteMakefile(
    NAME             => 'Webmania',
    VERSION_FROM     => 'lib/Webmania.pm',
    ABSTRACT         => 'Scoped Webmania fiscal and Monitor SDK',
    AUTHOR           => 'Webmania',
    LICENSE          => 'proprietary',
    MIN_PERL_VERSION => '5.036',
    PREREQ_PM        => {
        'IO::Socket::SSL'            => '2.099',
        'Net::SSLeay'                => '1.96',
        'XML::Parser'                => '2.47',
        'JSON::PP'                   => 0,
        'Math::BigFloat'             => 0,
        'IO::Uncompress::RawInflate' => 0,
        'Compress::Raw::Zlib'        => 0
    },
    TEST_REQUIRES => { 'Test::More' => 0 },
    PM            => \%pm,
    META_MERGE => { license => ['restricted'], no_index => { directory => [ 't', 'scripts', 'examples' ] } }
);
