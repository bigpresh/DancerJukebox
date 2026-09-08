package DancerJukebox;
use Carp;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use Dancer::Plugin::MPD;
use DateTime;

our $VERSION = '0.1';

# Cap on how many search results we'll render at once. A broad search against a
# few thousand songs otherwise builds a page big enough to make a phone crawl.
use constant MAX_SEARCH_RESULTS => 200;

# How much the front page shows before sending you off to a full listing.
# Both can be overridden via the "home" section of config.yml.
use constant DEFAULT_HOME_QUEUE   => 5;
use constant DEFAULT_HOME_POPULAR => 10;

# How many songs the full /popular chart lists.
use constant POPULAR_CHART_SIZE => 50;

# We always want to be in repeat & random mode if we are
hook 'mpd_connected' => sub {
    if (get_enabled()) {
        my $mpd = shift;
        $mpd->repeat(1);
        $mpd->random(1);
        $mpd->play;
    }
};

# Every page shows the now-playing bar and the on/off switch, so rather than
# each route remembering to pass them, fill them in for all templates.
# Everything in here is best-effort: if MPD has gone away we still want to
# render a usable page rather than a 500.
hook 'before_template_render' => sub {
    my $tokens = shift;
    $tokens->{current} = _current_summary() unless exists $tokens->{current};
    $tokens->{enabled} = get_enabled() ? 1 : 0;
    $tokens->{state}   = _mpd_state();
    $tokens->{page} ||= '';
};

# The front page guests see: what's coming up, an obvious way to queue
# something, and a shortcut to the crowd-pleasers.
get '/' => sub {
    my $queued = _get_queued_songs();
    my $limit  = config->{home}{queued_songs} || DEFAULT_HOME_QUEUE;

    # Only the next few, so the page stays short on a phone; the count tells
    # people how many more are behind them.
    my @next_up = @$queued;
    splice @next_up, $limit if @next_up > $limit;

    template 'index' => {
        page         => 'home',
        queued_songs => \@next_up,
        queued_total => scalar @$queued,
        queue_limit  => $limit,
        popular      => _popular_songs(
            config->{home}{popular_songs} || DEFAULT_HOME_POPULAR
        ),
    };
};


get '/control/skip' => sub {
    if (my $song = next_in_queue()) {
        play_queued_song($song);
    } else {
        mpd->next;
    }
    return _json({ ok => 1 }) if _wants_json();
    redirect '/';
};

get '/control/play/:id' => sub { mpd->play(params->{id}); redirect '/'; };


# Searching support:
get '/search' => sub {
    my $query = params->{'q'};
    my @results;
    my $truncated = 0;

    if (defined $query && length $query) {
        # Search titles, artists, albums and filenames. People at a party type
        # "queen" or "dancing" - matching only the filename (as this used to)
        # misses anything whose tags are better than its file naming.
        my %seen;
        for my $method (qw(
            songs_with_title_partial
            songs_by_artist_partial
            songs_from_album_partial
            songs_with_filename_partial
        )) {
            my @found = eval { mpd->collection->$method($query) };
            if ($@) {
                debug "Search via $method failed: $@";
                next;
            }
            for my $song (@found) {
                next unless $song;
                next if $seen{ $song->file }++;
                push @results, _song_summary($song);
            }
        }

        @results = sort {
            lc($a->{artist} // '') cmp lc($b->{artist} // '')
                ||
            lc($a->{display_title}) cmp lc($b->{display_title})
        } @results;

        if (@results > MAX_SEARCH_RESULTS) {
            $truncated = scalar @results;
            @results = @results[0 .. MAX_SEARCH_RESULTS - 1];
        }
    }

    template 'search' => {
        page      => 'search',
        query     => $query,
        results   => \@results,
        truncated => $truncated,
    };
};

# Listing most-played songs
get '/popular' => sub {
    template 'popular' => {
        page    => 'popular',
        popular => _popular_songs(POPULAR_CHART_SIZE),
    };
};

# The most-queued songs, decorated with their real title/artist rather than
# the raw path we store. Shared by the front page and the full chart.
sub _popular_songs {
    my $limit = shift || DEFAULT_HOME_POPULAR;

    my $sth = database->prepare(<<'QUERY');
select path, count(*) as times_queued from queue
group by path order by times_queued desc limit ?
QUERY
    $sth->execute($limit);
    my $popular = $sth->fetchall_arrayref({});

    _decorate_row($_) for @$popular;
    return $popular;
}

# Adding songs to the queue:
post '/enqueue' => sub {
    my @songs_to_queue = grep { defined $_ && length $_ }
        ref params->{song} ? @{ params->{song} } : params->{song};

    if (!@songs_to_queue) {
        return _json({ ok => 0, error => 'No song given' }) if _wants_json();
        return redirect '/search';
    }

    debug "Songs to queue: ", \@songs_to_queue;
    my $datetime = DateTime->now;
    my $queued_timestamp = join ' ', $datetime->ymd, $datetime->hms;
    database->quick_insert('queue',
        { path => $_, queued => $queued_timestamp }
    ) for @songs_to_queue;

    if (_wants_json()) {
        return _json({ ok => 1, queued => scalar @songs_to_queue });
    }

    # Without JS, send them back where they came from so they can carry on
    # picking songs instead of losing their search results.
    redirect _safe_referer() || '/';
};

# At the moment, this is a very dumb page intended to be called from a mobile
# device to monitor the queue and dequeue anything too crap/offensive/whatever.
# In future versions, it'll probably require authentication, but no need for
# that level of complexity for a simple app I just use at parties.  I trust the
# people who could potentially access this; if I didn't, they wouldn't be in my
# house drinking my beer, so it's all good.
get '/admin' => sub {
    template 'admin', {
        page   => 'admin',
        queued => _get_queued_songs(),
    }, { layout => undef };
};

post '/admin/dequeue' => sub {
    my @dequeue_ids = grep { defined $_ && length $_ }
        ref params->{id} ? @{ params->{id} } : params->{id};
    database->quick_delete('queue', { id => $_ }) for @dequeue_ids;
    redirect '/admin';
};


# Everything the UI needs to keep itself up to date, in one request: what's
# playing, how far through it is, whether the jukebox is enabled, and the
# current queue. The front end polls this every few seconds.
get '/ajax/status' => sub {
    my %status = (
        enabled => get_enabled() ? 1 : 0,
        state   => _mpd_state(),
        current => _current_summary(),
        elapsed => 0,
        total   => 0,
        percent => 0,
        queue   => [
            map { {
                id     => $_->{id},
                path   => $_->{path},
                title  => $_->{display_title},
                artist => $_->{artist},
            } } @{ _get_queued_songs() }
        ],
    );

    if (my $time = eval { mpd->status->time }) {
        $status{elapsed} = $time->sofar_secs || 0;
        $status{total}   = $time->total_secs || 0;
        $status{percent} = $status{total}
            ? int(($status{elapsed} / $status{total}) * 100) : 0;
    }

    return _json(\%status);
};

# Kept for anything already pointed at it; /ajax/status supersedes it.
get '/ajax/currentsong' => sub {
    my $current = _current_summary();
    return _json({
        title  => $current ? $current->{display_title} : undef,
        artist => $current ? $current->{artist} : undef,
    });
};

# Fetch the queued songs from the database, decorated with the song's real
# title and artist so the UI doesn't have to show a raw file path.
sub _get_queued_songs {
    my @queued = database->quick_select(
        'queue', { played => undef }, { order_by => 'queued' }
    );
    _decorate_row($_) for @queued;
    return \@queued;
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

    return _json({ enabled => get_enabled() ? 1 : 0 });
};


sub play_queued_song {
    my $song = shift;

    if (!$song || !ref $song || !$song->{path}) {
        carp "play_queued_song called without a song to add";
        return;
    }


    # OK - do our magic!
    debug("OK, about to add $song->{path}");
    mpd->playlist->add($song->{path});
    debug("Added $song->{path} to playlist");
    # It should be a pretty safe bet that it'll have been added at the
    # end, so find out how many tracks are now on the playlist, and
    # jump to the last:
    debug("Playlist is " . mpd->status->playlistlength
        . " items long, so playing that -1");
    mpd->play( mpd->status->playlistlength -1 );
    mark_played($song->{id});
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


### Helpers used by the routes above ########################################

# Serialise a response as JSON, with the right content type.
sub _json {
    my $data = shift;
    content_type 'application/json';
    return to_json($data);
}

# Did this request come from our JavaScript (rather than a plain form post or
# a browser following a link)?  If so it wants JSON back, not a redirect.
sub _wants_json {
    return 1 if params->{ajax};
    my $requested_with = request->header('X-Requested-With') || '';
    return lc($requested_with) eq 'xmlhttprequest' ? 1 : 0;
}

# The path part of the referring URL, but only if it's one of ours - so we
# never bounce someone off to an external site we were linked from.
sub _safe_referer {
    my $referer = request->referer or return;
    my $host = request->host or return;
    my ($path) = $referer =~ m{^https?://\Q$host\E(/.*)$};
    return $path;
}

sub _mpd_state {
    my $state = eval { mpd->status->state };
    return $state || 'stop';
}

# What's playing right now, as a plain hashref (so templates and JSON can
# treat it the same way), or undef if nothing is.
# Note the explicit "return undef": a bare "return" would yield an empty list
# when called in list context, which quietly eats the next key of any hash
# we're assigned into.
sub _current_summary {
    my $song = eval { mpd->current } or return undef;
    my $summary = _song_summary($song);
    $summary->{pos} = $song->pos;
    return $summary;
}

# Boil an Audio::MPD song object down to the handful of fields the UI wants,
# always with something sensible to display as a title.
sub _song_summary {
    my ($song, $fallback_path) = @_;
    my $path = $song ? $song->file : $fallback_path;

    my %info = (
        path   => $path,
        file   => $path,
        title  => ($song && $song->title)  ? $song->title  : undef,
        artist => ($song && $song->artist) ? $song->artist : undef,
        album  => ($song && $song->album)  ? $song->album  : undef,
    );
    $info{display_title} = (defined $info{title} && length $info{title})
        ? $info{title}
        : _prettify_path($path);

    return \%info;
}

# Copy a song's metadata onto a database row (which only stores the path).
sub _decorate_row {
    my $row = shift or return;
    my $info = _song_info($row->{path});
    $row->{$_} = $info->{$_} for qw(title artist album display_title);
    return $row;
}

{
    # The queue and the popular list ask about the same paths over and over,
    # and every lookup is a round trip to MPD, so remember what we're told.
    my %song_cache;

    sub _song_info {
        my $path = shift;
        return _song_summary(undef, $path) unless defined $path && length $path;
        return $song_cache{$path} if exists $song_cache{$path};

        # Don't let a long-running process grow this without bound.
        %song_cache = () if keys %song_cache > 5_000;

        my $song = eval { mpd->collection->song($path) };
        return $song_cache{$path} = _song_summary($song, $path);
    }
}

# Last resort when a song has no title tag: make its filename presentable
# rather than showing a full path to a party full of people.
sub _prettify_path {
    my $path = shift;
    return 'Unknown track' unless defined $path && length $path;

    my ($name) = $path =~ m{([^/]+)/*$};
    return 'Unknown track' unless defined $name && length $name;

    $name =~ s/\.[a-z0-9]{2,4}$//i;      # drop the file extension
    $name =~ s/^\s*\d+\s*[-._ ]+\s*//;   # drop a leading track number
    $name =~ tr/_/ /;
    $name =~ s/\s+/ /g;
    $name =~ s/^\s+|\s+$//g;

    return length $name ? $name : 'Unknown track';
}

true;
