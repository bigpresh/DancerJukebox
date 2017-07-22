package DancerJukebox::PlayFromQueue;

use strict;
use Dancer qw(:script);
use Dancer::Plugin::Database;
use Dancer::Plugin::DebugDump;
use Dancer::Plugin::MPD;
use DateTime;

use DancerJukebox;

sub watch_queue {
    mainloop:
    while (1) {
        warn "Loop start";
        eval {
            warn "eval start, see if enabled";
            my $enabled = DancerJukebox->get_enabled();
            if (!$enabled) {
                warn "Jukebox is curretly disabled";
                sleep 10;
                next mainloop;;
            }
            warn "Checking status.";
            my $status = mpd->status();

            if ($status->state ne 'play') {
                debug("Not currently playing; sleeping");
                sleep 10;
                next mainloop;
            }

            my $song = mpd->song;
            my $time = $status->time;


            if ($time->seconds_left < 10) {
                debug("Song change in " . $time->seconds_left . " seconds");
            } else {
                # We have a while to go, yet.
                debug("Song change in " . $time->seconds_left .
                    " seconds - no need to worry yet.");
                sleep 6;
                next mainloop;
            }

            if ($time->seconds_left <= 1) {
                debug("Song change immiment, looking for a queued entry");
                my $next = DancerJukebox::next_in_queue();
                if ($next) {
                    DancerJukebox::play_queued_song($next);
                } else {
                    # Song is about to change, and we have nothing queued
                    debug("Song change immiment, and nothing to play.");
                    sleep 10;
                    next mainloop;
                }
                sleep 10;
            } else {
                # We're close to the end of a song, but not close enough to start
                # preparing to move to the queued entry yet.
                sleep 1;
            }

            1;
        } or do {
            warn "eval failed?  $@";
            sleep 10;
        };
    }
}


1;
