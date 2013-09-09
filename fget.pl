#!/usr/bin/perl

use IPC::Run3;
use strict;
use warnings;
use vars qw/%entities $loghandle $success $tempfile/;

%entities = (
	'quot'		=> '"',		'apos'		=> '\'',		'amp'		=> '&',
	'lt'		=> '<',		'gt'		=> '>',			'nbsp' 		=> ' ',
	'iexcl' 	=> '¡',		'cent' 		=> '¢',			'pound' 	=> '£',
	'curren'	=> '¤',		'yen' 		=> '¥',			'brvbar'	=> '¦',
	'sect' 		=> '§',		'uml' 		=> '¨',			'copy' 		=> '©',
	'ordf' 		=> 'ª',		'laquo' 	=> '«',			'not' 		=> '¬',
	'shy' 		=> '­',		'reg' 		=> '®',			'macr' 		=> '¯',
	'deg' 		=> '°',		'plusmn'	=> '±',			'sup2' 		=> '²',
	'sup3' 		=> '³',		'acute' 	=> '´',			'micro' 	=> 'µ',
	'para' 		=> '¶',		'middot'	=> '·',			'cedil' 	=> '¸',
	'sup1' 		=> '¹',		'ordm' 		=> 'º',			'raquo' 	=> '»',
	'frac14'	=> '¼',		'frac12'	=> '½',			'frac34'	=> '¾',
	'iquest'	=> '¿',		'times' 	=> '×',			'divide'	=> '÷',
);

# un-entityize a given html named entity
# in:	html named entity (name/number of entity)
# ret:	char representation or "" if not found/mapped
sub unent($) {
	my ($str) = @_;

	if ($str =~ s/^#([0-9]+)$//) {
		return pack('c', $1);
	} elsif (defined $entities{$str}) {
		return $entities{$str};
	}

	return "";
}

# take given string an return the urldecoded version of it
# NOTE: performs decoding to the bone, i.e if the first urldecoding
# turns into a string which represents an urlencoded character, too
# then this one is also decoded and so forth
# in:	urlencoded string
# ret:	urldecoded string
sub urldecode($) {
	my ($str) = @_;
	while ($str =~ s/\%([a-fA-F0-9]{2})/pack('C', hex($1))/eg) { ; };
	$str
}

# decodes unicode characters found in input string to it's unicode
# representation
# in:	unicode encoded string
# ret:	unidecoded string
sub unidecode($) {
	my ($str) = @_;
	$str =~ s/\\u([a-fA-F0-9]{4})/pack('C', hex($1))/eg;
	$str
}

# extract all lines from file matching any regex in regexps
# in:	file to read,
# 		reference to regexps to put into array (only values are used)
# out: 	reference to line array
# ret:	nothing
sub extract_lines($\%\%) {
	my ($file, $regexps, $arrayref) = @_;

	open(F, "<$file") || die "Unable to open input file $file: $!";
	while (<F>) {
		# process each regex with each line which may match more than one pattern
		foreach my $pattern (values %{$regexps}) {
			if ($_ =~ /$pattern/) {
				chomp $_;
				push(@{$arrayref->{$pattern}}, $_);
				mylog("found 1 item matching pattern '%s' (%s ...)", $pattern,
					 substr($_, 0, 20));
			}
		}
	}
	close F;
}

# extract and purify title from file
# in:	reference to array of title line(s)
# ret:	purified title or "untitled" if no appropriate title could be found
sub get_title($) {
	my ($title_ref) = @_;

	foreach my $str (@{$title_ref}) {
		$str =~ s|.*?<title>(.*?)</title>.*|$1|;	# title tag's value extraction
		$str =~ s/ - youtube$//i;					# snip off youtube at the end of title
		$str =~ s|&(.*?);|unent($1)|eg;				# replace/wipe all named entities
		$str =~ tr| /()-|_|;						# transliterate all 'ugly' char to '_'
		$str =~ s|_+|_|g;							# replace multiple '_'-occurences
		$str =~ s|_$||;								# replace traling '_' character

		# if we have a decent length drop all other titles
		return $str if (length($str) > 0);
	}
	"untitled"
}

# get streams sorted out in a good way
# in:	reference to array of stream line(s)
#		chars following url_encoded_fmt_stream_map token
#		chars following the urls encoded
sub get_streams($$$) {
	my ($stream_ref, $start, $end) = @_;
	my @streams;

	foreach my $streams (@{$stream_ref}) {
		# extract value from line
		$streams =~ s|^.*url_encoded_fmt_stream_map$start(.*?)$end.*$|$1|;
		# unicode and url decoding
		$streams = unidecode($streams);
		$streams = urldecode($streams);
		mylog("found streams: '%s...%s'", substr($streams, 0, 10),
				substr($streams, length($streams) - 10));
		# determination of first value
		(my $split_str = $streams) =~ s/^(.*?)\s*=.*$/$1/;
		$split_str = quotemeta($split_str);
		mylog("split string is: '%s'", $split_str);
		# split by first value (sort of)
		$streams =~ s/,\s*$split_str=/\n$split_str=/g;
		my $m = 0;
		foreach my $stream (split /\n/, $streams) {
			mylog("[#%02u] processing: '%s...%s'", $m + 1,
					substr($stream, 0, 10),
					substr($stream, length($stream) - 10));
			$streams[$m]->{'__order'} = "";
			$stream =~ s/\?/&/;
			# loop all key value pairs
			foreach my $kvp (split /&/, $stream) {
				if ($kvp =~ /([a-z_]+)=(.*)/) {
					next if exists $streams[$m]->{$1};
					$streams[$m]->{'__order'} .= "$1,";
					$streams[$m]->{$1} = $2;
				}
			}
			{
				local $/ = ",";
				chomp $streams[$m]->{'__order'};
			}
			mylog("[#%02u] key order: '%s'", $m + 1,
					$streams[$m]->{'__order'});
			++$m;
		}
	}
	mylog("found %d streams", scalar @streams);
	@streams
}

# retrieve mime type and, if present audio and video format from type value
# in:	value of the type parameter found in stream info
# ret:	array -- if wanted -- with mime-subtype (the actual type stripped off)
# 		followed by audio and video information if present; if no array is
# 		desired, a string is returned which reads like this: "subtype [ac/vc]"
sub info_from_type($) {
	my ($str) = @_;

	if ($str =~ /^.*\/([0-9a-zA-Z_\-]+);\+codecs="(.+),\+?(.+)"/) {
		return wantarray ? ($1, $2, $3) : "$1 $2/$3";
	} elsif ($str =~ /^.*\/([0-9a-zA-Z_\-]+)/) {
		return $1;
	}

	return "???";
}

# function takes all streams found, displays all quality and mime type infos
# and asks user which stream is desired
# in:	array ref with stream information
# in:	[optional] preferred itag values for automated download
# ret:	stream selected by user
sub select_stream($;$) {
	my ($stream_ref, $itags) = @_;
	my $info;

	if (defined $itags) {
		my ($i, %streams);
		$i = 0;
		foreach my $stream (@{$stream_ref}) {
			$streams{$stream->{'itag'}} = $i++;
		}
		foreach my $itag (@{$itags}) {
			if (exists $streams{$itag}) {
				$i = $streams{$itag};
				$info = sprintf("itag % 2u: ", $stream_ref->[$i]->{'itag'}) .
					info_from_type($stream_ref->[$i]->{'type'});
				printf("auto-selected stream %-3s %-7s ($info)\n",
						"${\($i+1)}:", $stream_ref->[$i]->{'quality'});
				mylog("auto-selected stream %-3s %-7s ($info)\n",
						"${\($i+1)}:", $stream_ref->[$i]->{'quality'});
				return $i;
			}
		}
	} else {
		my $selections = "";
		my $i = 1;
		foreach my $stream (@{$stream_ref}) {
			$info = sprintf("itag % 2u: ", $stream->{'itag'}) . info_from_type($stream->{'type'});
			$selections .= sprintf("%-3s %-7s ($info)\n", "$i:", $stream->{'quality'});
			++$i;
		}
		print $selections;
		my $sel;
		do {
			print "\nWhich one? ";
			$sel = <STDIN>;
			exit if !defined $sel;
			$sel = 1 if ($sel eq "\n");
		} while ($sel >= $i or $sel < 1);
		# - 1 is due to our one based array presentation
		$sel - 1
	}
}

# assemble a wget-compatible url from a selected stream; all values found
# in $ref->{'__order'} are concatenated excluding all elements in $skip
# and giving special treatment to $ref->{'url'} and  $ref->{'sig'};
# in:	hash ref to a selected stream
# ret:	assembled url
sub assemble_url($) {
	my ($ref) = @_;
	my $skip = qr/\b(url|fallback_host|quality|type|sig)\b/;
	my @values;

	foreach my $key (split /,/, $ref->{'__order'}) {
		if ($key =~ /$skip/) {
			next;
		}
		push @values, "$key=$ref->{$key}"
	}
	my $url = $ref->{'url'} . "?" . (join '&', @values) . "&signature=" . $ref->{'sig'};
	$url =~ s/,/%2C/g;
	$url
}

# download the source html file from downloader to outfile
# in:	http downloading object
#		scalar ref to outfile
sub download_html($$) {
	my ($downloader, $outfile) = @_;
	chomp (${$outfile} = `mktemp -t tmp.fget.XXXXXXXX`);

	my $cmd = $downloader->();
	mylog("	'%s'", $cmd);
	my $stderr = "";
	# for curl, response header are written to stdout :/
	run3($cmd, \undef, \$stderr, \$stderr);
	mylog("\tresponded with \n%s\n", $stderr);
	die ("invalid exit code of $downloader ($cmd): " . ($? & 127)) if ($? != 0);
}

# perform download of the stream referenced by the hash ref using the downloader
# in:	http downloading object
#		hash reference of the selected source stream
#		scalar ref to outfile
sub download_video($$$) {
	my ($downloader, $ref, $outfile) = @_;
	my ($ext, undef, undef) = info_from_type($ref->{'type'});
	$ext =~ s/\W//g;
	$ext = "flv" if ($ext eq "xflv");

	${$outfile} .= ".$ext";
	my $cmd = $downloader->();
	printf("downloading file to '%s'\n", ${$outfile});
	mylog("downloading file to '%s'\nusing command '%s':", ${$outfile}, $cmd);
	my $stdout = "";
	run3($cmd, \undef, \$stdout, undef);
	mylog("\tresponded with \n%s\n", $stdout);
	return 0 == $? ? 1 : 0;
}

# initialize working hash (i.e. empty it out except for regexps and quiet)
sub init_hash($) {
	my ($log) = @_;
	(
		'regexps'	=> {
			'steams'	=> 'url_encoded_fmt_stream_map',
			'title'		=> '<title>.*?</\s*title>'
		},
		'log'		=> $log,
		'quiet'		=> 0,
		'preferred'	=> [ 44, 45, 84, 46, 37, 38, 85, 43, 82, 83, 22, 35, 18, 34, 6, 5, 13, 36, 17, 137, 136, 135, 134, 133, 160, 141, 140, 139, 102, 101, 100, 85, 84, 83, 82 ],
	);
}

sub get_args($@) {
	my ($stdin, @param) = @_;

	return sub {
		my $ret;

		$ret = shift @param if (scalar @param);

		if ($stdin && !defined $ret) {
			$ret = <STDIN>;
			chomp $ret if (defined $ret);
		}

		return $ret;
	};
}

# print out a little help text and then exit with the given exit code
# in:	optional exit code of the function, if exit value is supposed to
# 		to be <> 0
sub help(;$) {
	print "usage: fget COMMAND\n";
	print "            COMMAND := {SWITCH | url}\n";
	print "            SWITCH  := [ -q | +q ] # disable/enable quiet mode\n";
	exit(defined $_[0] ? $_[0] : 0);
}

# push array elements to loghandle, passing them to sprintf before
# in:	message to push to $loghandle
sub mylog(@) {
	push @{$loghandle}, sprintf(shift, @_);
}

# verify the availability of the http downloader (currently wget)
# in:	downloader command
# out:	boolean representing existence of the http downloader
sub verify_downloader($) {
	run3("$_[0] -h", \undef, \undef, undef, { 'return_if_system_error' => 1 });
	return -1 != $?
}

sub log_spill() {
	local $" = "\n";
	print "@{$loghandle}\n" if defined $loghandle;
}

sub downloader($) {
	my ($downloader) = @_;
	verify_downloader($downloader->{'binary'}) or die
		"http downloader $downloader->{'binary'} missing: $!\n";
	return sub {
		my $binary = $downloader->{'binary'};
		if ("curl" eq $binary) {
			my $extra = " ";
			$extra .= "-C - " if ("download_video" eq ${$downloader->{'operation'}});
			# --no-check-certificate <-> --insecure?
			"$binary --cookie-jar /dev/null -L -D -$extra" .
				"-A '$downloader->{'agent'}' " .
				"-o '${$downloader->{'outfile'}}' " .
				"'${$downloader->{'source'}}'";
		} elsif ("wget" eq $binary) {
			my $extra = " ";
			$extra .= "-c " if ("download_video" eq ${$downloader->{'operation'}});
			"$binary --no-cookies --no-check-certificate -S$extra" .
				"-U '$downloader->{'agent'}' " .
				"-O '${$downloader->{'outfile'}}' " .
				"'${$downloader->{'source'}}'";
		}
	}
}

sub f($) {
	print ref $_[0];
}

sub main(@) {
	my @args = @_;
	my $agent = exists $ENV{'AGENT'} ? $ENV{'AGENT'} : "Mozilla/5.0 (X11; Linux i686; rv:23.0) Gecko/20100101 Firefox/23.0";
	my ($operation, $outfile, $source);
	$tempfile = \$outfile;
	my $downloader = downloader({
		"binary"    => "curl",
		"agent"     => $agent,
		"operation" => \$operation,
		"outfile"   => \$outfile,
		"source"    => \$source,
	});

	$success = 0;
	help() if (0 == scalar @args);

	my %hash = init_hash(undef);
	$loghandle = $hash{'log'};

	my $stdin = 0;
	my $itag;
	while ($args[0] =~ /-[pic]/) {
		if ($args[0] eq "-p") {
			shift @args;
			$itag = $hash{'preferred'}
		} elsif ($args[0] eq "-i") {
			shift @args;
			push @{$itag}, shift @args or die "-i used without an argument";
		} elsif ($args[0] eq "-c") {
			$stdin = 1;
			shift @args;
		}
		last if (0 == scalar @args);
	}
	my $args = get_args($stdin, @args);

	my $var = $args->();
	while ($var or $var = $args->()) {
		my @tmp = split /\s+/, $var;
		my $v = shift @tmp;
		$tempfile = \$outfile;
		%hash = init_hash($loghandle);
		$var = join " ", @tmp;
		if ($v =~ /^([-+])q$/) {
			$hash{'quiet'} = $1 eq "+" ? 0 : 1;
			mylog("quiet mode set to '%s' (%s)", ($hash{'quiet'} ? "on" : "off"), $1);
			next;
		}
		$source = $v;
		mylog("processing file '%s'", $source);
		$operation = "download_html";
		download_html($downloader, \$outfile);
		extract_lines($outfile, %{$hash{'regexps'}}, %hash);
		$hash{'title'} = get_title($hash{$hash{'regexps'}->{'title'}});
		mylog("title extracted from title line is '%s'", $hash{'title'});
		@{$hash{'streams'}} = get_streams($hash{$hash{'regexps'}->{'steams'}}, '":\s*"', qr/"[,}]/);
		if (0 == scalar @{$hash{'streams'}}) {
			die "No valid streams found in file, exiting!"
		}
		$hash{'id'} = $hash{'quiet'} ? 0 : select_stream($hash{'streams'}, $itag);
		$hash{'streams'}->[$hash{'id'}]->{'__url'} = assemble_url($hash{'streams'}->[$hash{'id'}]);
		unlink(${$tempfile}) if (defined ${$tempfile});
		$tempfile = undef;
		$operation = "download_video";
		$outfile = $hash{'title'};
		$source = $hash{'streams'}->[$hash{'id'}]->{'__url'};
		$success = download_video($downloader, $hash{'streams'}->[$hash{'id'}], \$outfile);
		$operation = $outfile = $source = undef;
	}
}

main(@ARGV);
END {
	log_spill() if (!$success);
	unlink(${$tempfile}) if (defined ${$tempfile});
}
