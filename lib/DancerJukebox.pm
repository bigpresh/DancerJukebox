package DancerJukebox;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use Dancer::Plugin::DebugDump;
use Dancer::Plugin::MPD;
use DateTime;

our $VERSION = '0.1';

get '/' => sub {
    my $current_song = mpd->current;
    if (!$current_song) {
        die "No current song!";
    }

    # TODO: This is very inefficient for a large playlist; look for a way to get
    # only the songs we want
    my @playlist = mpd->playlist->as_items;
    my @songs_around_current = grep { $_ } @playlist[ 
        $current_song->pos - config->{playlist}{tracks_before_current}
        ..
        $current_song->pos + config->{playlist}{tracks_after_current}
    ];

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

# Adding songs to the queue:
post '/enqueue' => sub {
    my @songs_to_queue;
    push @songs_to_queue, 
        ref params->{song} ? @{ params->{song} } : params->{song};
    debug_dump("Songs to queue: " => \@songs_to_queue);
    my $datetime = DateTime->now;
    my $queued_timestamp = join ' ', $datetime->ymd, $datetime->hms;
    my $sth = database->prepare(
        'insert into queue (path, queued) values (?,?)'
    ) or die "Database error: " . database->errstr;
    $sth->execute($_, $queued_timestamp) for @songs_to_queue;
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
    my $sth = database->prepare('delete from queue where id = ?');
    $sth->execute($_) for @dequeue_ids;
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
    my $sth = database->prepare('select * from queue where played is null');
    if (!$sth) {
        die "Database error: " . database->errstr;
    }
    $sth->execute;
    return  $sth->fetchall_arrayref({});
}


# Now, fork a process that will watch MPD, and, when a song is about to end, see
# if we have anything in the queue to play, and, if so, play it:
my $pid = fork();
if (!defined $pid) {
    die "Failed to fork queue watcher";
} elsif ($pid == 0) {
    # This code is executed by the child process
    require DancerJukebox::PlayFromQueue;
    DancerJukebox::PlayFromQueue::watch_queue();
} else {
    debug("Forked PID $pid");
}


true;
