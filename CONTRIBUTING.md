# Contributing

## Running the project

### Create a new server instance

```
zig build server -- server init --server-name banana --owner-handle admin --owner-pass admin
```

This is only needed the first time and whenever the schema changes (make sure to delete awebo.db before re-running the command).

### Run the server:

```
zig build server -- server run
```

### Run the client:

```
zig build gui
```

The first time you will be asked to add a remote server, after that the info will be cached in the local config directory.
See logs to learn how to reset your local cache if needed.


#### NixOS
If you get a runtime SDL error that there are no devices, try:

```
nix-shell -p sdl3
zig build gui -fsys=sdl3
```

#### Testing with multiple users

If you want to launch two or more instances of the client,
each with a different logged user, use the `-Dlocal-cache` build option like so:

```
# from inside the awebo repository
mkdir user1
cd user1
zig build gui -Dlocal-cache
```

Repeat multiple times as needed replacing 'user1' with a different name.

The `-Dlocal-cache` flag will create a build of the client that stores cache and
authentication data in `.awebo-cache` and `.awebo-config` respectively, and by
dedicating a directory to each user you can achieve isolation.

This can also be useful to be able to connect as the same user twice, as you will
not be able to do so without this flag (the client takes an exclusive lock to the
sqlite database).

