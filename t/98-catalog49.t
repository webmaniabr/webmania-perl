use strict;use warnings;use Test::More;use Webmania;use lib 't/lib';use TestServer;
sub fixture {open my$f,'<:raw','t/fixtures/catalog49/'.$_[0]or die$!;local$/;<$f>}
sub file {Webmania::Files::result(200,$_[1],$_[0],[$_[1]])}
sub reject {my($raw,$media,$name)=@_;my$ok=eval{file($raw,$media);1};ok(!$ok&&ref($@)eq'Webmania::Error',$name)}
my$plain=fixture('canonical-plain.pdf');my$protected=fixture('canonical-protected.pdf');
is(file($plain,'application/pdf')->bytes,$plain,'canonical plain exact');is(file($protected,'application/pdf')->kind,'protected_pdf','canonical R2 protected');
reject("%PDF-1.4\n%%EOF\n",'application/pdf','marker-only PDF refused');
my$bad=$plain;$bad=~s/startxref\s+\d+/startxref\n1/;reject($bad,'application/pdf','physical startxref required');
reject(fixture('pdf-dangling-resource-coherent-xref.pdf'),'application/pdf','coherent xref dangling resources refused');
sub pdf {
 my@v=@_;my$raw="%PDF-1.4\n";my@off=(0);for my$i(0..$#v){push@off,length$raw;$raw.=($i+1)." 0 obj\n$v[$i]\nendobj\n"}my$x=length$raw;$raw.="xref\n0 ".(@v+1)."\n0000000000 65535 f \n";for(@off[1..$#off]){$raw.=sprintf("%010d 00000 n \n",$_)}$raw.='trailer' . "\n<< /Size ".(@v+1)." /Root 1 0 R >>\nstartxref\n$x\n%%EOF\n";$raw;
}
my$stream='99 0 obj /Encrypt 99 0 R endobj';my@v=('<< /Type /Catalog /Pages 2 0 R /Note (xref 99 0 R) >>','<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 72 72] /Resources << >> >>','<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>','<< /Length '.length($stream).' >>' . "\nstream\n$stream\nendstream");
my$opaque=pdf(@v);is(file($opaque,'application/pdf')->bytes,$opaque,'streams and strings opaque; inherited resources valid');
$v[2]='<< /Type /Page /Parent 2 0 R /Contents 4 1 R >>';reject(pdf(@v),'application/pdf','reference generation checked');
my$m='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
for(qw(canonical-workbook.xlsx xlsx-eight-sheets-eight-parts.xlsx xlsx-one-used-part-eight-relations.xlsx xlsx-two-parts-valid-ids.xlsx xlsx-root-parent-positive.xlsx)){my$b=fixture($_);is(file($b,$m)->bytes,$b,"coherent XLSX $_ exact")}
for(qw(xlsx-numeric-duplicate-ids.xlsx xlsx-duplicate-names.xlsx xlsx-duplicate-rids.xlsx xlsx-overflow-id.xlsx xlsx-wrong-worksheet-namespace.xlsx xlsx-wrong-sheet-parent.xlsx xlsx-wrong-relationship-type.xlsx xlsx-unsafe-internal-target.xlsx)){reject(fixture($_),$m,"invalid XLSX $_ refused")}
my$uuid='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';my$body={uuid=>$uuid,motivo=>'Finite catalog49 reason'};
for my$tail("10\r\n", "2\r\nx", "bogus\r\n", "2\r\n{}xx"){
 my$s=TestServer->new(["HTTP/1.1 503 Failure\r\nTransfer-Encoding: chunked\r\nX-Correlation-ID: ordinary-id\r\n\r\n$tail"]);my$e;eval{$s->pool->{Nfe}->cancel_document(body=>$body,options=>{max_response_bytes=>8});1}or$e=$@;
 ok(ref($e)eq'Webmania::Error','early chunk failure structured');is($e->outcome,'unknown','sent mutation uncertain');ok(!defined$e->correlation_id&&!defined$e->recovery,'incomplete chunk framing suppresses metadata');is(scalar@{$s->records},1,'early chunk failure one request');$s->stop;
}
my$s=TestServer->new([TestServer::response('0123456789',503,'text/plain','X-Correlation-ID: useful-id')]);my$e;eval{$s->pool->{Nfe}->cancel_document(body=>$body,options=>{max_response_bytes=>8});1}or$e=$@;ok($e->correlation_id eq'useful-id'&&$e->recovery,'nonchunked body limit retains useful metadata');$s->stop;
for my$loc('/r;token=matrix-secret49','/r#token=fragment-secret49','/r?x=visible%26token=encoded-secret49'){
 my$secret=$loc=~/matrix/?'matrix-secret49':$loc=~/fragment/?'fragment-secret49':'encoded-secret49';
 $s=TestServer->new([TestServer::response({error=>$secret},503,'application/json',"Location: $loc")]);eval{$s->pool->{Nfe}->get_sefaz_status;1}or$e=$@;is($e->details->{error},'[redacted]','native Location lexical assignment observed');is(scalar@{$s->records},1,'Location no transfer');$s->stop;
}
my$r=Webmania::Redactor->new(['xABA1234']);$r->observe_location('/r;token=abc');is($r->text('prefixxABA1234suffix abc alphabetabc ABC'),'prefix[redacted]suffix [redacted] alphabetabc ABC','strong configured literal and short observed boundaries');
$r=Webmania::Redactor->new;$r->observe_location('/r;token=%FF');is($r->text(chr(0xfffd)),chr(0xfffd),'invalid decoded UTF8 creates no replacement secret');
$s=TestServer->new([TestServer::response({error=>'temporarily unavailable'},503)]);my$f=$s->pool->{NfeFiles};eval{$f->download_report(uuid=>$uuid,auth=>Webmania::FileAuth->new(mode=>'capability'));1}or$e=$@;is($e->outcome,'unknown','quota-consuming report GET uncertain');ok(!exists$s->records->[0]{headers}{'x-consumer-key'}&&!exists$s->records->[0]{headers}{authorization},'report GET has no service credentials');is(scalar@{$s->records},1,'report GET never replayed');$s->stop;
# Cooperative checks are bounded synchronous checks, not a hard realtime promise.
my$cancel=Webmania::Cancel->new;$cancel->cancel;my$ctx={options=>{cancel=>$cancel},deadline=>Webmania::Transport::now()+1};eval{Webmania::Files::result(200,'application/pdf',$plain,['application/pdf'],$ctx)};$e=$@;is($e->kind,'cancelled','preinspection cancellation preserved');
$ctx={options=>{},deadline=>Webmania::Transport::now()-1};eval{Webmania::Files::result(200,$m,fixture('canonical-workbook.xlsx'),[$m],$ctx)};$e=$@;is($e->kind,'timeout','preinspection deadline preserved');
done_testing;
