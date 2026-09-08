package DancerJukebox;
use Carp;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use Dancer::Plugin::MPD;
use DateTime;
use Digest::MD5 qw(md5_hex);
use File::Path qw(make_path);
use File::Spec;

our $VERSION = '0.1';

# Cap on how many search results we'll render at once. A broad search against a
# few thousand songs otherwise builds a page big enough to make a phone crawl.
use constant MAX_SEARCH_RESULTS => 200;

# Shorter than this and a search matches so much of a decent-sized library
# that MPD hits its output buffer limit and drops the connection. ("a" against
# ~49k songs does exactly that.)
use constant MIN_SEARCH_LENGTH => 3;


# How much the front page shows before sending you off to a full listing.
# Both can be overridden via the "home" section of config.yml.
use constant DEFAULT_HOME_QUEUE   => 5;
use constant DEFAULT_HOME_POPULAR => 10;

# How many songs the full /popular chart lists.
use constant POPULAR_CHART_SIZE => 50;

# How many songs one person may have *waiting* at any one time. Counting
# pending rather than lifetime is the whole point: if you queue three and wait
# for one to play, you can add another. So somebody on their own can keep the
# queue topped up all evening, but nobody can stack fifty and leave everyone
# else's choices with no look-in. Set to 0 in config.yml for no limit.
use constant DEFAULT_QUEUE_LIMIT => 5;

# Identifies a guest between requests. A cookie rather than an IP address:
# phones change address when they roam between access points or renew a lease,
# and if a reverse proxy is ever put in front of the app every guest would
# share one address, so the first person to hit the limit would lock out the
# whole party. Someone who clears their cookies gets another go - this is a
# politeness mechanism, not access control.
use constant GUEST_COOKIE => 'jukebox_guest';

# Visiting /admin sets this, and it exempts the browser from the per-person
# limit - so you can queue freely from your own phone without the allowance
# getting in your way. Forgeable, of course, but so is finding /admin in the
# first place: same trust model, and there's a link there to drop it again.
use constant ADMIN_COOKIE => 'jukebox_admin';

# We always want to be in repeat & random mode if we are
hook 'mpd_connected' => sub {
    my $mpd = shift;
    return unless get_enabled();

    $mpd->repeat(1);
    $mpd->random(1);

    # Only start playback if it isn't already going. This hook fires on every
    # *re*connect, not just the first one - and an unusually broad search can
    # make MPD drop the connection, so an unconditional play() here meant a
    # guest's search could jump the track everyone was listening to.
    my $state = eval { $mpd->status->state } || '';
    $mpd->play if $state ne 'play';
};

# Make sure everyone has an identity and the queue table has somewhere to
# record it, before anyone tries to queue anything.
hook 'before' => sub {
    _ensure_schema();
    _guest_id();
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

    # So pages can show how much of your allowance is left, and warn you when
    # a no-JS queue attempt bounced off it.
    my $limit = _is_exempt() ? 0 : _queue_limit();
    $tokens->{admin_exempt} = _is_exempt();
    $tokens->{queue_limit_per_person} = $limit;
    $tokens->{your_pending} = $limit ? _pending_count_for(_guest_id()) : 0;
    $tokens->{queue_full} = params->{queue_full} ? 1 : 0;
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
    # Stripped, not rejected: a stray control character pasted into the box
    # shouldn't fail the search, it just mustn't reach MPD.
    my $query = _mpd_arg_clean(params->{'q'});
    my @results;
    my $truncated = 0;
    my $too_short = 0;

    if (defined $query && length $query && length $query < MIN_SEARCH_LENGTH) {
        $too_short = 1;
    }
    elsif (defined $query && length $query) {
        # Search titles, artists, albums and filenames. People at a party type
        # "queen" or "dancing" - matching only the filename (as this used to)
        # misses anything whose tags are better than its file naming.
        #
        # Ordered cheapest-and-most-relevant first, and we stop as soon as
        # we've got a page's worth: filename in particular matches enormously
        # on a big library (every path contains "the"), and a big enough
        # result set makes MPD hit its output buffer and drop the connection.
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
            last if @results >= MAX_SEARCH_RESULTS;
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
        page       => 'search',
        query      => $query,
        results    => \@results,
        truncated  => $truncated,
        too_short  => $too_short,
        min_length => MIN_SEARCH_LENGTH,
    };
};


# Browsing curated collections, for "I don't know what to search for, but I
# fancy some 80s music" - which in practice means wanting the hits, not a
# random sample of everything released that decade. The collections are just
# directories in the library (the NOW series, Mastermix, and so on), so discs
# and per-year sub-folders are walked automatically and adding a new album
# needs no configuration.
get '/browse' => sub {
    my $collections = _browse_collections();
    my $path = params->{path};

    # No path (or a path we don't recognise): offer the top-level collections.
    my $root = $path ? _browse_root_for($path) : undef;
    if (!$root) {
        return template 'browse' => {
            page        => 'browse',
            collections => $collections,
        };
    }

    my (@folders, @songs);
    my @items = eval { mpd->collection->items_in_dir($path) };
    if ($@) {
        debug "Couldn't list '$path': $@";
    }

    for my $item (@items) {
        if ($item->isa('Audio::MPD::Common::Item::Directory')) {
            push @folders, {
                path => $item->directory,
                name => _basename($item->directory),
            };
        } elsif ($item->isa('Audio::MPD::Common::Item::Song')) {
            push @songs, _song_summary($item);
        }
    }

    template 'browse' => {
        page        => 'browse',
        collections => $collections,
        root        => $root,
        path        => $path,
        crumbs      => _browse_crumbs($root, $path),
        parent      => _browse_parent($root, $path),
        folders     => \@folders,
        songs       => \@songs,
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
    my @songs_to_queue = grep { defined $_ && length $_ && _mpd_arg_ok($_) }
        ref params->{song} ? @{ params->{song} } : params->{song};

    if (!@songs_to_queue) {
        return _json({ ok => 0, error => 'No song given' }) if _wants_json();
        return redirect '/search';
    }

    # Hold people to a few songs at a time, so one enthusiast can't bury
    # everyone else's choices.
    my $guest = _guest_id();
    my $limit = _is_exempt() ? 0 : _queue_limit();
    my $pending = $limit ? _pending_count_for($guest) : 0;

    if ($limit && $pending >= $limit) {
        my $error = "You've already got $pending songs waiting."
            . " Hang on until one of them plays, then pick another.";
        if (_wants_json()) {
            return _json({
                ok => 0, error => $error, limit => $limit,
                # +0 because interpolating $pending into $error above set its
                # string flag, and JSON would then emit "5" rather than 5.
                pending => $pending + 0,
            });
        }
        return redirect _with_param(_safe_referer() || '/', queue_full => 1);
    }

    # Never let one request take someone past their allowance
    if ($limit) {
        my $room = $limit - $pending;
        splice @songs_to_queue, $room if @songs_to_queue > $room;
    }

    debug "Songs to queue: ", \@songs_to_queue;
    my $datetime = DateTime->now;
    my $queued_timestamp = join ' ', $datetime->ymd, $datetime->hms;
    database->quick_insert('queue', {
        path      => $_,
        queued    => $queued_timestamp,
        queued_by => $guest,
        ip        => request->address,
    }) for @songs_to_queue;

    if (_wants_json()) {
        return _json({
            ok      => 1,
            queued  => scalar @songs_to_queue,
            limit   => $limit,
            pending => $pending + @songs_to_queue,
        });
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
    # Being here is enough to mark this browser as yours, so the per-person
    # queue limit stops applying to it.
    set_cookie(ADMIN_COOKIE, 1, expires => '1 year', path => '/');
    var admin_exempt => 1;

    template 'admin', {
        page   => 'admin',
        queued => _get_queued_songs(),
    }, { layout => undef };
};

# For when a guest has wandered in here and picked up the exemption, or you
# just want to queue under the same rules as everyone else.
get '/admin/normal-limits' => sub {
    set_cookie(ADMIN_COOKIE, '', expires => '-1d', path => '/');
    var admin_exempt => 0;
    # Back to the guest side, not /admin - landing there would just hand the
    # exemption straight back.
    redirect '/';
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
        yours   => {
            pending => _is_exempt() ? 0 : _pending_count_for(_guest_id()),
            limit   => _is_exempt() ? 0 : _queue_limit(),
        },
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

    if (!_mpd_arg_ok($song->{path})) {
        carp "Refusing to play queued song with an unsafe path";
        mark_played($song->{id});
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

sub _with_param {
    my ($url, $key, $value) = @_;
    my $join = $url =~ /\?/ ? '&' : '?';
    return "$url$join$key=$value";
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

        # A row stored before this check existed could still hold one
        my $song = _mpd_arg_ok($path)
            ? eval { mpd->collection->song($path) }
            : undef;
        return $song_cache{$path} = _song_summary($song, $path);
    }
}

### Talking to MPD safely ###################################################

# MPD's protocol is line-based, and Audio::MPD escapes only double quotes when
# it builds a command - not newlines. So a value containing one ends the
# command and starts another: searching for "queen\nkill\n" shuts the server
# down, and a crafted path stored in the queue re-fires every time the queue
# is rendered. Nothing derived from user input may reach MPD without passing
# through here.
sub _mpd_arg_ok {
    my $value = shift;
    return 0 unless defined $value;
    return 0 if $value =~ /[\x00-\x1f\x7f]/;
    return 1;
}

# For free-text where silently dropping the odd stray character beats refusing
# the whole request.
sub _mpd_arg_clean {
    my $value = shift;
    return $value unless defined $value;
    $value =~ s/[\x00-\x1f\x7f]//g;
    return $value;
}


### Telling guests apart ####################################################

# A stable per-browser id. Set once and remembered for the request, so calling
# this more than once in a request gives the same answer even on the first
# visit (when the cookie only exists on the way back out).
sub _guest_id {
    return vars->{guest_id} if vars->{guest_id};

    my $cookie = cookies->{ +GUEST_COOKIE };
    my $id = $cookie ? scalar $cookie->value : undef;

    if (!defined $id || $id !~ /^[0-9a-f]{32}$/) {
        $id = _random_id();
        set_cookie(GUEST_COOKIE, $id, expires => '1 year', path => '/');
    }

    var guest_id => $id;
    return $id;
}

sub _random_id {
    my $bytes;
    if (open my $fh, '<:raw', '/dev/urandom') {
        read $fh, $bytes, 16;
        close $fh;
    }
    if (!defined $bytes || length $bytes != 16) {
        # Plenty good enough for telling party guests apart
        $bytes = pack 'N4', map { int rand 2**32 } 1 .. 4;
    }
    return unpack 'H*', $bytes;
}

sub _is_exempt {
    return vars->{admin_exempt} if defined vars->{admin_exempt};
    my $cookie = cookies->{ +ADMIN_COOKIE };
    my $exempt = ($cookie && $cookie->value) ? 1 : 0;
    var admin_exempt => $exempt;
    return $exempt;
}

sub _queue_limit {
    my $limit = config->{max_queued_per_person};
    $limit = DEFAULT_QUEUE_LIMIT unless defined $limit;
    # Numeric, not the string YAML handed us: it ends up in JSON, and "0"
    # is perfectly truthy in JavaScript.
    return $limit + 0;
}

# How many songs this person has waiting. Played ones don't count, so an
# allowance frees itself up as their choices come round.
sub _pending_count_for {
    my $guest = shift;
    return 0 unless defined $guest && length $guest;

    my $sth = database->prepare(
        'select count(*) from queue where played is null and queued_by = ?');
    $sth->execute($guest);
    my ($count) = $sth->fetchrow_array;
    # Numeric for the same reason the limit is: this ends up in JSON.
    return ($count || 0) + 0;
}

# Older installs won't have the columns we record the queuer in. Adding them
# is additive and safe - existing rows get NULL, and count as nobody's.
{
    my $checked;
    sub _ensure_schema {
        return if $checked;
        $checked = 1;

        my $have = eval {
            my $sth = database->prepare('select * from queue where 1 = 0');
            $sth->execute;
            my %cols = map { lc $_ => 1 } @{ $sth->{NAME_lc} || [] };
            $sth->finish;
            \%cols;
        };
        if (!$have) {
            warning "Couldn't inspect the queue table: $@";
            return;
        }

        for my $column (qw(queued_by ip)) {
            next if $have->{$column};
            debug "Adding '$column' column to the queue table";
            eval { database->do("alter table queue add column $column text"); 1 }
                or warning "Couldn't add '$column' to the queue table: $@";
        }
    }
}


### Cover art ###############################################################

# Cover art filenames worth showing, best first. Anything matching "back" is
# skipped explicitly - plenty of these albums ship a Back.jpg too, and a grid
# of back covers is no use to anyone.
use constant COVER_NAMES => [qw(
    cover folder front albumart album art
)];
use constant COVER_EXTENSIONS => [qw(jpg jpeg png gif)];

# Shown whenever an album has no usable artwork of its own.
use constant NO_COVER_IMAGE => '/images/no-cover.svg';

# Serve a thumbnail of an album's cover.
#
# Originals here average ~400KB and run to several MB, so a grid of eighty of
# them would be a punishing download on a phone. We shrink each one once and
# cache it on disk; after that it's a static file.
get '/cover' => sub {
    my $path = params->{path};

    # Only inside a configured collection - same rule as browsing. Anything
    # else falls through to the placeholder rather than erroring, so the grid
    # never shows a broken image.
    my $root = $path ? _browse_root_for($path) : undef;
    my $source = $root ? _find_cover($path) : undef;

    return send_file(NO_COVER_IMAGE) if !$source;

    my $thumb = _cover_thumbnail($source);
    return send_file($thumb || $source, system_path => 1);
};


# Locate the best cover image inside a library directory. Looks in the
# directory itself, then one level down, so an album whose art lives in
# Disc1/ still shows something.
{
    my %cover_cache;

    sub _find_cover {
        my $path = shift;
        return $cover_cache{$path} if exists $cover_cache{$path};

        my $dir = _library_path($path);
        return $cover_cache{$path} = undef unless defined $dir && -d $dir;

        my $found = _best_image_in($dir);

        if (!$found) {
            # Try one level down (discs, etc), in directory order so it's
            # stable between requests.
            opendir my $dh, $dir or return $cover_cache{$path} = undef;
            my @subdirs = sort grep { !/^\./ && -d File::Spec->catdir($dir, $_) }
                readdir $dh;
            closedir $dh;
            for my $sub (@subdirs) {
                $found = _best_image_in(File::Spec->catdir($dir, $sub));
                last if $found;
            }
        }

        return $cover_cache{$path} = $found;
    }
}

sub _best_image_in {
    my $dir = shift;
    opendir my $dh, $dir or return undef;
    my @files = grep { !/^\./ } readdir $dh;
    closedir $dh;

    my %by_name;
    for my $file (@files) {
        my ($stem, $ext) = $file =~ /^(.+)\.([^.]+)$/ or next;
        next unless grep { lc $ext eq $_ } @{ +COVER_EXTENSIONS };
        next if $stem =~ /back/i;      # skip back covers
        push @{ $by_name{ lc $stem } }, $file;
    }
    return undef unless %by_name;

    # Preferred names first...
    for my $want (@{ +COVER_NAMES }) {
        for my $stem (sort keys %by_name) {
            # matches "cover", "cover (1)", "cover_1" and so on
            next unless $stem eq $want || $stem =~ /^\Q$want\E[\s_(-]/;
            my ($file) = sort @{ $by_name{$stem} };
            return File::Spec->catfile($dir, $file);
        }
    }

    # ...otherwise any image that isn't a back cover.
    my ($first_stem) = sort keys %by_name;
    my ($file) = sort @{ $by_name{$first_stem} };
    return File::Spec->catfile($dir, $file);
}

# Shrink a cover to something sensible for a phone, caching the result.
# Returns undef if we can't (no ImageMagick, unwritable cache) so the caller
# can fall back to serving the original.
sub _cover_thumbnail {
    my $source = shift;
    return undef unless defined $source && -f $source;

    my $size = config->{cover_size} || 300;
    my $cache_dir = config->{cover_cache}
        || File::Spec->catdir(setting('appdir'), 'covers-cache');

    my @stat = stat $source;
    my $key = md5_hex(join '|', $source, $stat[7] || 0, $stat[9] || 0, $size);
    my $thumb = File::Spec->catfile($cache_dir, "$key.jpg");

    return $thumb if -f $thumb && -s $thumb;

    if (!-d $cache_dir) {
        eval { make_path($cache_dir) } or do {
            debug "Couldn't create cover cache dir $cache_dir: $@";
            return undef;
        };
    }

    # List form, so nothing here goes anywhere near a shell.
    my $tmp = "$thumb.$$.tmp";
    my @cmd = (
        'convert', "$source\[0]", '-thumbnail', "${size}x${size}>",
        '-background', 'none', '-strip', '-quality', '82', $tmp,
    );
    my $rc = system @cmd;

    if ($rc != 0 || !-s $tmp) {
        unlink $tmp;
        debug "convert failed for $source (rc $rc); serving original";
        return undef;
    }

    rename $tmp, $thumb or do { unlink $tmp; return undef };
    return $thumb;
}

# Turn a library-relative path into a path on disk, refusing anything that
# tries to climb out of the music directory.
sub _library_path {
    my $path = shift;
    my $music_dir = config->{music_dir} or return undef;
    return undef unless defined $path && length $path;
    return undef if $path =~ m{(?:^|/)\.\.(?:/|$)};
    return undef if $path =~ m{^/};
    return File::Spec->catdir($music_dir, $path);
}


### Browsing curated collections ############################################

# The collections configured in config.yml's "browse" section. Each is just a
# name and a directory within the MPD library.
sub _browse_collections {
    my $configured = config->{browse} || [];
    return [ grep { $_->{path} } @$configured ];
}

# Which configured collection, if any, does this path live inside?  Anything
# that isn't under one of them is refused - so a hand-typed path can't be used
# to wander the rest of the library (or anywhere else).
sub _browse_root_for {
    my $path = shift;
    return undef unless defined $path && length $path;

    # No traversal, no absolute paths, and nothing that could break out of the
    # MPD command we're about to put this in
    return undef if $path =~ m{(?:^|/)\.\.(?:/|$)};
    return undef if $path =~ m{^/};
    return undef unless _mpd_arg_ok($path);

    for my $collection (@{ _browse_collections() }) {
        my $root = $collection->{path};
        $root =~ s{/+$}{};
        return $collection if $path eq $root || index($path, "$root/") == 0;
    }
    return undef;
}

# Breadcrumbs from the collection root down to the current directory.
sub _browse_crumbs {
    my ($root, $path) = @_;
    my $base = $root->{path};
    $base =~ s{/+$}{};

    my @crumbs = ({ name => $root->{name}, path => $base });
    return \@crumbs if $path eq $base;

    my $rest = substr $path, length($base) + 1;
    my $so_far = $base;
    for my $part (split m{/}, $rest) {
        $so_far .= "/$part";
        push @crumbs, { name => $part, path => $so_far };
    }
    return \@crumbs;
}

# Where "up one level" goes: the parent directory, or back to the list of
# collections once we're at the top of one.
sub _browse_parent {
    my ($root, $path) = @_;
    my $base = $root->{path};
    $base =~ s{/+$}{};
    return undef if $path eq $base;

    my $parent = $path;
    $parent =~ s{/[^/]+$}{};
    return length $parent ? $parent : undef;
}

sub _basename {
    my $path = shift;
    return '' unless defined $path;
    my ($name) = $path =~ m{([^/]+)/*$};
    return defined $name ? $name : $path;
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
