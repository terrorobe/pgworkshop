ALTER TABLE auction ADD COLUMN start_time timestamp with time zone NOT NULL DEFAULT NOW();
