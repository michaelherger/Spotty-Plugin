package Plugins::Spotty::API::RateLimit;

use strict;
use Slim::Utils::Cache;
use Slim::Utils::Log;

my $log = logger('plugin.spotty');
my $cache = Slim::Utils::Cache->new();

use constant RATE_LIMIT_RESET_KEY => 'spotty_rate_limit_reset';
use constant RATE_LIMIT_RETRY_AFTER_KEY => 'spotty_rate_limit_retry_after';
use constant RATE_LIMIT_REQUEST_QUEUE_KEY => 'spotty_rate_limit_queue';
use constant DEFAULT_RETRY_AFTER => 60;  # seconds

sub isRateLimited {
    my ($class) = @_;
    
    my $resetTime = $cache->get(RATE_LIMIT_RESET_KEY);
    
    # No limit set
    return 0 unless $resetTime;
    
    # Check if reset time has passed
    if (time() > $resetTime) {
        main::INFOLOG && $log->is_info && $log->info("Rate limit expired, clearing flag");
        $class->clearRateLimit();
        return 0;
    }
    
    # Still rate limited
    my $remaining = $resetTime - time();
    main::DEBUGLOG && $log->is_debug && $log->debug("Rate limited for another $remaining seconds");
    return 1;
}

sub setRateLimit {
    my ($class, $retryAfter) = @_;
    
    $retryAfter ||= DEFAULT_RETRY_AFTER;
    
    my $resetTime = time() + $retryAfter;
    
    # Store with TTL slightly longer than retry_after to ensure it expires
    $cache->set(RATE_LIMIT_RESET_KEY, $resetTime, $retryAfter + 10);
    $cache->set(RATE_LIMIT_RETRY_AFTER_KEY, $retryAfter, $retryAfter + 10);
    
    main::INFOLOG && $log->is_info && $log->info(
        "Rate limit set. Reset in $retryAfter seconds at " . scalar(localtime($resetTime))
    );
}

sub getRetryAfter {
    my ($class) = @_;
    
    return $cache->get(RATE_LIMIT_RETRY_AFTER_KEY) || DEFAULT_RETRY_AFTER;
}

sub getResetTime {
    my ($class) = @_;
    
    return $cache->get(RATE_LIMIT_RESET_KEY);
}

sub getRemainingSeconds {
    my ($class) = @_;
    
    my $resetTime = $class->getResetTime();
    return 0 unless $resetTime;
    
    my $remaining = $resetTime - time();
    return $remaining > 0 ? $remaining : 0;
}

sub clearRateLimit {
    my ($class) = @_;
    
    $cache->remove(RATE_LIMIT_RESET_KEY);
    $cache->remove(RATE_LIMIT_RETRY_AFTER_KEY);
    
    main::INFOLOG && $log->is_info && $log->info("Rate limit cleared");
}

sub queueRequest {
    my ($class, $requestCb) = @_;
    
    my $queue = $cache->get(RATE_LIMIT_REQUEST_QUEUE_KEY) || [];
    push @$queue, $requestCb;
    
    my $retryAfter = $class->getRetryAfter();
    $cache->set(RATE_LIMIT_REQUEST_QUEUE_KEY, $queue, $retryAfter + 10);
    
    main::DEBUGLOG && $log->is_debug && $log->debug(
        "Request queued. Queue size: " . scalar(@$queue)
    );
}

sub processQueueAfterRateLimit {
    my ($class) = @_;
    
    my $queue = $cache->get(RATE_LIMIT_REQUEST_QUEUE_KEY);
    return unless $queue && @$queue;
    
    main::INFOLOG && $log->is_info && $log->info(
        "Processing " . scalar(@$queue) . " queued requests after rate limit reset"
    );
    
    # Clear queue first
    $cache->remove(RATE_LIMIT_REQUEST_QUEUE_KEY);
    
    # Process all queued requests
    foreach my $requestCb (@$queue) {
        $requestCb->() if $requestCb;
    }
}

1;
