## Fix gix-transport's reqwest HTTP backend to support connect and read timeouts

gix-transport/src/client/blocking_io/http/reqwest/remote.rs builds its
reqwest::blocking::Client in Remote::default() with a hardcoded
20-second .connect_timeout() and no .timeout() call at all — so a
connection that hangs mid-response (stalls after connecting, e.g. a
partitioned network or a slow/malicious server) blocks the calling
thread indefinitely.

The generic http::Options struct (client/blocking_io/http/mod.rs)
already has a connect_timeout: Option<Duration> field, populated from
the git-config key gitoxide.http.connectTimeout. The curl backend
(client/blocking_io/http/curl/remote.rs) honors it via
handle.connect_timeout(timeout). The reqwest backend never reads
config.connect_timeout at all — it only touches config.extra_headers,
config.follow_redirects, and config.backend.

Please:

  1. Make the reqwest backend honor Options.connect_timeout the same
  way curl does, replacing the hardcoded 20s default with
  config.connect_timeout.unwrap_or(Duration::from_secs(20)) (or
  similar) when building the client in Remote::default().

  2. Add a real overall/read timeout: call .timeout(duration) on the
  reqwest::blocking::ClientBuilder so a stalled read after a
  successful connect is also bounded. This likely needs a new Options
  field (e.g. read_timeout or request_timeout: Option<Duration>) since
  none currently exists for this purpose in either backend — check
  whether it's worth mirroring on the curl side too (curl's
  low_speed_limit/low_speed_time do something conceptually similar
  there) for consistency, but that's optional.

  3. Keep the existing configure_request extension point
  (reqwest/mod.rs) as-is — it operates on a per-request Request built
  after the client, and can't set a client-wide timeout, so it's not a
  substitute for #1/#2.

  4. Update the README.md to include a subsection (if not present) of
  the "About this Fork" for "Fork Features," and a subsection of "Fork
  Features" for the timeout settings.
