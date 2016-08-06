CREATE TABLE `queue` (
    `id` INTEGER PRIMARY KEY,
    `path` text,
    `playlist_id` int(11) default NULL,
    `played` datetime default NULL,
    `queued` datetime default NULL
);
CREATE TABLE `status` (
    `enabled`  int(1) default 1
);

