CREATE TABLE `queue` (
    `id` int(11) NOT NULL auto_increment,
    `path` text,
    `playlist_id` int(11) default NULL,
    `played` datetime default NULL,
    `queued` datetime default NULL,
    PRIMARY KEY  (`id`)
);
CREATE TABLE `status` (
    `enabled` int(1) default 1
);

