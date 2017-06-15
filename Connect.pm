package Plugins::Spotty::Connect;

use strict;

use Slim::Utils::Prefs;
use Slim::Utils::Timers;

sub init {
	my ($class, $helper) = @_;
# TODO - needs to be renamed, as "spotty" is being used by OPMLBased
#                                                                |requires Client
#                                                                |  |is a Query
#                                                                |  |  |has Tags
#                                                                |  |  |  |Function to call
#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch(['spotty'],
	                                                            [1, 0, 0, sub {
																	my $request = shift;
																	my $client = $request->client();
																	
																	# check buffer usage - no need to skip if buffer is empty
																	my $usage = $client->usage;
													
																	if ( $usage && $client->can('skipAhead') ) {
														#				Slim::Utils::Timers::killTimers($client, \&_skipAhead);
														#				Slim::Utils::Timers::setHighTimer($client, Time::HiRes::time() + 1, \&_skipAhead, $usage);
																		$client->flush();
																	}

																	$request->setStatusDone();
	                                                            }]);


	my $flushBuffer = Slim::Utils::Misc::findbin('flushbuffers') || '';
	my $serverPort = preferences('server')->get('httpport');
	
	foreach ( keys %Slim::Player::TranscodingHelper::commandTable ) {
		if ( $flushBuffer && $_ =~ /^sptc-/ ) {
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/\$FLUSHBUFFERS\$/$flushBuffer/g;
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/\$SERVERPORT\$/$serverPort/g;
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/\[spotty\]/\[$helper\]/g if $helper;
		}
	}
}

sub _skipAhead {
	my ($client, $usage) = @_;
	$client->execute(["mixer", "muting", 1]);
	my $bitrate = $client->streamingSong()->streambitrate();
	#my $bufferSize = $client->bufferSize;		# bytes?
	my $delta = $client->bufferSize * 8 / $bitrate * $usage * 2;
																		
#	warn Data::Dump::dump($bitrate, $client->bufferSize, $usage, $delta);
	$client->skipAhead($delta);
	$client->execute(["mixer", "muting", 0]);
}


1;