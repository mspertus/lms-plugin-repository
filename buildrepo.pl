#!/usr/bin/perl

use strict;

use Digest::SHA qw(sha256_hex);
use JSON;
use LWP::UserAgent;
use Storable qw(dclone);
use XML::Simple;

use constant INCLUDE_FILE => 'include.json';
use constant REPO_FILE    => 'extensions.xml';
use constant MAX_AGE      => 30 * 86400;

my $includes;

eval {
	open my $fh, '<', INCLUDE_FILE;
	$/ = undef;
	$includes = decode_json(<$fh>);
	close $fh;
} || die "$@";

my $repo = XMLin(REPO_FILE,
	SuppressEmpty => 1,
	ForceArray => [ 'applet', 'wallpaper', 'sound', 'plugin', 'patch' ],
	KeyAttr => {
		title   => 'lang',
		desc    => 'lang',
		changes => 'lang'
	},
) || {};

my $ua = LWP::UserAgent->new(
	timeout => 5,
	ssl_opts => {
		verify_hostname => 0
	}
);

$ua->agent('Mozilla/5.0, LMS buildrepo');

my $out = {
	details => {
		title => $includes->{title}
	}
};

for my $url (sort @{$includes->{repositories}}) {
	my $content;
	my $repoHash = sha256_hex($url);

	my $resp = $ua->get($url);
	if (!$resp->is_success) {

		warn "error fetching $url - " . $resp->status_line . "\n";

		if ($resp->code == 500) {
			warn "trying curl instead...\n";
			$content = `curl -m35 -L -s $url`;
			$content =~ s/^\s+|\s+$//g;
		}
	} else {
		$content = $resp->content;
	}

	print "$url\n";

	if ($content) {
		my $xml = eval { XMLin($content,
			SuppressEmpty => 1,
			KeyAttr    => [],
			ForceArray => [ 'applet', 'wallpaper', 'sound', 'plugin', 'patch' ],
		) };

		if ($@) {
			warn "bad xml ($url) $@";
			next;
		}

		processCategories(sub {
			my $item = shift;

			$item->{lastSeen} = time();
			$item->{repo} = $repoHash;

			return $item;
		}, $xml, $out);
	}
	else {
		processCategories(sub {
			my $item = shift;

			# don't use cached value if it's older than x days or from a different repository
			return if $item->{repo} ne $repoHash;

			if (($item->{lastSeen} || 0) < time() - MAX_AGE) {
				printf("  %s has not been seen for more than %i days - remove\n", $item->{name}, MAX_AGE/86400);
				return;
			}

			return $item;
		}, $repo, $out);
	}
}

XMLout($out,
	OutputFile => REPO_FILE,
	RootName   => 'extensions',
	KeyAttr    => [ 'name' ],
);

sub processCategories {
	my ($cb, $data, $out) = @_;

	for my $category (qw(applet wallpaper sound plugin patch)) {
		my $element = $category . 's';
		$element =~ s/patchs/patches/;

		for my $item (@{ $data->{$element}->{$category} || [] }) {
			if (my $newItem = $cb->(dclone($item))) {
				printf("  %s %s\n", $category, $newItem->{name});
				push @{ $out->{$element}->{$category} ||= [] }, $newItem;
			}
		}
	}
}

1;
