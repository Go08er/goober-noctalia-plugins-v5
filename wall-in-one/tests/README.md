# Wall-in-One companion tests

Run `python3 wall-in-one/tests/test_thin_client.py` from the repository root.
With Luau installed, the tests execute production entries in a mock Noctalia
host. No installed wallpaper app, live sockets, or desktop services are used.

Coverage includes direct migration/validation preflight, loaded/masked/absent
user-unit handling, fatal and slow startup failures, and opening configuration
while startup is pending. Panel/widget rendering checks cover actionable
control errors and optional battery inhibition labels without changing manual
playback state.

Both launch paths cover callback timeouts, status exit 75, the old app's exact
timeout text, eventual readiness, and one-time replay after confirmed absence.
Preparation exit 75 still fails closed. Health-persistence failures retain the
runtime/menu with keyed backoff; stale status is explicit in widget and panel.
Timed-out mutations are never replayed. The app repository additionally tests
the real client deadline and cold-starts this companion in its desktop VM.

Theme role strings are passed through to Noctalia. Verifying an actual scheme
change requires a host integration test with the widgets and panels kept open;
the mock host does not claim to test Noctalia's color invalidation.
