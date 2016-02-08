#!/usr/bin/perl

use warnings;
use strict;

use IPC::Run3;
use JSON qw/from_json/;
use File::Temp qw/mktemp/;
use Data::Dumper;

use vars qw/@tempfiles $agent $rmp4/;

# params: 0 url to fetch
#         1 output file
sub curl($$) {
	my ($cmd, $stderr);
	chomp $_[0];
	$cmd = "curl -L -o '$_[1]' '$_[0]'";
	run3($cmd, \undef, \undef, \$stderr);
	if ($? != 0) {
		my $exit = $? >> 8 & 255;
		chomp $stderr;
		die ("curl failed (cmd: '$cmd', exit code $exit):\n\t'$stderr'");
		exit $exit;
	}
}

# params: 0 tempfile to extract json url from
# return    json url or undef
sub extract_json_url($) {
	my ($in, $ret);
	open $in, "<$_[0]" or die "error opening '$_[0]': $!";
	while (<$in>) {
		#if ($_ =~ /ALL.json/ and $_ !~ /EXTRAIT/) {
		if ($_ =~ /arte_vp_url_oembed/ and $_ !~ /EXTRAIT/) {
			if (($ret = $_) =~ s/.*["'](http.*?)["'].*/$1/) {
				last;
			}
		}
	}
	close $in;
	$ret;
}

# params: 0 tempfile to extract json url from
# return    json url or undef
sub extract_real_json_url($) {
	local $/ = undef;
	my ($in, $json);
	open $in, "<$_[0]" or die "error opening '$_[0]': $!";
	($json = from_json(<$in>)->{'html'}) =~ s/.*?json_url=(.*?)".*/$1/;
	close $in;
	while ($json =~ s/\%([a-fA-F0-9]{2})/pack('C', hex($1))/eg) { ; };
	$json;
}

sub sanitize_name {
	my $name = "";

	foreach (@_) {
		$name .= "" eq $name ? $_ : "_$_";
	}
	utf8::downgrade($name);
	$name =~ s/([\$()\[\]{}<>`'"-\/])/\\$1/g;
	$name =~ s|[ /]+|_|g;
	$name =~ s/_$//;
	"$name.mp4";
}

sub display_video_entry($$) {
	++$_[1];
	my $type = "" eq $_[0]->{'mediaType'} ? "http" : $_[0]->{'mediaType'};
	sprintf "% 2d: $type $_[0]->{'quality'}, ".
		"$_[0]->{'width'}x$_[0]->{'height'} $_[0]->{'bitrate'} kBit".
		" ($_[0]->{'versionLibelle'})\n", $_[1];
}

sub sort_helper($){
	$_[0]->{'width'} * $_[0]->{'height'} * $_[0]->{'bitrate'};
}

sub sort_func($$) {
	if ($_[0]->{'versionLibelle'} =~ /UT/ and $_[1]->{'versionLibelle'} =~ /UT/ or
		$_[0]->{'versionLibelle'} !~ /UT/ and $_[1]->{'versionLibelle'} !~ /UT/) {
		return sort_helper($_[0]) <=> sort_helper($_[1]);
	}
	return $_[0]->{'versionLibelle'} =~ /UT/ ? -1 : 1;
}

# params: 0 parse VSR json hash ref (for video stream selection)
#         1 http playpath ref for curl/wget
sub choose_playpath($$) {
	my ($vsr_hash, $playpath) = @_;
	my @sorted;
	foreach (sort keys %{$vsr_hash}) {
		next if $vsr_hash->{$_}->{'versionShortLibelle'} =~ /FR/i or $vsr_hash->{$_}->{'mediaType'} !~ /$rmp4/i;
		push @sorted, $vsr_hash->{$_};
	}
	@sorted = sort(sort_func @sorted);
	my $i = 0;
	foreach (@sorted) {
		print display_video_entry($_, $i);
	}
	my $sel;
	do {
		print "\nWhich one? ";
		$sel = <STDIN>;
		exit if !defined $sel;
		$sel = scalar @sorted if ($sel eq "\n");
	} while ($sel > $i or $sel < 1);
	--$sel;
	my $vformat = $sorted[$sel]->{'url'};
	if ($sorted[$sel]->{'mediaType'} ne $rmp4) {
		die "unknown videoFormat $vformat";
	}
	${$playpath} = "$sorted[$sel]->{'url'}";
	$sorted[$sel]->{'quality'}
}

# params: 0 json file to parse
#         1 playpath ref for rtmpdump
#         2 name (title) ref for video output
sub select_video($\$\$) {
	my ($tempfile, $playpath, $rflv) = @_;
	my $json;
	{
		my $in;
		open $in, "<$tempfile" or die "error opening '$tempfile': $!";
		local $/;
		$json = from_json(<$in>)->{'videoJsonPlayer'};
		close $in;
	}
	my $quality = choose_playpath($json->{'VSR'}, $playpath);
	${$rflv} = sanitize_name($json->{'VTI'}, $json->{'VPI'}, $quality);
}

sub new_tempfile($) {
	my @steps = ( "main", "json", "real_json" );
	push @tempfiles, mktemp("/tmp/tmp.$_[0].step_$steps[${\(scalar @tempfiles)}].XXXXXXXX");
	$tempfiles[scalar @tempfiles - 1];
}

sub usage($) {

	print "usage: $_[0] [-q] <url>\n";
	exit();
}

END {
	foreach my $tempfile (@tempfiles) {
		unlink($tempfile);
	}
}

(my $basename = $0) =~ s|^.*/||;
usage($basename) if (0 == scalar @ARGV);

my $dry = 0;
for my $i (0 .. scalar @ARGV - 1) {
	if ($ARGV[$i] =~ /^-d/) {
		splice @ARGV, $i, 1;
		$dry = 1;
		last;
	}
}

my %config = (
);

$agent = "User-Agent: Mozilla/5.0 (X11; Linux i686; rv:32.0) Gecko/20100101 Firefox/32.0";
$rmp4 = "mp4";
my $tempfile = new_tempfile($basename);
curl($ARGV[0], $tempfile);
my $json_url = extract_json_url($tempfile);
$tempfile = new_tempfile($basename);
curl($json_url, $tempfile);
my $real_json_url = extract_real_json_url($tempfile);
$tempfile = new_tempfile($basename);
curl($real_json_url, $tempfile);

select_video($tempfile, $config{'http'}, $config{'name'});
if (defined $config{'http'}) {
	my $cmd = "curl -C - -L -A '$agent' $config{'http'} -o $config{'name'}";
	if ($dry) {
		print $cmd
	} else {
		`$cmd`
	}
}
