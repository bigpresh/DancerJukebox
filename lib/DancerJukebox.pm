package DancerJukebox;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use Dancer::Plugin::DebugDump;
use Dancer::Plugin::MPD;
use DateTime;

our $VERSION = '0.1';

# We always want to be in repeat & random mode if we are
hook 'mpd_connected' => sub {
    if (get_enabled()) {
        my $mpd = shift;
        $mpd->repeat(1);
        $mpd->random(1);
        $mpd->play;
    }
};

get '/' => sub {
    my $current_song = mpd->current;
    if (!$current_song) {
        die "No current song!";
    }

    # TODO: This is very inefficient for a large playlist; look for a way to get
    # only the songs we want
    my @playlist = mpd->playlist->as_items;
    my @songs_around_current;
    for my $pos (
        $current_song->pos - config->{playlist}{tracks_before_current}
        ..
        $current_song->pos + config->{playlist}{tracks_after_current}
        )
    {
        if (my $song = $playlist[$pos]) {
            push @songs_around_current, $song;
        }
    }


    # See what's currently queued:
    my $queued_songs = _get_queued_songs();
    debug_dump("queued songs" => $queued_songs);

    template 'index' => {
        current => $current_song,
        playlist_snippet => \@songs_around_current,
        queued_songs => $queued_songs,
    };
};

get '/control/skip' => sub { mpd->next; redirect '/'; };

get '/control/play/:id' => sub { mpd->play(params->{id}); redirect '/'; };


# Searching support:
get '/search' => sub {
    my @results;
    if (my $search = params->{'q'}) {
        @results = mpd->collection->songs_with_filename_partial($search);
    }
    template 'search' => { results => \@results };
};

# Listing most-played songs
get '/popular' => sub {
    # TODO: configurable number of most-played songs
    # TODO: fetch title for each song (or store titles when queuing)
    my $sth = database->prepare(<<QUERY);
select path, count(*) as times_queued from queue
group by path order by times_queued desc limit 50
QUERY
    $sth->execute;
    my $popular = $sth->fetchall_arrayref({});
    debug "Popular songs: ", $popular;
    template 'popular' => { popular => $popular };
};

# Adding songs to the queue:
post '/enqueue' => sub {
    my @songs_to_queue;
    push @songs_to_queue, 
        ref params->{song} ? @{ params->{song} } : params->{song};
    debug_dump("Songs to queue: " => \@songs_to_queue);
    my $datetime = DateTime->now;
    my $queued_timestamp = join ' ', $datetime->ymd, $datetime->hms;
    database->quick_insert('queue', 
        { path => $_, queued => $queued_timestamp }
    ) for @songs_to_queue;
    redirect '/';
};

# At the moment, this is a very dumb page intended to be called from a mobile
# device to monitor the queue and dequeue anything too crap/offensive/whatever.
# In future versions, it'll probably require authentication, but no need for
# that level of complexity for a simple app I just use at parties.  I trust the
# people who could potentially access this; if I didn't, they wouldn't be in my
# house drinking my beer, so it's all good.
get '/admin' => sub {
    my $queued_songs = _get_queued_songs();    
    template 'admin', { 
        queued => $queued_songs,
        current => mpd->current,
    }, { layout => undef };
};
get '/admin/skip' => sub { mpd->next; redirect '/admin'; };


post '/admin/dequeue' => sub {
    my @dequeue_ids = ref params->{id} ? @{ params->{id} } : params->{id};
    database->quick_delete('queue', { id => $_ }) for @dequeue_ids;
    redirect '/admin';
};


get '/ajax/currentsong' => sub { 
    my $current = mpd->current;
    to_json({
        title => $current->title,
        artist => $current->artist,
    });
};

# Fetch the queued songs from the database.
sub _get_queued_songs {
    return [ database->quick_select('queue', { played => undef }) ];
}

sub get_enabled {
    my $row = database->quick_select('status', {});
    if ($row) {
        return $row->{enabled};
    } else {
        database->quick_insert('status', { enabled => 1 });
        return 1;
    }
}


# Change enabled status
any '/enabled' => sub {
    my $current_state = get_enabled();
    if (exists params->{new_state}) {
        my $new_state;
        if (params->{new_state} eq 'toggle') {
            $new_state = get_enabled() ? 0 : 1;
        } else {
            $new_state = params->{new_state} ? 1 : 0;
        }
        if ($new_state != $current_state) {
            debug "Setting enabled status to $new_state"
                . " as we got " . params->{new_state};
            database->quick_update('status', {}, { enabled => $new_state })
                or debug("FAILED to update status");
        }
    }

    return to_json { enabled => get_enabled() };
};


# Now, fork a process that will watch MPD, and, when a song is about to end, see
# if we have anything in the queue to play, and, if so, play it.  The child will
# change its name to something predictable - and we should only fork if the
# child doesn't already exist (in case we're being run by Starman or something
# so we periodically re-exec):
my $child_name = 'dancer-jukebox-queue-watcher';
my $pgrep_out = `pgrep -f $child_name`;
if ($? == 1) {
    # pgrep indicated no processes matched
    my $pid = fork();
    if (!defined $pid) {
        die "Failed to fork queue watcher";
    } elsif ($pid == 0) {
        # This code is executed by the child process
        $0 = $child_name;
        require DancerJukebox::PlayFromQueue;
        DancerJukebox::PlayFromQueue::watch_queue();
    } else {
        debug("Forked PID $pid");
    }
} else {
    debug("A process named $child_name already exists, not forking");
}


true;
