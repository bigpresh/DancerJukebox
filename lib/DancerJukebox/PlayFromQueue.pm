package DancerJukebox::PlayFromQueue;

use strict;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use Dancer::Plugin::DebugDump;
use Dancer::Plugin::MPD;

sub watch_queue {
    mainloop:
    while (1) {
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

    }
}

{
    my $fetch_next_sth;
    sub next_in_queue {
        $fetch_next_sth ||= database->prepare(
            'select * from queue where played is null order by id asc limit 1');
        $fetch_next_sth->execute()
            or die "Failed to execute query - " . database->errstr;
        return $fetch_next_sth->fetchrow_hashref;
    }
    my $delete_sth;
    sub mark_played {
        $delete_sth ||= 
            database->prepare('update queue set played = now() where id = ?');
        $delete_sth->execute(shift)
            or die "Failed to execute query - " . database->errstr;
        return 1;
    }
}

1;
