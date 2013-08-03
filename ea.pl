#!/usr/bin/perl

use warnings;
use strict;

use IPC::Run3;
use JSON qw/from_json/;
use File::Temp qw/mktemp/;
use Data::Dumper;

use vars qw/@tempfiles/;

sub make_rtmp_command(\%) {
	my $cmd = "";

	foreach my $key (keys %{$_[0]}) {
		if ('binary' eq $key) {
			$cmd = "$_[0]->{$key} \\\n" . $cmd;
		} else {
			$cmd .= ("" eq $cmd ? "" : " \\\n") . "	--$key $_[0]->{$key}";
		}
	}
	$cmd .= "\n";
}

# params: 0 url to fetch
#         1 output file
sub curl($$) {
	my ($cmd, $stderr);
	$cmd = "curl -o '$_[1]' '$_[0]'";
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
		if ($_ =~ /ALL.json/ and $_ !~ /EXTRAIT/) {
			if (($ret = $_) =~ s/.*"(http.*?)".*/$1/) {
				last;
			}
		}
	}
	close $in;
	$ret;
}

sub sanitize_name {
	my $name = "";

	foreach (@_) {
		$name .= "" eq $name ? $_ : "_$_";
	}
	utf8::downgrade($name);
	$name =~ y/- |\/\\/_/;
	$name =~ s/_+/_/g;
	"$name.mp4";
}

sub display_video_entry($$) {
	++$_[1];
	my $type = "" eq $_[0]->{'mediaType'} ? "http" : $_[0]->{'mediaType'};
	sprintf "% 2d: $type $_[0]->{'quality'}, ".
		"$_[0]->{'width'}x$_[0]->{'height'} $_[0]->{'bitrate'} kBit".
		" ($_[0]->{'versionLibelle'})\n", $_[1];
}

# params: 0 parse VSR json hash ref (for video stream selection)
#         1 playpath ref for rtmpdump
sub choose_playpath($$) {
	my @sorted;
	foreach (sort keys %{$_[0]}) {
		next if $_[0]->{$_}->{'versionLibelle'} =~ /frz/i or $_ =~ /REACH/;
		push @sorted, $_[0]->{$_};
	}
	my $i = 0;
	foreach (@sorted) {
		print display_video_entry($_, $i);
	}
	my $sel;
	do {
		print "\nWhich one? ";
		$sel = <STDIN>;
		exit if !defined $sel;
		$sel = scalar @sorted - 1 if ($sel eq "\n");
	} while ($sel >= $i or $sel < 1);
	${$_[1]} = "\"mp4:$sorted[$sel]->{'url'}\"";
	$sorted[$sel]->{'quality'}
}

# params: 0 json file to parse
#         1 playpath ref for rtmpdump
#         2 flv (title) ref for video output
sub select_video($\$\$) {
	my $json;
	{
		my $in;
		open $in, "<$_[0]" or die "error opening '$_[0]': $!";
		local $/;
		$json = from_json(<$in>)->{'videoJsonPlayer'};
		close $in;
	}
	#print Dumper($json);
	#exit (0);
	my $quality = choose_playpath($json->{'VSR'}, $_[1]);
	${$_[2]} = sanitize_name($json->{'VTI'}, $json->{'VPI'}, $quality);
}

sub new_tempfile($) {
	my @steps = ( "main", "json" );
	push @tempfiles, mktemp("/tmp/tmp.$_[0].step_$steps[${\(scalar @tempfiles)}].XXXXXXXX");
	$tempfiles[scalar @tempfiles - 1];
}

END {
	foreach my $tempfile (@tempfiles) {
		unlink($tempfile);
	}
}

my %config = (
	'resume'   => '',
	'binary'   => 'rtmpdump',
	'app'      => 'a3903/o35/',
	'swfUrl'   => 'http://www.arte.tv/player/v2//jwplayer6/mediaplayer.6.3.3242.swf',
	'flashVer' => 'LNX 11,2,202,236',
);
$config{'rtmp'} = "rtmp://artestras.fcod.llnwd.net/$config{'app'}";
$config{'tcUrl'} = "$config{'rtmp'}";
$config{'swfVfy'} = "$config{'swfUrl'}";

(my $basename = $0) =~ s|^.*/||;
my $tempfile = new_tempfile($basename);
curl($ARGV[0], $tempfile);
my $json_url = extract_json_url($tempfile);
$tempfile = new_tempfile($basename);
curl($json_url, $tempfile);

select_video($tempfile, $config{'playpath'}, $config{'flv'});
my $cmd = make_rtmp_command(%config);
`$cmd`
