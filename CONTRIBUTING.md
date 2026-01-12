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
