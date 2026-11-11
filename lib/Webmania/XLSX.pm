package Webmania::XLSX;
use strict;
use warnings;
use XML::Parser 2.47;
# OPC graph design adapted from webmania-rust src/xlsx.rs (alpha5/6).
# ZIP members are inflated once by Files.pm; graph reads reuse those bytes.
my $CT='http://schemas.openxmlformats.org/package/2006/content-types';
my $REL='http://schemas.openxmlformats.org/package/2006/relationships';
my @MAIN=('http://schemas.openxmlformats.org/spreadsheetml/2006/main','http://purl.oclc.org/ooxml/spreadsheetml/main');
my @OFFICE=('http://schemas.openxmlformats.org/officeDocument/2006/relationships','http://purl.oclc.org/ooxml/officeDocument/relationships');
my $WB='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml';
my $WS='application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml';
my $RT='application/vnd.openxmlformats-package.relationships+xml';
sub bad { Webmania::Files::bad('Expected a supported coherent XLSX workbook.') }
sub check { Webmania::Transport::_check($_[0]{guard}) if $_[0]{guard} }
sub clean {my$n=shift;length($n)&&$n!~m{\A/|[\x00-\x20\\%?#:]|(?:\A|/)(?:\.?\.?)(?:/|\z)}}
sub target {
    my($base,$v)=@_;bad()if !length($v)||$v=~m{[\x00-\x20\\%?#:]|//};
    my$j=$v=~s{\A/}{}?$v:$base.$v;my@out;
    for(split m{/},$j,-1){if($_ eq'..'){bad()unless@out;pop@out}elsif($_ ne'.'){bad()unless length;push@out,$_}}
    my$r=join'/',@out;bad()unless clean($r);$r;
}
sub expand {
    my($name,$ns,$attribute)=@_;
    if($name=~/\A([^:]+):([^:]+)\z/){bad()unless exists$ns->{$1};return'{'.$ns->{$1}.'}'.$2}
    bad()if$name=~/:/;
    return !$attribute&&length($ns->{''}//'')?'{'.$ns->{''}.'}'.$name:$name;
}
sub doc {
    my($s,$name)=@_;check($s);return$s->{docs}{$name}if exists$s->{docs}{$name};
    my$raw=$s->{parts}{$name};bad()unless defined$raw&&length($raw)<=64*1024*1024;
    my(@events,@stack,@ns);my$parser=XML::Parser->new(Handlers=>{
        Doctype=>sub{bad()},Entity=>sub{bad()},ExternEnt=>sub{bad()},
        Start=>sub{
            my($p,$name,%a)=@_;check($s);bad()if@stack>=64||++$s->{nodes}>500000||keys(%a)>4096;
            my%ns=@ns?%{$ns[-1]}:('xml'=>'http://www.w3.org/XML/1998/namespace');
            for(keys%a){if($_ eq'xmlns'){$ns{''}=$a{$_};delete$a{$_}}elsif(/\Axmlns:(.+)\z/){bad()if$1 eq'xmlns';$ns{$1}=$a{$_};delete$a{$_}}}
            my$full=expand($name,\%ns,0);my%attrs;
            for(keys%a){bad()if length($a{$_})>65536;my$k=expand($_,\%ns,1);bad()if exists$attrs{$k};$attrs{$k}=$a{$_}}
            push@events,{name=>$full,a=>\%attrs,depth=>scalar@stack,parent=>@stack?$stack[-1]:''};push@stack,$full;push@ns,\%ns;
        },End=>sub{pop@stack;pop@ns},
    });
    my$ok=eval{my$p=$parser->parse_start;for(my$i=0;$i<length$raw;$i+=16384){check($s);$p->parse_more(substr($raw,$i,16384))}$p->parse_done;1};
    if(!$ok){my$e=$@;die$e if ref($e)&&eval{$e->isa('Webmania::Error')};bad()}
    bad()unless@events&&!@stack;$s->{docs}{$name}=\@events;
}
sub root {my($doc,$local,$ns)=@_;$doc->[0]{name}eq'{'.$ns.'}'.$local}
sub rels {
    my($s,$name,$base)=@_;my$d=doc($s,$name);bad()unless root($d,'Relationships',$REL);my%rels;
    for my$e(@$d[1..$#$d]){
        check($s);my$a=$e->{a};my$id=$a->{Id}//'';my$t=$a->{Type}//'';
        bad()unless $e->{depth}==1&&$e->{name}eq'{'.$REL.'}Relationship'&&($a->{TargetMode}//'Internal')eq'Internal'&&length($id)&&$id!~/\s/&&$t=~/:/&&$t!~/[\x00-\x20]/;
        my$path=target($base,$a->{Target}//'');bad()unless exists$s->{parts}{$path};bad()if exists$rels{$id};$rels{$id}=[$path,$t];
    }
    \%rels;
}
sub inspect {
    my($parts,$guard)=@_;my$s={parts=>$parts,guard=>$guard,docs=>{},nodes=>0};check($s);my%folded;
    for(keys%$parts){bad()unless clean($_)&&!$folded{lc$_}++}
    my$types=doc($s,'[Content_Types].xml');bad()unless root($types,'Types',$CT);my(%defaults,%overrides,%folded_override);
    for my$e(@$types[1..$#$types]){
        check($s);my$a=$e->{a};my$t=$a->{ContentType}//'';bad()unless$e->{depth}==1&&$t=~m{/}&&$t!~/[\x00-\x20]/;
        if($e->{name}eq'{'.$CT.'}Default'){my$ext=lc($a->{Extension}//'');bad()unless$ext=~/\A[a-z0-9]+\z/&&!exists$defaults{$ext};$defaults{$ext}=$t}
        elsif($e->{name}eq'{'.$CT.'}Override'){my$n=$a->{PartName}//'';bad()unless$n=~s{\A/}{}&&clean($n)&&exists$parts->{$n}&&!$folded_override{lc$n}++;$overrides{$n}=$t}
        else{bad()}
    }
    my$type=sub{my$n=shift;return$overrides{$n}if exists$overrides{$n};$n=~/\.([^.]*)\z/?$defaults{lc$1}:undef};
    for(keys%$parts){check($s);next if$_ eq'[Content_Types].xml';my$t=$type->($_);bad()unless defined$t;bad()if/\.rels\z/&&$t ne$RT}
    bad()unless($type->('xl/workbook.xml')//'')eq$WB;
    my$package=rels($s,'_rels/.rels','');my@office=grep{my$t=$_->[1];grep{$t eq"$_/officeDocument"}@OFFICE}values%$package;
    bad()unless@office==1&&$office[0][0]eq'xl/workbook.xml';my$workbook=doc($s,'xl/workbook.xml');my$family;
    for(0..1){$family=$_ if root($workbook,'workbook',$MAIN[$_])}bad()unless defined$family&&$office[0][1]eq$OFFICE[$family].'/officeDocument';
    my$wrels=rels($s,'xl/_rels/workbook.xml.rels','xl/');my$ns=$MAIN[$family];my$rn=$OFFICE[$family];
    my@containers=grep{$_->{name}eq"{$ns}sheets"&&$_->{depth}==1}@$workbook;bad()unless@containers==1;
    my(%ids,%rids,%names,%targets);my$sheets=0;
    for my$e(@$workbook){
        check($s);next unless$e->{name}=~/(?:\}|\A)sheet\z/;my$a=$e->{a};my$id=$a->{sheetId}//'';$id=~s/\A0+(?=[0-9])//;
        my$rid=$a->{"{$rn}id"}//'';my$name=$a->{name}//'';
        bad()unless$e->{name}eq"{$ns}sheet"&&$e->{depth}==2&&$e->{parent}eq"{$ns}sheets"&&$id=~/\A[0-9]{1,10}\z/&&$id>0&&$id<=4294967295&&length($rid)&&length($name);
        bad()if$ids{$id}++||$rids{$rid}++||$names{lc$name}++;
        my$r=$wrels->{$rid};bad()unless$r&&$r->[1]eq"$rn/worksheet"&&($type->($r->[0])//'')eq$WS&&!$targets{$r->[0]}++;
        bad()unless root(doc($s,$r->[0]),'worksheet',$ns);$sheets++;
    }
    bad()unless$sheets;
    for my$n(keys%$parts){
        check($s);if(($type->($n)//'')eq$WS){my$d=doc($s,$n);bad()unless grep{root($d,'worksheet',$_)}@MAIN}
        next unless$n=~/\.rels\z/;my$base='';
        if($n ne'_rels/.rels'){bad()unless$n=~m{\A(.*?/)?_rels/([^/]+)\.rels\z};$base=$1//'';bad()unless exists$parts->{$base.$2}}
        my$rels=rels($s,$n,$base);
        for my$r(values%$rels){for my$i(0..1){if($r->[1]eq$OFFICE[$i].'/worksheet'){bad()unless($type->($r->[0])//'')eq$WS&&root(doc($s,$r->[0]),'worksheet',$MAIN[$i])}elsif($r->[1]eq$OFFICE[$i].'/officeDocument'){bad()unless($type->($r->[0])//'')eq$WB}}}
    }
    check($s);return'xlsx';
}
1;
