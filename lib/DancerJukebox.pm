package DancerJukebox;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use Dancer::Plugin::DebugDump;
use Dancer::Plugin::MPD;


our $VERSION = '0.1';

get '/' => sub {
    my $current_song = mpd->current;
    if (!$current_song) {
        die "No current song!";
    }

    # TODO: This is very inefficient for a large playlist; look for a way to get
    # only the songs we want
    my @playlist = mpd->playlist->as_items;
    my @songs_around_current = @playlist[ 
        $current_song->pos - config->{playlist}{tracks_before_current}
        ..
        $current_song->pos + config->{playlist}{tracks_after_current}
    ];

    # See what's currently queued:
    my $sth = database->prepare('select * from queue where played is null');
    $sth->execute;
    my $queued_songs = $sth->fetchall_arrayref({});
    debug_dump("queued songs" => $queued_songs);
    template 'index' => {
        current => $current_song,
        playlist_snippet => \@songs_around_current,
        queued_songs => $queued_songs,
    };
};

get '/skipnext' => sub { mpd->next; redirect '/'; };

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
    my $sth = database->prepare(
        'insert into queue (path, queued) values (?, now())'
    );
    $sth->execute($_) for @songs_to_queue;
    redirect '/';
};


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
