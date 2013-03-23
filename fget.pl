#!/usr/bin/perl

use IPC::Run3;
use strict;
use warnings;
use vars qw/%entities $agent $loghandle $success $tempfile/;

use Data::Dumper;

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
$agent = exists $ENV{'AGENT'} ? $ENV{'AGENT'} : "Mozilla/5.0 (X11; Linux i686; rv:15.0) Gecko/20121212 Firefox/15.0";

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
		#print "xxx: streams: $streams\n";
		# determination of first value
		(my $split_str = $streams) =~ s/^(.*?)\s*=.*$/$1/;
		$split_str = quotemeta($split_str);
		#print "xxx: split_str: $split_str\n";
		# split by first value (sort of)
		$streams =~ s/,\s*$split_str=/\n$split_str=/g;
		my $m = 0;
		foreach my $stream (split /\n/, $streams) {
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
			++$m;
		}
	}
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
# ret:	stream selected by user
sub select_stream($) {
	my ($stream_ref) = @_;

	my $i = 1;
	foreach my $stream (@{$stream_ref}) {
		my $info = info_from_type($stream->{'type'});
		printf "%-3s %-7s ($info)\n", "$i:", $stream->{'quality'};
		++$i;
	}
	my $sel;
	do {
		print "\nWhich one? ";
		$sel = <STDIN>;
		$sel = 1 if ($sel eq "\n");
	} while ($sel >= $i or $sel < 1);
	# - 1 is due to our one based array presentation
	$sel - 1
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

# download the 'source' html file from hash_ref to 'tempfile'
# in:	source url of the file to be downloaded
# ret:	name of the temporarily created download file
sub download_html($) {
	my ($source) = @_;
	chomp (my $tempfile = `mktemp`);
	mylog("downloading '%s' to '%s':", $source, $tempfile);

	my $cmd = "wget --no-check-certificate -S -U '$agent' -O '$tempfile' '$source'";
	mylog("	'%s'", $cmd);
	my $stderr = "";
	run3($cmd, \undef, \undef, \$stderr);
	mylog("\tresponded with \n%s\n", $stderr);
	die ("invalid exit code of wget ($cmd): " . ($? & 127)) if ($? != 0);
	$tempfile
}

# perform download of the stream referenced by the hash ref with the given title
# in:	hash reference of the selected source stream
sub x($$) {
	my ($ref, $title) = @_;
	my ($ext, undef, undef) = info_from_type($ref->{'type'});
	$ext =~ s/\W//g;
	$ext = "flv" if ($ext eq "xflv");

	my @cmd = ("wget", "-S", "-c", "-U", $agent, "-O", "$title.$ext", "$ref->{'__url'}");
	mylog("downloading file to '%s'\nusing command '%s':", $title.$ext, @cmd);
	#my $stderr = "";
	#run3($cmd, undef, undef, \$stderr);
	#mylog("\tresponded with \n%s\n", $stderr);
	run3 \@cmd, undef, undef, undef;
	return 0 == $? ? 1 : 0;
}

# initialize working hash (i.e. empty it out except for regexps and quiet)
# NOTE: inefficient code!
sub init_hash(\%) {
	my ($hash_ref) = @_;

	foreach my $key (keys %{$hash_ref}) {
		next if ($key =~ /^(regexps|quiet|log)$/);
		delete $hash_ref->{$key};
	}
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
	print "usage: get_flash_vid [-q|+q] <URL> [[-q|+q] <URL> ...]\n";
	exit(defined $_[0] ? $_[0] : 0);
}

# push array elements to loghandle, passing them to sprintf before
# in:	message to push to $loghandle
sub mylog(@) {
	push @{$loghandle}, sprintf(shift, @_);
}

sub log_spill() {
	local $" = "\n";
	print "@{$loghandle}\n";
}

sub main(@) {
	my @args = @_;

	$success = 0;
	help() if (0 == scalar @args);

	my %hash = (
		'regexps'	=> {
			'streams'		=> 'yt\.playerConfig\s?=',
			'altstreams'	=> 'url_encoded_fmt_stream_map',
			'title'			=> '<title>.*?</\s*title>'
		},
		'tempfile'	=> "",
		'source'	=> "",
		'log'		=> [],
		'quiet'		=> 0,
	);

	$loghandle = $hash{'log'};

	my $stdin = 0;
	if ($args[0] eq "-c") {
		shift @args;
		$stdin = 1;
	}
	my $args = get_args($stdin, @args);

	while (my $var = $args->()) {
		init_hash(%hash);
		if ($var =~ /^([-+])q$/) {
			$hash{'quiet'} = $1 eq "+" ? 0 : 1;
			mylog("quiet mode set to '%s' (%s)", ($hash{'quiet'} ? "on" : "off"), $1);
			next;
		}
		$hash{'source'} = $var;
		mylog("processing file '%s'", $hash{'source'});
		$tempfile = $hash{'tempfile'} = download_html($hash{'source'});
		extract_lines($hash{'tempfile'}, %{$hash{'regexps'}}, %hash);
		$hash{'title'} = get_title($hash{$hash{'regexps'}->{'title'}});
		mylog("title extracted from title line is '%s'", $hash{'title'});
		@{$hash{'streams'}} = get_streams($hash{$hash{'regexps'}->{'streams'}}, qr/":\s*"/, qr/"[,}]/);
		if (0 == scalar @{$hash{'streams'}}) {
			# TODO: alternate start and end required
			@{$hash{'streams'}} = get_streams($hash{$hash{'regexps'}->{'altstreams'}}, '":\s*"', qr/"[,}]/);
			die "No valid streams found in file, exiting!"
		}
		$hash{'id'} = $hash{'quiet'} ? 0 : select_stream($hash{'streams'});
		$hash{'streams'}->[$hash{'id'}]->{'__url'} = assemble_url($hash{'streams'}->[$hash{'id'}]);
		$success = x($hash{'streams'}->[$hash{'id'}], $hash{'title'});
	}
}

#Referer: http://s.ytimg.com/yts/swfbin/watch_as3_hh-vfleHfpd4.swf
#"url": "http:\/\/s.ytimg.com\/yts\/swfbin\/watch_as3_hh-vfleHfpd4.swf"
main(@ARGV);

END {
	log_spill() if (!$success);
	#unlink($tempfile) if (defined $tempfile);
}
