CREATE TABLE `queue` (
    `id` int(11) NOT NULL auto_increment,
    `path` text,
    `playlist_id` int(11) default NULL,
    `played` datetime default NULL,
    `queued` datetime default NULL,
    -- who queued it: a random id from a cookie, so one person can't
    -- crowd everyone else out. `ip` is recorded for the admin view only.
    `queued_by` text default NULL,
    `ip` text default NULL,
    PRIMARY KEY  (`id`)
);
CREATE TABLE `status` (
    `enabled` int(1) default 1
);

