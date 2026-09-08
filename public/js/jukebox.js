/* DancerJukebox front-end.
 *
 * Deliberately dependency-free vanilla JS. This thing gets used at parties,
 * where the network is often flaky or entirely absent - loading jQuery from a
 * CDN meant the skip button and the enable/disable toggle silently stopped
 * working exactly when you needed them.
 *
 * Everything here is progressive enhancement: with JS off, the plain forms and
 * links still queue songs, skip, and dequeue, just with a page reload.
 */
(function () {
    "use strict";

    var POLL_MS = 4000;
    var poll_timer = null;
    var local_tick = null;
    var last_status = null;

    function $(sel, root) { return (root || document).querySelector(sel); }
    function $$(sel, root) {
        return Array.prototype.slice.call((root || document).querySelectorAll(sel));
    }

    // Element.closest and the two-argument form of classList.toggle are
    // missing on older mobile Safari, which is exactly the sort of device
    // that gets pressed into service as a party remote. Roll our own.
    function closest(el, selector) {
        var matches = Element.prototype.matches ||
                      Element.prototype.msMatchesSelector ||
                      Element.prototype.webkitMatchesSelector;
        while (el && el.nodeType === 1) {
            if (matches.call(el, selector)) { return el; }
            el = el.parentElement;
        }
        return null;
    }

    function set_class(el, name, on) {
        if (!el) { return; }
        if (on) { el.classList.add(name); } else { el.classList.remove(name); }
    }

    /* ------------------------------------------------------------ toasts */

    function toast(message, kind) {
        var tray = $(".toasts");
        if (!tray) { return; }
        var el = document.createElement("div");
        el.className = "toast" + (kind ? " " + kind : "");
        el.textContent = message;
        // Announced to screen readers via the tray's aria-live region
        tray.appendChild(el);
        window.setTimeout(function () {
            el.classList.add("out");
            window.setTimeout(function () {
                if (el.parentNode) { el.parentNode.removeChild(el); }
            }, 250);
        }, 2600);
    }

    /* ------------------------------------------------------- small utils */

    // Fetch JSON without depending on window.fetch (older tablets at parties
    // are a real thing - a 2013 iPad is still a perfectly good jukebox remote).
    function getJSON(url, done, fail) {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", url, true);
        xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest");
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4) { return; }
            if (xhr.status >= 200 && xhr.status < 300) {
                try { done(JSON.parse(xhr.responseText)); }
                catch (e) { if (fail) { fail(e); } }
            } else if (fail) {
                fail(new Error("HTTP " + xhr.status));
            }
        };
        xhr.send();
    }

    function postJSON(url, params, done, fail) {
        var xhr = new XMLHttpRequest();
        xhr.open("POST", url, true);
        xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest");
        xhr.setRequestHeader("Content-Type",
            "application/x-www-form-urlencoded; charset=UTF-8");
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4) { return; }
            if (xhr.status >= 200 && xhr.status < 300) {
                try { done(JSON.parse(xhr.responseText)); }
                catch (e) { if (fail) { fail(e); } }
            } else if (fail) {
                fail(new Error("HTTP " + xhr.status));
            }
        };
        xhr.send(params);
    }

    function mmss(seconds) {
        if (typeof seconds !== "number" || seconds < 0) { return "0:00"; }
        var m = Math.floor(seconds / 60);
        var s = Math.floor(seconds % 60);
        return m + ":" + (s < 10 ? "0" : "") + s;
    }

    /* -------------------------------------------------- now playing bar  */

    function paint_status(status) {
        last_status = status;

        var bar = $(".nowbar");
        if (bar) {
            set_class(bar, "is-playing", status.state === "play");

            var title = $(".now-title", bar);
            var artist = $(".now-artist", bar);
            if (status.current) {
                if (title) { title.textContent = status.current.title; }
                if (artist) { artist.textContent = status.current.artist; }
            } else {
                if (title) { title.textContent = "Nothing playing"; }
                if (artist) { artist.textContent = ""; }
            }

            var fill = $(".progress .bar", bar);
            if (fill) {
                fill.style.width = (status.percent || 0) + "%";
            }
            var elapsed = $(".now-time", bar);
            if (elapsed && status.total) {
                elapsed.textContent =
                    mmss(status.elapsed) + " / " + mmss(status.total);
            } else if (elapsed) {
                elapsed.textContent = "";
            }
        }

        paint_power(status.enabled);
        paint_queue(status.queue);
        paint_allowance(status.yours);
    }

    /* "You've 2 of 3 picks left" - refreshed as your songs come round, so the
     * number goes back up without a reload. */
    function paint_allowance(yours) {
        var el = $(".allowance");
        if (!el || !yours || !yours.limit) { return; }

        var left = yours.limit - yours.pending;
        el.textContent = (left > 0)
            ? "You've " + left + " of " + yours.limit + " picks left."
            : "That's your " + yours.limit +
              " queued - pick another once one has played.";
    }

    function paint_power(enabled) {
        $$(".power").forEach(function (btn) {
            set_class(btn, "is-on", !!enabled);
            set_class(btn, "is-off", !enabled);
            btn.setAttribute("aria-pressed", enabled ? "true" : "false");
            var label = $(".power-label", btn);
            if (label) {
                label.textContent = enabled ? "Jukebox on" : "Jukebox off";
            }
        });
    }

    /* Rebuild the queue list in place, so you can watch other people's
     * choices land without refreshing. */
    function paint_queue(queue) {
        var list = $("#queued_songs");
        if (!list || !queue) { return; }

        var total = queue.length;

        var count = $("#queue_count");
        if (count) { count.textContent = total; }

        // The front page only lists the next few; honour the same limit the
        // server rendered with, so the two don't disagree after a poll.
        var limit = parseInt(list.getAttribute("data-limit"), 10);
        var shown = (limit > 0) ? queue.slice(0, limit) : queue;

        // "... and N more waiting"
        var more = $(".queue-more");
        if (more) {
            var extra = total - shown.length;
            if (extra > 0) {
                var n = $(".queue-more-count", more);
                if (n) { n.textContent = extra; }
                more.removeAttribute("hidden");
            } else {
                more.setAttribute("hidden", "hidden");
            }
        }

        // Cheap check so we don't thrash the DOM on every single poll when
        // nothing has actually changed.
        var signature = shown.map(function (s) { return s.id; }).join(",");
        if (list.getAttribute("data-signature") === signature) { return; }
        list.setAttribute("data-signature", signature);

        list.innerHTML = "";

        if (!total) {
            var li = document.createElement("li");
            li.className = "empty";
            li.textContent = "Nothing queued - be the first!";
            list.appendChild(li);
            return;
        }

        shown.forEach(function (song, i) {
            var li = document.createElement("li");
            var row = document.createElement("div");
            row.className = "song";

            var idx = document.createElement("span");
            idx.className = "song-index";
            idx.textContent = (i + 1);

            var meta = document.createElement("span");
            meta.className = "song-meta";

            var t = document.createElement("span");
            t.className = "song-title";
            t.textContent = song.title;

            var sub = document.createElement("span");
            sub.className = "song-sub";
            sub.textContent = song.artist || "";

            meta.appendChild(t);
            meta.appendChild(sub);
            row.appendChild(idx);
            row.appendChild(meta);
            li.appendChild(row);
            list.appendChild(li);
        });
    }

    function refresh_status() {
        getJSON("/ajax/status", function (status) {
            paint_status(status);
        });
    }

    /* Tick the progress bar between polls so it moves smoothly rather than
     * jumping every 4 seconds. */
    function tick() {
        if (!last_status || last_status.state !== "play") { return; }
        if (!last_status.total) { return; }
        last_status.elapsed = Math.min(last_status.elapsed + 1,
                                       last_status.total);
        last_status.percent =
            Math.round((last_status.elapsed / last_status.total) * 100);

        var fill = $(".nowbar .progress .bar");
        if (fill) { fill.style.width = last_status.percent + "%"; }
        var elapsed = $(".nowbar .now-time");
        if (elapsed) {
            elapsed.textContent =
                mmss(last_status.elapsed) + " / " + mmss(last_status.total);
        }
    }

    function start_polling() {
        stop_polling();
        refresh_status();
        poll_timer = window.setInterval(refresh_status, POLL_MS);
        local_tick = window.setInterval(tick, 1000);
    }

    function stop_polling() {
        if (poll_timer) { window.clearInterval(poll_timer); poll_timer = null; }
        if (local_tick) { window.clearInterval(local_tick); local_tick = null; }
    }

    /* ------------------------------------------------------ one-tap queue */

    function queue_song(row) {
        var path = row.getAttribute("data-queue");
        if (!path || row.classList.contains("is-busy")) { return; }

        row.classList.add("is-busy");

        postJSON("/enqueue", "song=" + encodeURIComponent(path),
            function (res) {
                row.classList.remove("is-busy");
                if (res && res.ok) {
                    row.classList.add("is-queued");
                    var action = $(".song-action", row);
                    if (action) { action.textContent = "✓"; }
                    toast("Queued: " + (row.getAttribute("data-label") || "song"),
                          "good");
                    refresh_status();
                } else if (res && res.error) {
                    // Usually "you've already got three waiting" - the server
                    // words it, so we just show what it said.
                    toast(res.error, "bad");
                    refresh_status();
                } else {
                    toast("Couldn't queue that one", "bad");
                }
            },
            function () {
                row.classList.remove("is-busy");
                toast("Couldn't queue that one - is the jukebox still there?",
                      "bad");
            });
    }

    /* ------------------------------------------------------------- wiring */

    function init() {
        // One delegated listener covers every song row on every page,
        // including rows added later by paint_queue().
        document.addEventListener("click", function (ev) {
            var row = closest(ev.target, "[data-queue]");
            if (row) {
                ev.preventDefault();
                queue_song(row);
                return;
            }

            var skip = closest(ev.target, "[data-skip]");
            if (skip) {
                ev.preventDefault();
                getJSON("/control/skip?ajax=1", function () {
                    toast("Skipping…");
                    // Give MPD a moment to actually move on before we ask
                    window.setTimeout(refresh_status, 600);
                }, function () {
                    toast("Skip failed", "bad");
                });
                return;
            }

            var power = closest(ev.target, ".power");
            if (power) {
                ev.preventDefault();
                getJSON("/enabled?new_state=toggle", function (res) {
                    paint_power(res.enabled);
                    toast(res.enabled ? "Jukebox enabled"
                                      : "Jukebox disabled");
                }, function () {
                    toast("Couldn't change that", "bad");
                });
            }
        });

        // Don't poll a screen nobody's looking at - it's someone's phone
        // battery, and there may be a dozen of them open around the house.
        document.addEventListener("visibilitychange", function () {
            if (document.hidden) { stop_polling(); } else { start_polling(); }
        });

        if ($(".nowbar") || $("#queued_songs") || $(".power")) {
            start_polling();
        }

        // Focus the search box on desktop only; on a tablet this pops the
        // on-screen keyboard up over the results, which is maddening.
        var search = $("[data-autofocus]");
        if (search && window.matchMedia &&
            window.matchMedia("(hover: hover) and (pointer: fine)").matches) {
            search.focus();
        }
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", init);
    } else {
        init();
    }
}());
