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
                my $next = next_in_queue();
                if (!$next) {
                    # Song is about to change, and we have nothing queued
                    debug("Song change immiment, and nothing to play.");
                    sleep 10;
                    next mainloop;
                }

                # OK - do our magic!
                debug("OK, about to add $next->{path}");
                mpd->playlist->add($next->{path});
                debug("Added $next->{path} to playlist");
                # It should be a pretty safe bet that it'll have been added at the
                # end, so find out how many tracks are now on the playlist, and
                # jump to the last:
                debug("Playlist is " . mpd->status->playlistlength
                    . " items long, so playing that -1");
                mpd->play( mpd->status->playlistlength -1 );
                mark_played($next->{id});
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

{
    my $fetch_next_sth;
    sub next_in_queue {
        # Annoyingly, the syntax to randomly select a row varies depending on
        # the DB engine:
        my %order_by_rand = (
            mysql => 'ORDER BY RAND()',
            sqlite => 'ORDER BY RANDOM()',
        );
        my $order_by;
        if (config->{random}) {
            $order_by = $order_by_rand{ lc database->{Driver}{Name} }
                or warn "Don't know how to get random rows with this"
                    . " database engine!";
        } else {
            $order_by = 'queued ASC';
        }
        $fetch_next_sth ||= database->prepare(
            "select * from queue where played is null $order_by limit 1");
        $fetch_next_sth->execute()
            or warn "Failed to execute query - " . database->errstr;
        return $fetch_next_sth->fetchrow_hashref;
    }
    my $delete_sth;
    sub mark_played {
        my $datetime = DateTime->now;
        my $datestamp = join ' ', $datetime->ymd, $datetime->hms;
        $delete_sth ||= 
            database->prepare('update queue set played = ? where id = ?');
        $delete_sth->execute($datestamp, shift)
            or warn "Failed to execute query - " . database->errstr;
        return 1;
    }
}

1;
