package Webmania::PDF;
use strict;
use warnings;
# Recognizer design adapted from webmania-rust src/pdf.rs (alpha5/6), with
# independent Perl parsing. No rendering, stream decoding, extraction or I/O.
sub fail { die "unsupported PDF structure\n" }
sub check { Webmania::Transport::_check($_[0]{guard}) if $_[0]{guard} }
sub space {
    my ($p) = @_;
    check($p);
    pos($p->{raw}) = $p->{at};
    $p->{raw} =~ /\G(?:[\x00\x09\x0a\x0c\x0d\x20]+|%[^\r\n]*)*/gc;
    $p->{at} = pos($p->{raw});
}
sub word {
    my ($p,$word) = @_;
    space($p);
    pos($p->{raw}) = $p->{at};
    if ($p->{raw} =~ /\G\Q$word\E(?=[\x00\x09\x0a\x0c\x0d\x20()<>\[\]{}\/%]|\z)/gc) {
        $p->{at} = pos($p->{raw}); return 1;
    }
    return 0;
}
sub uint {
    my ($p) = @_; space($p); pos($p->{raw})=$p->{at};
    fail() unless $p->{raw} =~ /\G([0-9]{1,12})(?=[\x00\x09\x0a\x0c\x0d\x20()<>\[\]{}\/%]|\z)/gc;
    $p->{at}=pos($p->{raw}); return 0+$1;
}
sub value {
    my ($p,$d)=@_; check($p); fail() if $d>64 || --${$p->{budget}}<0; space($p);
    my $b=substr($p->{raw},$p->{at},1); fail() unless length $b;
    if (substr($p->{raw},$p->{at},2) eq '<<') {
        $p->{at}+=2;my %v;
        while (1) {
            space($p); if(substr($p->{raw},$p->{at},2)eq'>>'){$p->{at}+=2;return ['d',\%v]}
            my $key=value($p,$d+1);fail() unless $key->[0]eq'n' && !exists$v{$key->[1]};
            $v{$key->[1]}=value($p,$d+1);
        }
    }
    if ($b eq '[') {
        $p->{at}++;my @a;
        while (1) {space($p);if(substr($p->{raw},$p->{at},1)eq']'){$p->{at}++;return ['a',\@a]}push@a,value($p,$d+1)}
    }
    if ($b eq '/') {
        $p->{at}++;pos($p->{raw})=$p->{at};$p->{raw}=~/\G([^\x00\x09\x0a\x0c\x0d\x20()<>\[\]{}\/%]*)/gc;
        my $n=$1;$p->{at}=pos($p->{raw});fail() if $n=~/#(?![0-9a-fA-F]{2})/;
        $n=~s/#([0-9a-fA-F]{2})/chr(hex($1))/ge;return ['n',$n];
    }
    if ($b eq '(') {
        $p->{at}++;my($nest,$len)=(1,0);
        while ($p->{at}<length($p->{raw})) {
            check($p) if $p->{at}%4096==0;
            my $c=substr($p->{raw},$p->{at}++,1);
            if ($c eq '\\') {
                fail() if $p->{at}>=length($p->{raw});my $e=substr($p->{raw},$p->{at}++,1);
                $p->{at}++ if $e eq "\r" && substr($p->{raw},$p->{at},1)eq"\n";
                if ($e=~/[0-7]/) {for(1..2){last unless substr($p->{raw},$p->{at},1)=~/[0-7]/;$p->{at}++}}
                $len++ unless $e eq "\r" || $e eq "\n";
            }
            elsif ($c eq '(') {fail() if ++$nest>64;$len++}
            elsif ($c eq ')') {return ['s',$len] if --$nest==0;$len++}
            else {$len++}
        }
        fail();
    }
    if ($b eq '<') {
        $p->{at}++;pos($p->{raw})=$p->{at};fail() unless $p->{raw}=~/\G([0-9a-fA-F\x00\x09\x0a\x0c\x0d\x20]*)>/gc;
        my $s=$1;$p->{at}=pos($p->{raw});$s=~s/\s|\x00//g;return ['s',int((length($s)+1)/2)];
    }
    my $start=$p->{at};
    if ($b=~/[0-9]/) {
        my($id,$g);my $ok=eval{$id=uint($p);$g=uint($p);word($p,'R') && $id>0 && $g<=65535};
        return ['r',[$id,$g]] if $ok;$p->{at}=$start;
    }
    pos($p->{raw})=$p->{at};fail() unless $p->{raw}=~/\G([^\x00\x09\x0a\x0c\x0d\x20()<>\[\]{}\/%]+)/gc;
    my $v=$1;$p->{at}=pos($p->{raw});return ['o'] if $v=~/\A(?:true|false|null)\z/;
    fail() unless length($v)<=24 && $v=~/\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z/;
    return ['real'] if index($v,'.')>=0;
    fail() if length($v)>18;return ['i',0+$v];
}
sub dict {my$v=shift;fail()unless$v&&$v->[0]eq'd';$v->[1]}
sub integer {my$v=shift;fail()unless$v&&$v->[0]eq'i';$v->[1]}
sub reference {my$v=shift;fail()unless$v&&$v->[0]eq'r';$v->[1]}
sub named {my($v,$n)=@_;$v&&$v->[0]eq'n'&&$v->[1]eq$n}
sub inspect {
    my($raw,$guard)=@_;my$budget=500000;my$p={raw=>$raw,at=>0,budget=>\$budget,guard=>$guard};check($p);
    fail() unless $raw=~/\A%PDF-(?:1\.[0-7]|2\.0)[\r\n]/ && $raw=~/startxref[\x00\x09\x0a\x0c\x0d\x20]+([0-9]{1,12})[\x00\x09\x0a\x0c\x0d\x20]+%%EOF[\x00\x09\x0a\x0c\x0d\x20]*\z/;
    my$xref=0+$1;my$tail=$-[0];my(%entries,%sections,%revisions);my($root,$encrypt,$size);my$section=$xref;
    while(1) {
        check($p);fail() if $section<9 || $section>=$tail || $revisions{$section}++ || keys(%revisions)>32;
        $p->{at}=$section;fail() unless substr($raw,$section,4)eq'xref' && word($p,'xref');my%current;
        until(word($p,'trailer')) {
            my$first=uint($p);my$count=uint($p);fail()if !$count || $first+$count>100000 || keys(%current)+$count>100000;
            for my$id($first..$first+$count-1) {
                check($p);my$off=uint($p);my$g=uint($p);my$live;
                if(word($p,'n')){$live=1}elsif(word($p,'f')){$live=0}else{fail()}
                fail()if $g>65535 || exists$current{$id} || $live&&(!$id||$g==65535||$off<9||$off>=$section);
                $current{$id}=[$off,$g,$live];
            }
        }
        my$d=dict(value($p,0));my$n=integer($d->{Size});fail()if$n<1||$n>100000||exists$d->{XRefStm};
        $size//=$n;fail()if$n>$size;
        for(keys%current){fail()if$_>=$n||!$current{$_}[2]&&$current{$_}[0]>=$n}
        $root=reference($d->{Root})if!$root&&exists$d->{Root};$encrypt=reference($d->{Encrypt})if!$encrypt&&exists$d->{Encrypt};
        space($p);$sections{$section}=$p->{at};
        if($section==$xref){fail()unless$p->{at}==$tail}else{fail()unless word($p,'startxref')&&uint($p)==$section}
        for(keys%current){$entries{$_}//=$current{$_}}fail()if keys(%entries)>100000;
        last unless exists$d->{Prev};my$prev=integer($d->{Prev});fail()if$prev<0||$prev>=$section;$section=$prev;
    }
    fail()unless $root&&$entries{0}&&!$entries{0}[2]&&$entries{0}[1]==65535;
    fail()if grep{$_>=$size}keys%entries;
    my$resolve=sub{my$r=shift;my$e=$entries{$r->[0]};fail()unless$e&&$e->[2]&&$e->[1]==$r->[1];$e};
    my(%objects,%seen);my$scanned=0;$p->{at}=0;
    while(1) {
        check($p);space($p);last if$p->{at}==length$raw;
        if(exists$sections{$p->{at}}){my$s=$p->{at};fail()if$seen{$s}++;$p->{at}=$sections{$s};fail()unless word($p,'startxref')&&uint($p)==$s;next}
        my$start=$p->{at};my$id=uint($p);my$g=uint($p);fail()if !$id||$id>=100000||$g>=65535||++$scanned>100000||!word($p,'obj');
        my$v=value($p,0);my$d=$v->[0]eq'd'?$v->[1]:undef;
        fail()if$d&&(named($d->{Type},'XRef')||named($d->{Type},'ObjStm')||exists$d->{Linearized});
        if(word($p,'stream')) {
            fail()unless$d;my$l=$d->{Length};my$n;
            if($l&&$l->[0]eq'i'){$n=$l->[1]}
            else {my$r=reference($l);my$e=$resolve->($r);my$q={%$p,at=>$e->[0]};fail()unless uint($q)==$r->[0]&&uint($q)==$r->[1]&&word($q,'obj');$n=integer(value($q,0));fail()unless word($q,'endobj')}
            fail()if$n<0||$n>length$raw;
            if(substr($raw,$p->{at},1)eq"\r"){$p->{at}++;$p->{at}++if substr($raw,$p->{at},1)eq"\n"}
            elsif(substr($raw,$p->{at},1)eq"\n"){$p->{at}++}else{fail()}
            $p->{at}+=$n;fail()if$p->{at}>length$raw;fail()unless word($p,'endstream');$v=['stream',$d];
        }
        fail()unless word($p,'endobj');
        if(my$e=$entries{$id}){if($e->[2]&&$e->[0]==$start){fail()if$e->[1]!=$g||exists$objects{$id};$objects{$id}=$v}}
    }
    fail()unless keys(%seen)==keys(%sections);for(keys%entries){fail()if$entries{$_}[2]&&!exists$objects{$_}}
    my$direct=sub{my$v=shift;fail()unless$v;if($v->[0]eq'r'){$resolve->($v->[1]);return$objects{$v->[1][0]}}$v};
    # Validate reference generations in every parsed dictionary/array; stream data
    # remains opaque and cannot manufacture object headers or references.
    my@work=values%objects;my$walked=0;
    while(my$v=pop@work){check($p);fail()if++$walked>500000;if($v->[0]eq'r'){$resolve->($v->[1])}elsif($v->[0]eq'd'||$v->[0]eq'stream'){push@work,values%{$v->[1]}}elsif($v->[0]eq'a'){push@work,@{$v->[1]}}}
    my$catalog=dict($direct->(['r',$root]));fail()unless named($catalog->{Type},'Catalog');my$pages=reference($catalog->{Pages});my%visited;my$count;
    $count=sub{
        my($r,$parent,$box,$resources,$depth)=@_;check($p);fail()if$depth>64||$visited{join ':',@$r}++;
        my$d=dict($direct->(['r',$r]));
        if($parent){my$pr=reference($d->{Parent});fail()unless join(':',@$pr)eq join(':',@$parent)}else{fail()if exists$d->{Parent}}
        $box=$d->{MediaBox}//$box;$resources=$d->{Resources}//$resources;
        if(named($d->{Type},'Page')){fail()unless$parent;my$b=$direct->($box);fail()unless$b->[0]eq'a'&&@{$b->[1]}==4;for(@{$b->[1]}){my$t=$direct->($_);fail()unless$t->[0]eq'i'||$t->[0]eq'real'}dict($direct->($resources));return 1}
        fail()unless named($d->{Type},'Pages')&&$d->{Kids}&&$d->{Kids}[0]eq'a';my$total=0;for(@{$d->{Kids}[1]}){$total+=$count->(reference($_),$r,$box,$resources,$depth+1)}fail()unless integer($d->{Count})==$total;return$total;
    };
    my$ok=eval{$count->($pages,undef,undef,undef,0);1};my$err=$@;undef$count;die$err unless$ok;
    if($encrypt){my$d=dict($direct->(['r',$encrypt]));fail()unless named($d->{Filter},'Standard')&&integer($d->{V})==1&&integer($d->{R})==2;integer($d->{P});for(qw(O U)){fail()unless$d->{$_}&&$d->{$_}[0]eq's'&&$d->{$_}[1]>=32}fail()if exists$d->{Length}&&integer($d->{Length})!=40;return'protected_pdf'}
    check($p);return'pdf';
}
1;
