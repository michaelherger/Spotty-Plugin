package Plugins::Spotty::Helper;

use strict;
use File::Slurp;
use File::Spec::Functions qw(catdir);
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use constant HELPER => 'spotty';

my $prefs = preferences('plugin.spotty');
my $log   = logger('plugin.spotty');

my ($helper, $helperVersion, $helperCapabilities, $isLowCaloriesPi);

sub init {
	# aarch64 can potentially use helper binaries from armhf
	if ( !main::ISWINDOWS && !main::ISMAC && Slim::Utils::OSDetect::details()->{osArch} =~ /^aarch64/i ) {
		Slim::Utils::Misc::addFindBinPaths(catdir(Plugins::Spotty::Plugin->_pluginDataFor('basedir'), 'Bin', 'arm-linux'));
	}

	$prefs->setChange ( sub {
		$helper = $helperVersion = $helperCapabilities = undef;

		# can't call this immediately, as it would trigger another onChange event
		Slim::Utils::Timers::setTimer(undef, time() + 1, sub {
			Plugins::Spotty::Connect->init();
		});

	}, 'helper') if !main::SCANNER;
}

sub get {
	if ( !$helper && (my $candidate = $prefs->get('helper')) ) {
		helperCheck($candidate);

		main::INFOLOG && $helper && $log->info("Using helper from prefs: $helper");
	}

	if (!$helper) {
		my $check;

		$helper = _findBin(sub {
			helperCheck(@_, \$check);
		}, 'custom-first');

		if (!$helper) {
			$log->warn("Didn't find Spotty helper application!");
			$log->warn("Last error: \n" . $check) if $check;
		}
	}

	# recommend not to use Spotty on a Pi zero/1
	if (!main::ISWINDOWS && !main::ISMAC && Slim::Utils::OSDetect::isLinux() && not defined $isLowCaloriesPi) {
		$isLowCaloriesPi = 0;
		if ($helper =~ /arm/ && -f '/proc/device-tree/model') {
			if ((read_file('/proc/device-tree/model') || '') =~ /Raspberry/si) {
				my $cpuinfo = read_file('/proc/cpuinfo') || '';
				# check revision against https://www.raspberrypi.org/documentation/hardware/raspberrypi/revision-codes/README.md
				if ($cpuinfo =~ /^Revision\s*:\s*(\b[89][0-5]\d\d[0-3569ac]\d\b|\b00[01][0-9a-f]\b)/si) {
					$log->warn(string('PLUGIN_SPOTTY_LO_POWER_PI'));
					$isLowCaloriesPi = 1;
				}
			}
		}
	}

	return wantarray ? ($helper, $helperVersion) : $helper;
}

sub getAll {
	my $candidates = {};

	my @candidates = _findBin(sub {
		my $candidate = shift;

		my $check = '';
		if ( helperCheck($candidate, \$check, 1) && $check =~ /ok spotty v([\d\.]+)/ ) {
			my $helperVersion = $1;

			$check =~ /\n(.*)/s;
			my $helperCapabilities = eval {
				from_json($1);
			};

			$candidates->{$candidate} = $helperCapabilities || { version => $helperVersion };
		}
	});

	return $candidates;
}

sub helperCheck {
	my ($candidate, $check, $dontSet) = @_;

	$$check = '' unless $check && ref $check;

	my $checkCmd = sprintf('%s -n "Spotty" --check',
		$candidate
	);

	$$check = `$checkCmd 2>&1`;

	if ( $$check && $$check =~ /^ok spotty v([\d\.]+)/i ) {
		return 1 if $dontSet;

		$helper = $candidate;
		$helperVersion = $1;

		if ( $$check =~ /\n(.*)/s ) {
			$helperCapabilities = eval {
				from_json($1);
			};

			main::INFOLOG && $log->is_info && $helperCapabilities && $log->info("Found helper capabilities table: " . Data::Dump::dump($helperCapabilities));
			$helperCapabilities ||= {};
		}

		return 1;
	}
}

sub getCapability {
	return $helperCapabilities->{$_[1]};
}

sub getVersion {
	my ($class) = @_;

	if (!$helperVersion) {
		$class->get();
	}

	return $helperVersion;
}

# custom file finder around Slim::Utils::Misc::findbin: check for multiple versions per platform etc.
sub _findBin {
	my ($checkerCb, $customFirst) = @_;

	my @candidates = (HELPER);
	my $binary;

	# trying to find the correct binary can be tricky... some ARM platforms behave oddly.
	# do some trial-and-error testing to see what we can use
	if (Slim::Utils::OSDetect::OS() eq 'unix') {
		# on 64 bit try 64 bit builds first
		if ( $Config::Config{'archname'} =~ /x86_64/ ) {
			if ($customFirst) {
				unshift @candidates, HELPER . '-x86_64';
			}
			else {
				push @candidates, HELPER . '-x86_64';
			}
		}
		elsif ( $Config::Config{'archname'} =~ /[3-6]86/ ) {
			if ($customFirst) {
				unshift @candidates, HELPER . '-i386';
			}
			else {
				push @candidates, HELPER . '-i386';
			}
		}

		# on armhf use hf binaries instead of default arm5te binaries
		# muslhf would not run on Pi1... have another gnueabi-hf for it
		elsif ( $Config::Config{'archname'} =~ /(aarch64|arm).*linux/ ) {
			if ($customFirst && $1 ne 'aarch64') {
				unshift @candidates, HELPER . '-hf', HELPER . '-muslhf';
			}
			else {
				push @candidates, HELPER . '-hf', HELPER . '-muslhf';
			}
		}
	}

	# try spotty-custom first, allowing users to drop their own build anywhere
	unshift @candidates, HELPER . '-custom';
	my $check;
	my @binaries;

	foreach (@candidates) {
		my $candidate = Slim::Utils::Misc::findbin($_) || next;

		$candidate = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($candidate);

		next unless -f $candidate && -x $candidate;

		main::INFOLOG && $log->is_info && $log->info("Trying helper application: $candidate");

		if ( !$checkerCb || $checkerCb->($candidate) ) {
			main::INFOLOG && $log->is_info && $log->info("Found helper application: $candidate");

			if (wantarray) {
				push @binaries, $candidate;
			}
			else {
				$binary = $candidate;
				last;
			}
		}
	}

	return wantarray ? @binaries : $binary;
}

sub isLowCaloriesPi {
	return $isLowCaloriesPi;
}

1;